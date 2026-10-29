import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import Revive

final class StillMotionTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("StillMotionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporary) }

    func testStillImageProducesRealMotionExactDurationGIFAndVerifiedLivePair() async throws {
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let evidence = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ci-evidence/StillMotion-Core-\(configuration)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let source = evidence.appendingPathComponent("TEST_still_source.png")
        try makeImage(source, width: 320, height: 240)
        let sourceHash = try SafeExport.sha256(source)
        let movie = evidence.appendingPathComponent("motion.mp4")
        try await StillMotion.generate(source: source, to: movie)
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(duration, 3, accuracy: 0.001)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertTrue(audioTracks.isEmpty)
        let frames = try await decodedFrames(movie)
        XCTAssertEqual(frames, 90)
        let first = try await frame(movie, seconds: 0)
        let middle = try await frame(movie, seconds: 1.5)
        XCTAssertEqual(first.width, 320)
        XCTAssertEqual(first.height, 240)
        let difference = try meanPixelDifference(first, middle)
        XCTAssertGreaterThan(difference, 2, "The real rendered movie must visibly move, not repeat a still")

        let gif = evidence.appendingPathComponent("motion.gif")
        let gifSummary = try await StillMotion.exportGIF(movieURL: movie, to: gif)
        XCTAssertEqual(gifSummary.frameCount, 45)
        XCTAssertEqual(gifSummary.duration, 3, accuracy: 0.011)
        XCTAssertEqual(gifSummary.width, 320)
        XCTAssertEqual(gifSummary.height, 240)
        let animation = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(animation), 45)
        var gifDuration = 0.0
        var delays = Set<Int>()
        for index in 0..<45 {
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(animation, index, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(animation, index, nil) as? [String: Any])
            let timing = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
            let delay = try XCTUnwrap(timing[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)
            gifDuration += delay.doubleValue
            delays.insert(Int((delay.doubleValue * 100).rounded()))
        }
        XCTAssertEqual(gifDuration, 3, accuracy: 0.011)
        XCTAssertEqual(delays, Set([6, 7]), "Distribute centiseconds; uniform seven-centisecond frames would last3.15s")
        let gifFirst = try XCTUnwrap(CGImageSourceCreateImageAtIndex(animation, 0, nil))
        let gifMiddle = try XCTUnwrap(CGImageSourceCreateImageAtIndex(animation, 22, nil))
        XCTAssertGreaterThan(try meanPixelDifference(gifFirst, gifMiddle), 2)

        var settings = ConversionSettings()
        settings.trimEnd = 3
        settings.frameTime = 1.5
        settings.exactTrim = true
        settings.dropAudio = true
        let pair = try await LivePhotoEngine.convert(input: movie,
            outputDir: evidence.appendingPathComponent("LivePair", isDirectory: true),
            baseName: "PAIR", settings: settings)
        let checks = await Verifier.verify(imageURL: pair.imageURL, movURL: pair.movURL,
            expectedDuration: 3, expectedStillTime: pair.stillTime, expectedAudio: false)
        XCTAssertFalse(checks.isEmpty)
        for check in checks { XCTAssertEqual(check.status, .pass, "\(check.code): \(check.detail)") }
        XCTAssertEqual(try SafeExport.sha256(source), sourceHash)
        guard frames == 90, difference > 2, gifSummary.frameCount == 45,
              abs(gifDuration - 3) <= 0.011, !checks.isEmpty,
              checks.allSatisfy({ $0.status == .pass }), try SafeExport.sha256(source) == sourceHash else {
            throw failure("Still motion acceptance did not pass every native check")
        }
        let receipt: [String: Any] = [
            "status": "STILL_IMAGE_MOTION_GIF_AND_LIVE_PAIR_VERIFIED",
            "sourceCommit": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "LOCAL_NATIVE_TEST",
            "configuration": configuration,
            "sourceFile": source.lastPathComponent, "sourceSHA256": sourceHash, "sourceUnchanged": true,
            "movieFile": movie.lastPathComponent, "movieSHA256": try SafeExport.sha256(movie),
            "movieFrames": frames, "movieDuration": duration, "visibleMotionDifference": difference,
            "gifFile": gif.lastPathComponent, "gifSHA256": try SafeExport.sha256(gif),
            "gifFrames": gifSummary.frameCount, "gifDuration": gifDuration,
            "gifDelaysCentiseconds": delays.sorted(), "width": gifSummary.width, "height": gifSummary.height,
            "imageFile": "LivePair/PAIR.JPG", "imageSHA256": try SafeExport.sha256(pair.imageURL),
            "liveMovieFile": "LivePair/PAIR.MOV", "liveMovieSHA256": try SafeExport.sha256(pair.movURL),
            "checks": checks.map { ["code": $0.code, "status": $0.status.rawValue, "detail": $0.detail] },
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("StillMotionReceipt.json"), options: .atomic)
    }

    func testImageOrientationIsAppliedBeforeMovieDimensionsAreChosen() async throws {
        let source = temporary.appendingPathComponent("rotated.jpg")
        try makeImage(source, width: 200, height: 120, orientation: 6)
        let before = try SafeExport.sha256(source)
        let movie = temporary.appendingPathComponent("upright.mp4")
        try await StillMotion.generate(source: source, to: movie, duration: 0.5)
        let actual = try await frame(movie, seconds: 0)
        XCTAssertEqual(actual.width, 120)
        XCTAssertEqual(actual.height, 200)
        let frames = try await decodedFrames(movie)
        XCTAssertEqual(frames, 15)
        XCTAssertEqual(try SafeExport.sha256(source), before)
    }

    func testTransparentImageIsCompositedOverOpaqueWhite() async throws {
        let source = temporary.appendingPathComponent("transparent.png")
        try makeImage(source, width: 160, height: 120, transparent: true)
        let movie = temporary.appendingPathComponent("opaque.mp4")
        try await StillMotion.generate(source: source, to: movie, duration: 0.5)
        let image = try await frame(movie, seconds: 0)
        let pixels = try rgba(image)
        let pixel = (5 * image.width + 5) * 4
        XCTAssertGreaterThan(pixels[pixel], 230)
        XCTAssertGreaterThan(pixels[pixel + 1], 230)
        XCTAssertGreaterThan(pixels[pixel + 2], 230)
        XCTAssertEqual(pixels[pixel + 3], 255)
    }

    func testInvalidImagesAndDurationsLeaveNoOutputOrStagingFiles() async throws {
        let invalid = temporary.appendingPathComponent("invalid.png")
        try Data("not a real image".utf8).write(to: invalid)
        let output = temporary.appendingPathComponent("invalid.mp4")
        do { try await StillMotion.generate(source: invalid, to: output); XCTFail("Corrupt image must fail") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
        let source = temporary.appendingPathComponent("source.png")
        try makeImage(source, width: 160, height: 120)
        for duration in [0, -1, Double.nan, .infinity, 11] {
            do { try await StillMotion.generate(source: source, to: output, duration: duration); XCTFail("Invalid duration must fail") }
            catch { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
        }
        let oversized = temporary.appendingPathComponent("too-large.png")
        let oversizedFD = Darwin.open(oversized.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard oversizedFD >= 0 else { throw failure("Cannot create bounded-input regression fixture") }
        let truncated = Darwin.ftruncate(oversizedFD, off_t(256 * 1024 * 1024 + 1))
        Darwin.close(oversizedFD)
        guard truncated == 0 else { throw failure("Cannot size bounded-input regression fixture") }
        do { try await StillMotion.generate(source: oversized, to: output); XCTFail("Oversized image must be rejected before loading") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
        XCTAssertEqual(Set(remaining), Set(["invalid.png", "source.png", "too-large.png"]))
    }

    func testExistingFilesAndSymlinksAreNeverReplaced() async throws {
        let source = temporary.appendingPathComponent("source.png")
        try makeImage(source, width: 160, height: 120)
        let original = try SafeExport.sha256(source)
        let existing = temporary.appendingPathComponent("keep.mp4")
        let sentinel = Data("existing user file".utf8)
        try sentinel.write(to: existing)
        do { try await StillMotion.generate(source: source, to: existing, duration: 0.5); XCTFail("Existing movie must be rejected") }
        catch { XCTAssertEqual(try Data(contentsOf: existing), sentinel) }
        let alias = temporary.appendingPathComponent("alias.mp4")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: existing)
        do { try await StillMotion.generate(source: source, to: alias, duration: 0.5); XCTFail("Leaf alias must be rejected") }
        catch { XCTAssertEqual(try Data(contentsOf: existing), sentinel) }
        let sourceAlias = temporary.appendingPathComponent("source-alias.png")
        try FileManager.default.createSymbolicLink(at: sourceAlias, withDestinationURL: source)
        let rejected = temporary.appendingPathComponent("rejected.mp4")
        do { try await StillMotion.generate(source: sourceAlias, to: rejected, duration: 0.5); XCTFail("Source symlink must be rejected") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path)) }
        let movie = temporary.appendingPathComponent("motion.mp4")
        try await StillMotion.generate(source: source, to: movie, duration: 0.5)
        let gif = temporary.appendingPathComponent("keep.gif")
        try sentinel.write(to: gif)
        do { _ = try await StillMotion.exportGIF(movieURL: movie, to: gif); XCTFail("Existing GIF must be rejected") }
        catch { XCTAssertEqual(try Data(contentsOf: gif), sentinel) }
        XCTAssertEqual(try SafeExport.sha256(source), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temporary.path)
            .contains(where: { $0.hasPrefix(".revive-motion-") }))
    }

    func testCancellationDuringImageRenderingRemovesOwnedStagingAndPreservesSource() async throws {
        let source = temporary.appendingPathComponent("inflight-source.png")
        try makeImage(source, width: 1280, height: 960)
        let original = try SafeExport.sha256(source)
        let movie = temporary.appendingPathComponent("inflight.mp4")
        let operation = Task { try await StillMotion.generate(source: source, to: movie, duration: 10) }
        let deadline = Date().addingTimeInterval(5)
        var observedStaging = false
        while Date() < deadline {
            observedStaging = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
                .contains { $0.hasPrefix(".revive-motion-") }
            if observedStaging { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        operation.cancel()
        do { try await operation.value; XCTFail("In-flight cancellation must not publish a movie") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected cancellation result: \(error)") }
        XCTAssertTrue(observedStaging, "Test must cancel after real rendering setup began")
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
        XCTAssertEqual(try SafeExport.sha256(source), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temporary.path)
            .contains { $0.hasPrefix(".revive-motion-") })
    }

    func testCancellationNeverPublishesPartialMovieOrGIF() async throws {
        let source = temporary.appendingPathComponent("source.png")
        try makeImage(source, width: 160, height: 120)
        let sourceHash = try SafeExport.sha256(source)
        let cancelledMovie = temporary.appendingPathComponent("cancelled.mp4")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await StillMotion.generate(source: source, to: cancelledMovie)
        }
        do { try await task.value; XCTFail("Pre-cancelled motion must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledMovie.path))
        let movie = temporary.appendingPathComponent("valid.mp4")
        try await StillMotion.generate(source: source, to: movie, duration: 0.5)
        let gif = temporary.appendingPathComponent("cancelled.gif")
        let gifTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StillMotion.exportGIF(movieURL: movie, to: gif)
        }
        do { _ = try await gifTask.value; XCTFail("Pre-cancelled GIF must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: gif.path))
        XCTAssertEqual(try SafeExport.sha256(source), sourceHash)
    }

    private func makeImage(_ url: URL, width: Int, height: Int, orientation: Int = 1,
                           transparent: Bool = false) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        if transparent {
            context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 0.8))
            context.fill(CGRect(x: CGFloat(width) / 3, y: CGFloat(height) / 3,
                                width: CGFloat(width) / 3, height: CGFloat(height) / 3))
        } else {
            for y in stride(from: 0, to: height, by: 12) {
                for x in stride(from: 0, to: width, by: 12) {
                    let odd = ((x / 12 + y / 12) % 2) == 0
                    context.setFillColor(CGColor(red: odd ? 0.95 : 0.1,
                                                 green: Double(x) / Double(width),
                                                 blue: odd ? 0.15 : 0.9, alpha: 1))
                    context.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 12, height: 12))
                }
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let type = url.pathExtension.lowercased() == "jpg" ? UTType.jpeg : UTType.png
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.98] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw failure("Cannot write still test source") }
    }

    private func frame(_ url: URL, seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 60_000))
        return image
    }

    private func decodedFrames(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? failure("Cannot decode motion movie") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetImageBuffer(sample) != nil else {
                throw failure("Motion movie frame failed real decoding")
            }
            count += CMSampleBufferGetNumSamples(sample)
        }
        guard reader.status == .completed else { throw reader.error ?? failure("Motion decode did not finish") }
        return count
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { memory in
            let context = try XCTUnwrap(CGContext(data: memory.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return bytes
    }

    private func meanPixelDifference(_ a: CGImage, _ b: CGImage) throws -> Double {
        guard a.width == b.width, a.height == b.height else { throw failure("Comparison dimensions differ") }
        let left = try rgba(a), right = try rgba(b)
        return zip(left, right).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(left.count)
    }
    private func failure(_ detail: String) -> NSError { NSError(domain: "StillMotionTests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: detail]) }
}
