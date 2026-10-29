import XCTest
import AVFoundation
import ImageIO
import CoreGraphics
import Darwin
@testable import Revive

/// End-to-end tests for the conversion engine. Each test generates a real H.264
/// video on the fly (no fixture files in the repo), runs the engine, then checks
/// the output the same way the app does — via Verifier.
final class EngineTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviveTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // Proves the whole pipeline: a converted pair passes every Verifier check
    // (both files exist, matching UUID on each side, still-image-time track).
    func testProducesValidLivePhotoPair() async throws {
        let src = tmp.appendingPathComponent("src.mp4")
        try makeTestVideo(at: src)

        let result = try await LivePhotoEngine.convert(
            input: src, outputDir: tmp, baseName: "IMG_TEST", settings: ConversionSettings())

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.imageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.movURL.path))

        let checks = await Verifier.verify(imageURL: result.imageURL, movURL: result.movURL)
        for check in checks {
            XCTAssertEqual(check.status, .pass, "驗證未通過:\(check.label) — \(check.detail)")
        }
    }

    // Proves the zero-quality-loss promise for real: the compressed video
    // bitstream in the output is byte-for-byte identical to the source (not just
    // that a "copied" flag is set). This is the in-test equivalent of the
    // `ffmpeg -c copy | md5` check.
    func testH264VideoStreamIsByteIdentical() async throws {
        let src = tmp.appendingPathComponent("src.mp4")
        try makeTestVideo(at: src)

        let result = try await LivePhotoEngine.convert(
            input: src, outputDir: tmp, baseName: "IMG_LL", settings: ConversionSettings())

        XCTAssertTrue(result.videoWasCopied, "H.264 應走無損 passthrough")
        let before = try await compressedVideoBytes(src)
        let after = try await compressedVideoBytes(result.movURL)
        XCTAssertFalse(before.isEmpty, "測試影片沒讀到任何樣本")
        XCTAssertEqual(before, after, "影片壓縮位元流應與來源完全相同(零損失)")
    }

    /// Reads the raw compressed samples of a file's video track (passthrough,
    /// no decode) and concatenates them — exact bytes, for equality comparison.
    private func compressedVideoBytes(_ url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return Data() }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil) // nil = compressed
        reader.add(output)
        reader.startReading()
        var acc = Data()
        while let sbuf = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sbuf) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: len)
            if CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: &bytes) == kCMBlockBufferNoErr {
                acc.append(contentsOf: bytes)
            }
        }
        return acc
    }

    // Proves the verifier actually catches a broken pair: A's photo with B's
    // video have different UUIDs, so the "identifiers match" check must fail.
    func testVerifierRejectsMismatchedPair() async throws {
        let a = tmp.appendingPathComponent("a.mp4"); try makeTestVideo(at: a)
        let b = tmp.appendingPathComponent("b.mp4"); try makeTestVideo(at: b)

        let ra = try await LivePhotoEngine.convert(
            input: a, outputDir: tmp, baseName: "A", settings: ConversionSettings())
        let rb = try await LivePhotoEngine.convert(
            input: b, outputDir: tmp, baseName: "B", settings: ConversionSettings())

        let checks = await Verifier.verify(imageURL: ra.imageURL, movURL: rb.movURL)
        // checks[2] is the "identifiers match" check
        XCTAssertEqual(checks[2].status, .fail, "不同 UUID 的配對應被判定失敗")
    }

    // MARK: test fixture

    // A source-frame cover can differ from a re-encoded, trimmed movie. Compare
    // the encoded JPEG with the actual final MOV frame and read its timed tag.
    func testExactTrimCoverMatchesFinalMovieAndActualMetadataTime() async throws {
        let src = tmp.appendingPathComponent("source.mp4")
        try makeTestVideo(at: src)
        let original = try Data(contentsOf: src)
        var settings = ConversionSettings()
        settings.exactTrim = true
        settings.trimStart = 0.213
        settings.trimEnd = 0.913
        settings.frameTime = 0.217
        let result = try await LivePhotoEngine.convert(
            input: src, outputDir: tmp.appendingPathComponent("pair"),
            baseName: "COVER", settings: settings)

        XCTAssertFalse(result.videoWasCopied)
        XCTAssertGreaterThanOrEqual(result.stillTime, 0)
        XCTAssertLessThan(result.stillTime, result.clipDuration)
        let marker = try await stillMetadataRange(result.movURL)
        XCTAssertTrue(marker.duration.isNumeric)
        XCTAssertTrue(marker.duration.seconds.isFinite)
        XCTAssertGreaterThan(marker.duration.seconds, 0)
        XCTAssertEqual(marker.start.seconds, result.stillTime, accuracy: 0.001)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: result.movURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (frame, actualTime) = try await generator.image(at:
            CMTime(seconds: result.stillTime, preferredTimescale: 60_000))
        XCTAssertEqual(actualTime.seconds, result.stillTime, accuracy: 0.001)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(result.imageURL as CFURL, nil))
        let photo = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(photo.width, frame.width)
        XCTAssertEqual(photo.height, frame.height)
        XCTAssertEqual(photo.width, 320, "Cover must retain full frame resolution")
        let photoBytes = try rgba(photo)
        let frameBytes = try rgba(frame)
        let meanError = zip(photoBytes, frameBytes).reduce(0.0) {
            $0 + abs(Double($1.0) - Double($1.1))
        } / Double(photoBytes.count)
        XCTAssertLessThan(meanError, 4, "JPEG pixels must match the final movie within encoding loss")
        XCTAssertEqual(try Data(contentsOf: src), original, "Conversion must preserve the source")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: result.movURL.deletingLastPathComponent().path)
        XCTAssertEqual(Set(leftovers), Set(["COVER.JPG", "COVER.MOV"]))
    }

    func testRejectsExistingImageOrMovieWithoutChangingFiles() async throws {
        let src = tmp.appendingPathComponent("source.mp4")
        try makeTestVideo(at: src)
        let original = try Data(contentsOf: src)
        for ext in ["JPG", "MOV"] {
            let output = tmp.appendingPathComponent(ext)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let existing = output.appendingPathComponent("PAIR.\(ext)")
            let sentinel = Data("keep this file".utf8)
            try sentinel.write(to: existing)
            do {
                _ = try await LivePhotoEngine.convert(
                    input: src, outputDir: output, baseName: "PAIR", settings: ConversionSettings())
                XCTFail("Existing \(ext) must be rejected")
            } catch {
                XCTAssertEqual(try Data(contentsOf: existing), sentinel)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [existing.lastPathComponent])
            }
        }
        XCTAssertEqual(try Data(contentsOf: src), original)
    }

    func testRejectsInvalidTimesBeforeCreatingOutputs() async throws {
        let src = tmp.appendingPathComponent("source.mp4")
        try makeTestVideo(at: src)
        var cases: [ConversionSettings] = []
        for value in [Double.nan, .infinity, -.infinity, -0.1, 1.0, 2.0] {
            var settings = ConversionSettings()
            settings.frameTime = value
            cases.append(settings)
        }
        for value in [Double.nan, .infinity, -0.1, 1.0, 2.0] {
            var settings = ConversionSettings()
            settings.trimStart = value
            cases.append(settings)
        }
        for value in [Double.nan, .infinity, -0.1, 2.0] {
            var settings = ConversionSettings()
            settings.trimEnd = value
            cases.append(settings)
        }
        var reversed = ConversionSettings()
        reversed.trimStart = 0.7
        reversed.trimEnd = 0.3
        cases.append(reversed)
        for (index, settings) in cases.enumerated() {
            let output = tmp.appendingPathComponent("invalid-\(index)")
            do {
                _ = try await LivePhotoEngine.convert(
                    input: src, outputDir: output, baseName: "PAIR", settings: settings)
                XCTFail("Invalid times must fail: case \(index)")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    func testRejectsBasenameTraversalAndSymlinkedOutputDirectory() async throws {
        let src = tmp.appendingPathComponent("source.mp4")
        try makeTestVideo(at: src)
        for baseName in ["", ".", "..", "../escape", "nested/name", "nested\\name"] {
            do {
                _ = try await LivePhotoEngine.convert(input: src, outputDir: tmp,
                    baseName: baseName, settings: ConversionSettings())
                XCTFail("Invalid baseName must fail: \(baseName)")
            } catch { }
        }
        let destination = tmp.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let link = tmp.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        do {
            _ = try await LivePhotoEngine.convert(input: src, outputDir: link,
                baseName: "PAIR", settings: ConversionSettings())
            XCTFail("Symlinked output directories must fail")
        } catch {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }

    func testCancellationLeavesSourceAndNoPair() async throws {
        let src = tmp.appendingPathComponent("source.mp4")
        try makeTestVideo(at: src)
        let original = try Data(contentsOf: src)
        let output = tmp.appendingPathComponent("cancelled")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LivePhotoEngine.convert(input: src, outputDir: output,
                baseName: "PAIR", settings: ConversionSettings())
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled conversion must fail")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try Data(contentsOf: src), original)
        }
    }

    func testAcceptsSymlinkedParentAndKeepsLeafSymlinkRejected() async throws {
        let src = tmp.appendingPathComponent("source.mp4")
        try makeTestVideo(at: src)
        let realParent = tmp.appendingPathComponent("real-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        let parentAlias = tmp.appendingPathComponent("parent-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parentAlias, withDestinationURL: realParent)

        // macOS commonly provides temporaryDirectory under the /var alias.
        // Resolve parent aliases while treating the requested leaf independently.
        let requested = parentAlias.appendingPathComponent("pair", isDirectory: true)
        let result = try await LivePhotoEngine.convert(input: src, outputDir: requested,
            baseName: "PAIR", settings: ConversionSettings())
        let expected = URL(fileURLWithPath: try physicalPath(realParent.appendingPathComponent("pair", isDirectory: true)),
                           isDirectory: true)
        XCTAssertEqual(result.imageURL.deletingLastPathComponent().path, expected.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: requested.appendingPathComponent("PAIR.JPG").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: requested.appendingPathComponent("PAIR.MOV").path))

        let leafAlias = parentAlias.appendingPathComponent("linked-pair", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: leafAlias, withDestinationURL: expected)
        let before = try Data(contentsOf: result.movURL)
        do {
            _ = try await LivePhotoEngine.convert(input: src, outputDir: leafAlias,
                baseName: "OTHER", settings: ConversionSettings())
            XCTFail("A leaf symlink must be rejected even below a parent alias")
        } catch {
            XCTAssertEqual(try Data(contentsOf: result.movURL), before)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: expected.path)),
                           Set(["PAIR.JPG", "PAIR.MOV"]))
        }
    }

    func testCreatesNestedMissingDirectoriesBelowSymlinkedParent() async throws {
        let source = tmp.appendingPathComponent("nested-source.mp4")
        try makeTestVideo(at: source)
        let original = try Data(contentsOf: source)
        let realParent = tmp.appendingPathComponent("nested-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        let parentAlias = tmp.appendingPathComponent("nested-parent-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parentAlias, withDestinationURL: realParent)
        let output = parentAlias.appendingPathComponent("missing/also-missing/pair", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        let result = try await LivePhotoEngine.convert(input: source, outputDir: output,
            baseName: "NESTED", settings: ConversionSettings())
        let expectedPath = try physicalPath(realParent.appendingPathComponent("missing/also-missing/pair", isDirectory: true))
        XCTAssertEqual(result.imageURL.deletingLastPathComponent().path, expectedPath)
        XCTAssertEqual(result.movURL.deletingLastPathComponent().path, expectedPath)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: expectedPath)),
                       Set(["NESTED.JPG", "NESTED.MOV"]))
        let checks = await Verifier.verify(imageURL: result.imageURL, movURL: result.movURL,
            expectedDuration: 1, expectedStillTime: result.stillTime, expectedAudio: false)
        for check in checks { XCTAssertEqual(check.status, .pass, "\(check.code): \(check.detail)") }
    }

    @MainActor
    func testTempStoreRemovesCanonicalOperationDirectory() async throws {
        let directory = try TempStore.makeOperationDirectory()
        defer { TempStore.removeDirectory(directory) }
        let canonical = URL(fileURLWithPath: try physicalPath(directory), isDirectory: true)
        XCTAssertEqual(directory.path, canonical.path)
        TempStore.removeDirectory(canonical)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func physicalPath(_ url: URL) throws -> String {
        guard let resolved = Darwin.realpath(url.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.free(resolved) }
        return String(cString: resolved)
    }

    private func stillMetadataRange(_ url: URL) async throws -> CMTimeRange {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else { throw reader.error ?? fail("metadata startReading") }
            while let group = adaptor.nextTimedMetadataGroup() {
                if group.items.contains(where: { ($0.key as? String) == LivePhotoEngine.keyStillImageTime }) {
                    return group.timeRange
                }
            }
            if reader.status == .failed { throw reader.error ?? fail("metadata read failed") }
        }
        throw fail("still-image-time metadata sample missing")
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { data in
            guard let context = CGContext(data: data.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw fail("Cannot create comparison context") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return bytes
    }

    /// Writes a short real H.264 .mp4 (solid frames) so the engine has something
    /// genuine to stream-copy.
    private func makeTestVideo(
        at url: URL, seconds: Double = 1.0, fps: Int = 30, width: Int = 320, height: Int = 240
    ) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        guard writer.canAdd(input) else { throw fail("cannot add writer input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? fail("startWriting") }
        writer.startSession(atSourceTime: .zero)

        for i in 0..<Int(seconds * Double(fps)) {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &pb)
            guard let buf = pb else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                // Adjacent frames must differ substantially: a wrong cover
                // frame must not pass the JPEG encoding-loss tolerance.
                memset(base, Int32(30 + (i * 67) % 200), CVPixelBufferGetDataSize(buf))
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            while !input.isReadyForMoreMediaData { usleep(2000) }
            adaptor.append(buf, withPresentationTime:
                CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? fail("finishWriting") }
    }

    private func fail(_ msg: String) -> NSError {
        NSError(domain: "ReviveTests", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
