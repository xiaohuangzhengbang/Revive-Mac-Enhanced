import XCTest
import AVFoundation
@testable import Revive

/// End-to-end tests for the conversion engine. Each test generates a real H.264
/// video on the fly (no fixture files in the repo), runs the engine, then checks
/// the output the same way the app does — via Verifier.
final class EngineTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviveTests-\(UUID().uuidString)")
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
                memset(base, Int32(30 + i * 3), CVPixelBufferGetDataSize(buf)) // changing shade
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
