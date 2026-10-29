import XCTest
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import Foundation
import Darwin
@testable import Revive

final class NativeWriterStabilityTests: XCTestCase {
    private struct CompressedTrack {
        var bytes = Data()
        var sampleCount = 0
    }

    /// Replays the exact prepared movie retained from the native writer stall.
    /// No trim export or video/audio encode is allowed in this regression.
    func testRepeatedlyRemuxesPreviouslyStalledMovie() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "TEST_writer_stall_prepared",
                                                    withExtension: "mov", subdirectory: "Fixtures"))
        let originalHash = try SafeExport.sha256(source)
        let retainedHash = "9dd43aa46f2a77c386999a3dd493c3811b32ed335c17cee860f0dd34c8c8e334"
        XCTAssertEqual(originalHash, retainedHash, "Replay must use the retained stalled prepared movie")
        guard originalHash == retainedHash else { return }

        let environment = ProcessInfo.processInfo.environment
        let configured = environment["REVIVE_REPLAY_ITERATIONS"] ?? "3"
        guard let iterations = Int(configured), (1...1000).contains(iterations) else {
            XCTFail("REVIVE_REPLAY_ITERATIONS must be an integer in 1...1000")
            return
        }
        let traceRoot = environment["REVIVE_WRITER_TRACE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        var traceHandle: FileHandle?
        if let traceRoot {
            try FileManager.default.createDirectory(at: traceRoot, withIntermediateDirectories: true)
            let traceURL = traceRoot.appendingPathComponent("StressIterations.jsonl")
            if !FileManager.default.fileExists(atPath: traceURL.path) {
                guard FileManager.default.createFile(atPath: traceURL.path, contents: nil) else {
                    throw replayError("Cannot create replay iteration trace")
                }
            }
            traceHandle = try FileHandle(forWritingTo: traceURL)
            try traceHandle?.seekToEnd()
        }
        defer { try? traceHandle?.close() }
        let stressID = UUID().uuidString
        let startedAt = ProcessInfo.processInfo.systemUptime

        func trace(_ event: String, iteration: Int, iterationStartedAt: TimeInterval,
                   detail: String? = nil) throws {
            let now = ProcessInfo.processInfo.systemUptime
            var entry: [String: Any] = [
                "event": event, "experiment": "stalled-movie-remux", "stressID": stressID,
                "iteration": iteration, "totalIterations": iterations,
                "elapsedSeconds": now - startedAt, "iterationSeconds": now - iterationStartedAt,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "pid": ProcessInfo.processInfo.processIdentifier,
            ]
            if let detail { entry["detail"] = detail }
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0A)
            print(String(decoding: data.dropLast(), as: UTF8.self))
            fflush(stdout)
            try traceHandle?.write(contentsOf: data)
            try traceHandle?.synchronize()
        }

        let videoBefore = try await compressedTracks(source, mediaType: .video)
        let audioBefore = try await compressedTracks(source, mediaType: .audio)
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        for iteration in 1...iterations {
            let iterationStartedAt = ProcessInfo.processInfo.systemUptime
            try trace("start", iteration: iteration, iterationStartedAt: iterationStartedAt)
            let directory = (traceRoot ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath())
                .appendingPathComponent("Replay-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let asset = AVURLAsset(url: source)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let (image, actualTime) = try await generator.image(
                    at: CMTime(seconds: 1.49, preferredTimescale: 60_000))
                XCTAssertTrue(actualTime.isNumeric && actualTime.seconds >= 0 && actualTime.seconds < duration)
                guard actualTime.isNumeric, actualTime.seconds >= 0, actualTime.seconds < duration else {
                    throw replayError("Cover extraction returned an invalid actual frame time")
                }
                let assetID = UUID().uuidString.uppercased()
                let imageURL = directory.appendingPathComponent("REPLAY.JPG")
                let movieURL = directory.appendingPathComponent("REPLAY.MOV")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
                    imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
                let properties: [CFString: Any] = [
                    kCGImageDestinationLossyCompressionQuality: 0.98,
                    kCGImagePropertyMakerAppleDictionary: [LivePhotoEngine.makerAppleAssetIDKey: assetID],
                ]
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    throw replayError("Replay JPEG encoding failed")
                }

                let copied = try await LivePhotoEngine.passthroughWrite(
                    asset: asset, to: movieURL, assetID: assetID, timeRange: nil,
                    stillTimeAbs: actualTime, dropAudio: false, allowVideoReencode: false)
                XCTAssertTrue(copied, "Replay must copy the compressed video")
                let checks = await Verifier.verify(imageURL: imageURL, movURL: movieURL,
                    expectedDuration: duration, expectedStillTime: actualTime.seconds, expectedAudio: true)
                XCTAssertFalse(checks.isEmpty)
                for check in checks {
                    XCTAssertEqual(check.status, .pass, "\(check.code): \(check.detail)")
                }
                let videoAfter = try await compressedTracks(movieURL, mediaType: .video)
                let audioAfter = try await compressedTracks(movieURL, mediaType: .audio)
                let videoPreserved = assertPreserved(videoBefore, videoAfter, mediaType: "video")
                let audioPreserved = assertPreserved(audioBefore, audioAfter, mediaType: "audio")
                let currentHash = try SafeExport.sha256(source)
                XCTAssertEqual(currentHash, originalHash)
                guard copied, !checks.isEmpty, checks.allSatisfy({ $0.status == .pass }),
                      videoPreserved, audioPreserved, currentHash == originalHash else {
                    throw replayError("Replay verification or source integrity failed")
                }
                try FileManager.default.removeItem(at: directory)
                try trace("finish", iteration: iteration, iterationStartedAt: iterationStartedAt)
            } catch {
                // Retain this iteration's files for the existing artifact collector.
                let unchanged = (try? SafeExport.sha256(source)) == originalHash
                XCTAssertTrue(unchanged, "The retained source must stay unchanged even when replay fails")
                do {
                    try trace("failed", iteration: iteration, iterationStartedAt: iterationStartedAt,
                              detail: "\(error.localizedDescription); retainedOutput=\(directory.path)")
                } catch let traceError {
                    print("Replay failure trace write failed: \(traceError.localizedDescription)")
                    fflush(stdout)
                }
                throw error
            }
        }
    }

    private func compressedTracks(_ url: URL, mediaType: AVMediaType) async throws -> [CompressedTrack] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: mediaType)
        guard !tracks.isEmpty else { throw replayError("Missing \(mediaType.rawValue) track") }
        var result: [CompressedTrack] = []
        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            defer { if reader.status == .reading { reader.cancelReading() } }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { throw replayError("Cannot read compressed track") }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? replayError("Cannot start compressed reader") }
            var compressed = CompressedTrack()
            while let sample = output.copyNextSampleBuffer() {
                guard CMSampleBufferDataIsReady(sample) else { throw replayError("Compressed sample is not ready") }
                let samples = CMSampleBufferGetNumSamples(sample)
                compressed.sampleCount += samples
                guard let block = CMSampleBufferGetDataBuffer(sample) else {
                    guard samples == 0 else { throw replayError("Compressed sample has no data buffer") }
                    continue
                }
                let length = CMBlockBufferGetDataLength(block)
                if length == 0 {
                    guard samples == 0 else { throw replayError("Compressed sample has no bytes") }
                    continue
                }
                var bytes = [UInt8](repeating: 0, count: length)
                let status = bytes.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw replayError("Cannot copy compressed sample bytes") }
                compressed.bytes.append(contentsOf: bytes)
            }
            guard reader.status == .completed else { throw reader.error ?? replayError("Compressed reader did not finish") }
            guard compressed.sampleCount > 0, !compressed.bytes.isEmpty else {
                throw replayError("Compressed track has no readable samples")
            }
            result.append(compressed)
        }
        return result
    }

    private func assertPreserved(_ before: [CompressedTrack], _ after: [CompressedTrack], mediaType: String) -> Bool {
        XCTAssertEqual(before.count, after.count, "\(mediaType) track count changed")
        guard before.count == after.count else { return false }
        var preserved = true
        for (index, pair) in zip(before, after).enumerated() {
            XCTAssertEqual(pair.0.sampleCount, pair.1.sampleCount, "\(mediaType) track \(index) sample count changed")
            XCTAssertTrue(pair.0.bytes == pair.1.bytes, "\(mediaType) track \(index) compressed bytes changed")
            preserved = preserved && pair.0.sampleCount == pair.1.sampleCount && pair.0.bytes == pair.1.bytes
        }
        return preserved
    }

    private func replayError(_ detail: String) -> NSError {
        NSError(domain: "ReviveNativeWriterReplay", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
}
