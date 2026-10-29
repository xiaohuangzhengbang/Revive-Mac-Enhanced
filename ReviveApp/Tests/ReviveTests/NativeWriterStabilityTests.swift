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
                let prepared = try await prepareReplayPair(source: source, directory: directory)
                let asset = prepared.asset
                let assetID = prepared.assetID
                let imageURL = prepared.imageURL
                let movieURL = prepared.movieURL
                let actualTime = prepared.actualTime

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

    /// Three deterministic native writes must actually stop with unread audio,
    /// then be resumed by the unmodified production recovery timer.
    func testNativeStalledWriterResumesViaFallbackAndPreservesPair() async throws {
        for iteration in 1...3 { try await exerciseNativeRecovery(mode: .positive, iteration: iteration) }
    }

    /// With the identical callback loss but no recovery, the real writer must
    /// remain incomplete over the live observation window and cancel safely.
    func testNativeStalledWriterCannotCompleteWithRecoveryDisabled() async throws {
        try await exerciseNativeRecovery(mode: .negative, iteration: 1)
    }

    /// This opt-in gate passes only after a spontaneous native stall is captured
    /// and the original reader/writer actually recover through the normal timer.
    /// Normal writes completing within the fixed budget are not recovery proof.
    func testCapturesNaturalNativeStallAndVerifiesRecovery() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["REVIVE_NATURAL_CAPTURE"] == "1" else {
            throw XCTSkip("Natural native capture is a separate explicit fixed-budget acceptance gate")
        }
        guard let budget = Int(environment["REVIVE_NATURAL_ITERATIONS"] ?? "500"),
              (1...1000).contains(budget) else {
            throw replayError("REVIVE_NATURAL_ITERATIONS must be an integer in 1...1000")
        }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "TEST_writer_stall_prepared",
                                                    withExtension: "mov", subdirectory: "Fixtures"))
        let originalHash = try SafeExport.sha256(source)
        guard originalHash == "9dd43aa46f2a77c386999a3dd493c3811b32ed335c17cee860f0dd34c8c8e334" else {
            throw replayError("Natural recovery capture must use the unchanged retained native stall fixture")
        }
        let videoBefore = try await compressedTracks(source, mediaType: .video)
        let audioBefore = try await compressedTracks(source, mediaType: .audio)
        let audioSamples = audioBefore.reduce(0) { $0 + $1.sampleCount }
        let videoSamples = videoBefore.reduce(0) { $0 + $1.sampleCount }
        guard audioSamples == 142, videoSamples == 91 else {
            throw replayError("Natural recovery fixture sample counts changed")
        }
        let fallbackDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ci-evidence", isDirectory: true)
        let output = environment["REVIVE_NATURAL_OUTPUT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fallbackDirectory
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let captureID = UUID().uuidString
        var ledger: [[String: Any]] = []
        var started = 0
        var completed = 0
        var observed = 0
        var verified = 0
        var totalNativeHookInvocations = 0
        var totalYieldHookInvocations = 0
        var currentArchitecture = "UNKNOWN"
        var currentConfiguration = "UNKNOWN"

        func writeSummary(_ status: String, extra: [String: Any] = [:]) throws {
            var summary: [String: Any] = [
                "status": status, "evidenceKind": NativeNaturalRecoveryProbe.evidenceKind,
                "captureID": captureID, "sourceCommit": environment["GITHUB_SHA"] ?? "LOCAL_NOT_CI_BOUND",
                "architecture": currentArchitecture, "configuration": currentConfiguration,
                "attemptsBudget": budget, "attemptsStarted": started, "attemptsCompleted": completed,
                "naturalStallsObserved": observed, "nativeRecoveriesVerified": verified,
                "nativeCallbackHookInvocations": totalNativeHookInvocations,
                "yieldHookInvocations": totalYieldHookInvocations,
                "artificialFaultInjected": false, "perBufferInstrumentationBeforeFallback": false,
                "productionNoProgressTimeoutSeconds": 120, "attemptDeadlineSeconds": 15,
                "requiredGlobalNoProgressSeconds": 2, "requiredStableReadySnapshotSeconds": 1,
                "sourceFixtureSHA256": originalHash, "expectedAudioSamples": audioSamples,
                "expectedVideoSamples": videoSamples, "attempts": ledger,
                "completedAtUtc": ISO8601DateFormatter().string(from: Date())
            ]
            for (key, value) in extra { summary[key] = value }
            let path = output.appendingPathComponent(
                "NaturalWriterRecovery-\(currentArchitecture)-\(currentConfiguration)-\(captureID).json")
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: path, options: .atomic)
            print("NATURAL_WRITER_CAPTURE \(status) attempts=\(completed)/\(budget) receipt=\(path.path)")
            fflush(stdout)
        }

        for iteration in 1...budget {
            started += 1
            let recorder = try NativeNaturalRecoveryProbe(expectedAudioSamples: audioSamples, directory: output)
            currentArchitecture = recorder.architecture
            currentConfiguration = recorder.configuration
            let directory = output.appendingPathComponent("NaturalWriter-Pair-\(recorder.operationID)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let prepared = try await prepareReplayPair(source: source, directory: directory)
            recorder.note("test.context", fields: ["iteration": iteration, "captureID": captureID,
                "sourceFixtureSHA256": originalHash, "expectedAudioSamples": audioSamples,
                "expectedVideoSamples": videoSamples, "assetID": prepared.assetID])
            let attemptStarted = ProcessInfo.processInfo.systemUptime
            let operation = Task {
                try await LivePhotoEngine.passthroughWrite(asset: prepared.asset, to: prepared.movieURL,
                    assetID: prepared.assetID, timeRange: nil, stillTimeAbs: prepared.actualTime,
                    dropAudio: false, allowVideoReencode: false, probe: recorder.probe)
            }
            let deadline = Task {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { return }
                recorder.note("test.deadline.expired")
                operation.cancel()
            }
            var hookCountsRecorded = false
            var naturalStallCounted = false
            func recordHookCounts() {
                guard !hookCountsRecorded else { return }
                let counts = recorder.hookInvocationCounts
                totalNativeHookInvocations += counts.nativeCallback
                totalYieldHookInvocations += counts.yield
                hookCountsRecorded = true
            }
            do {
                let copied = try await operation.value
                deadline.cancel()
                let integrityFailures = recorder.passiveIntegrityFailures()
                guard integrityFailures.isEmpty else { throw replayError(integrityFailures.joined(separator: "; ")) }
                let naturalStall = recorder.didObserveNaturalStall
                if naturalStall {
                    observed += 1
                    naturalStallCounted = true
                    let failures = recorder.recoveryValidationFailures()
                    guard failures.isEmpty else { throw replayError(failures.joined(separator: "; ")) }
                }
                let checks = await Verifier.verify(imageURL: prepared.imageURL, movURL: prepared.movieURL,
                    expectedDuration: prepared.duration, expectedStillTime: prepared.actualTime.seconds,
                    expectedAudio: true)
                let videoAfter = try await compressedTracks(prepared.movieURL, mediaType: .video)
                let audioAfter = try await compressedTracks(prepared.movieURL, mediaType: .audio)
                let videoPreserved = assertPreserved(videoBefore, videoAfter, mediaType: "natural-recovery video")
                let audioPreserved = assertPreserved(audioBefore, audioAfter, mediaType: "natural-recovery audio")
                let unchanged = try SafeExport.sha256(source) == originalHash
                guard copied, !checks.isEmpty, checks.allSatisfy({ $0.status == .pass }),
                      videoPreserved, audioPreserved, unchanged else {
                    throw replayError("Native natural-capture output failed strict paired-file or compressed-sample validation")
                }
                let pair: [String: Any] = ["assetID": prepared.assetID,
                    "sourceUnchanged": unchanged, "compressedVideoPreserved": videoPreserved,
                    "compressedAudioPreserved": audioPreserved, "audioSamples": audioSamples,
                    "videoSamples": videoSamples, "imageSHA256": try SafeExport.sha256(prepared.imageURL),
                    "movieSHA256": try SafeExport.sha256(prepared.movieURL),
                    "imageFile": directory.lastPathComponent + "/" + prepared.imageURL.lastPathComponent,
                    "movieFile": directory.lastPathComponent + "/" + prepared.movieURL.lastPathComponent,
                    "checks": checks.map { ["code": $0.code, "status": "pass", "detail": $0.detail] }]
                recorder.note("test.files.verified", fields: pair)
                if naturalStall {
                    let failures = recorder.recoveryValidationFailures(requireFilesVerified: true)
                    guard failures.isEmpty else { throw replayError(failures.joined(separator: "; ")) }
                    verified += 1
                }
                completed += 1
                let status = naturalStall ? "NATURE_RECOVERED" : "NORMAL_WRITE_COMPLETED_NO_STALL"
                try recorder.finish(status: status, details: ["iteration": iteration, "captureID": captureID,
                    "sourceFixtureSHA256": originalHash, "pairValidation": "STRICT_JPG_MOV_AND_COMPRESSED_PAYLOAD_PASS",
                    "pair": pair])
                recordHookCounts()
                ledger.append(["iteration": iteration, "status": status,
                    "elapsedSeconds": ProcessInfo.processInfo.systemUptime - attemptStarted,
                    "receiptFile": recorder.receiptURL.lastPathComponent,
                    "eventFile": recorder.eventURL.lastPathComponent])
                if naturalStall {
                    try writeSummary("NATURE_RECOVERED", extra: ["recoveredAttempt": iteration,
                        "recoveryReceiptFile": recorder.receiptURL.lastPathComponent,
                        "recoveryEventFile": recorder.eventURL.lastPathComponent, "pair": pair])
                    return
                }
                try FileManager.default.removeItem(at: directory)
            } catch {
                deadline.cancel()
                operation.cancel()
                _ = await operation.result
                let detail = error.localizedDescription
                if recorder.didObserveNaturalStall && !naturalStallCounted { observed += 1 }
                recordHookCounts()
                try recorder.finish(status: "FAIL", details: ["iteration": iteration,
                    "captureID": captureID, "error": detail,
                    "sourceUnchanged": (try? SafeExport.sha256(source)) == originalHash,
                    "retainedOutput": directory.lastPathComponent])
                ledger.append(["iteration": iteration, "status": "FAIL", "error": detail,
                    "receiptFile": recorder.receiptURL.lastPathComponent,
                    "eventFile": recorder.eventURL.lastPathComponent])
                try writeSummary("FAIL", extra: ["error": detail])
                throw error
            }
        }
        try writeSummary("NOT_OBSERVED", extra: [
            "error": "Fixed budget exhausted without a naturally occurring native stall and verified fallback recovery"])
        throw replayError("NATURAL_STALL_NOT_OBSERVED: \(budget) normal native writes are not recovery evidence")
    }

    private func exerciseNativeRecovery(mode: NativeWriterRecoveryProbe.Mode, iteration: Int) async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "TEST_writer_stall_prepared",
                                                    withExtension: "mov", subdirectory: "Fixtures"))
        let originalHash = try SafeExport.sha256(source)
        guard originalHash == "9dd43aa46f2a77c386999a3dd493c3811b32ed335c17cee860f0dd34c8c8e334" else {
            throw replayError("Native recovery must use the exact retained stall fixture")
        }
        let videoBefore = try await compressedTracks(source, mediaType: .video)
        let audioBefore = try await compressedTracks(source, mediaType: .audio)
        let audioSamples = audioBefore.reduce(0) { $0 + $1.sampleCount }
        let videoSamples = videoBefore.reduce(0) { $0 + $1.sampleCount }
        guard audioSamples == 142, videoSamples == 91 else {
            throw replayError("Native recovery source sample counts changed")
        }
        let negativeHeld: XCTestExpectation? = mode == .negative
            ? expectation(description: "real native negative control stayed stalled") : nil
        let recorder = try NativeWriterRecoveryProbe(mode: mode, expectedAudioSamples: audioSamples,
            notifyNegativeHold: { negativeHeld?.fulfill() })
        let directory = recorder.receiptURL.deletingLastPathComponent()
            .appendingPathComponent("WriterRecovery-Pair-\(recorder.operationID)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let prepared = try await prepareReplayPair(source: source, directory: directory)
        recorder.note("test.context", fields: ["iteration": iteration, "assetID": prepared.assetID,
            "sourceFixtureSHA256": originalHash, "expectedAudioSamples": audioSamples,
            "expectedVideoSamples": videoSamples, "movieURL": prepared.movieURL.path])
        let operation = Task {
            try await LivePhotoEngine.passthroughWrite(asset: prepared.asset, to: prepared.movieURL,
                assetID: prepared.assetID, timeRange: nil, stillTimeAbs: prepared.actualTime,
                dropAudio: false, allowVideoReencode: false, probe: recorder.probe)
        }
        let deadline = Task {
            do { try await Task.sleep(nanoseconds: 12_000_000_000) }
            catch { return }
            recorder.note("test.deadline.expired")
            operation.cancel()
        }
        defer { deadline.cancel() }
        var cancelled = false
        do {
            if mode == .negative {
                await fulfillment(of: [try XCTUnwrap(negativeHeld)], timeout: 10)
                recorder.note("test.cancellation.requested")
                operation.cancel()
                switch await operation.result {
                case .success:
                    throw replayError("Native negative control unexpectedly completed without recovery")
                case .failure(let error):
                    guard case EngineError.cancelled = error else { throw error }
                    cancelled = true
                    recorder.note("test.cancellation.completed")
                }
                deadline.cancel()
                let failures = recorder.validationFailures(negativeCancelled: true)
                guard failures.isEmpty else { throw replayError(failures.joined(separator: "; ")) }
                guard try SafeExport.sha256(source) == originalHash else {
                    throw replayError("Negative native control changed the source fixture")
                }
                try recorder.finish(status: "PASS", details: ["iteration": iteration,
                    "sourceFixtureSHA256": originalHash, "expectedVideoSamples": videoSamples,
                    "sourceUnchanged": true, "cancelledThroughNativeFailureDrain": true,
                    "pairValidation": "NOT_APPLICABLE_CANCELLED_NEGATIVE_CONTROL"])
            } else {
                let copied = try await operation.value
                deadline.cancel()
                let failures = recorder.validationFailures()
                guard failures.isEmpty else {
                    throw replayError("RECOVERY_EXPECTED_APPEND_NOT_OBSERVED: " + failures.joined(separator: "; "))
                }
                let checks = await Verifier.verify(imageURL: prepared.imageURL, movURL: prepared.movieURL,
                    expectedDuration: prepared.duration, expectedStillTime: prepared.actualTime.seconds,
                    expectedAudio: true)
                let videoAfter = try await compressedTracks(prepared.movieURL, mediaType: .video)
                let audioAfter = try await compressedTracks(prepared.movieURL, mediaType: .audio)
                let videoPreserved = assertPreserved(videoBefore, videoAfter, mediaType: "recovered video")
                let audioPreserved = assertPreserved(audioBefore, audioAfter, mediaType: "recovered audio")
                let unchanged = try SafeExport.sha256(source) == originalHash
                guard copied, !checks.isEmpty, checks.allSatisfy({ $0.status == .pass }),
                      videoPreserved, audioPreserved, unchanged else {
                    throw replayError("Recovered native pair failed strict file or compressed payload verification")
                }
                let passedChecks = checks.map { ["code": $0.code, "detail": $0.detail, "status": "pass"] }
                let pair: [String: Any] = ["assetID": prepared.assetID,
                    "imageSHA256": try SafeExport.sha256(prepared.imageURL),
                    "movieSHA256": try SafeExport.sha256(prepared.movieURL),
                    "imageFile": directory.lastPathComponent + "/" + prepared.imageURL.lastPathComponent,
                    "movieFile": directory.lastPathComponent + "/" + prepared.movieURL.lastPathComponent,
                    "sourceUnchanged": unchanged, "compressedVideoPreserved": videoPreserved,
                    "compressedAudioPreserved": audioPreserved, "videoSamples": videoSamples,
                    "audioSamples": audioSamples, "checks": passedChecks]
                recorder.note("test.files.verified", fields: pair)
                let finalFailures = recorder.validationFailures(requireFilesVerified: true)
                guard finalFailures.isEmpty else { throw replayError(finalFailures.joined(separator: "; ")) }
                try recorder.finish(status: "PASS", details: ["iteration": iteration,
                    "sourceFixtureSHA256": originalHash, "expectedVideoSamples": videoSamples,
                    "sourceUnchanged": unchanged, "pairValidation": "STRICT_JPG_MOV_AND_COMPRESSED_PAYLOAD_PASS",
                    "pair": pair])
            }
        } catch {
            operation.cancel()
            _ = await operation.result
            let failures = recorder.validationFailures(negativeCancelled: cancelled)
            let marker = mode == .positive ? "RECOVERY_EXPECTED_APPEND_NOT_OBSERVED: " : ""
            let detail = marker + error.localizedDescription + "; " + failures.joined(separator: "; ")
            try recorder.finish(status: "FAIL", details: ["iteration": iteration,
                "sourceFixtureSHA256": originalHash, "expectedVideoSamples": videoSamples,
                "sourceUnchanged": (try? SafeExport.sha256(source)) == originalHash,
                "error": detail, "validationFailures": failures, "retainedOutput": directory.path])
            throw replayError(detail)
        }
    }

    private struct PreparedReplay {
        let asset: AVURLAsset
        let assetID: String
        let imageURL: URL
        let movieURL: URL
        let actualTime: CMTime
        let duration: Double
    }

    private func prepareReplayPair(source: URL, directory: URL) async throws -> PreparedReplay {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, actualTime) = try await generator.image(
            at: CMTime(seconds: 1.49, preferredTimescale: 60_000))
        guard actualTime.isNumeric, actualTime.seconds >= 0, actualTime.seconds < duration else {
            throw replayError("Cover extraction returned an invalid actual frame time")
        }
        let assetID = UUID().uuidString.uppercased()
        let imageURL = directory.appendingPathComponent("REPLAY.JPG")
        let movieURL = directory.appendingPathComponent("REPLAY.MOV")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.98,
            kCGImagePropertyMakerAppleDictionary: [LivePhotoEngine.makerAppleAssetIDKey: assetID]]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw replayError("Replay JPEG encoding failed") }
        return PreparedReplay(asset: asset, assetID: assetID, imageURL: imageURL, movieURL: movieURL,
                              actualTime: actualTime, duration: duration)
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
