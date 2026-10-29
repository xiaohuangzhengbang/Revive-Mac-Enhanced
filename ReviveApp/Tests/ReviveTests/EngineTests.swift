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

    func testLastCoverFrameHasReadableMarkerContainedInMovie() async throws {
        let source = tmp.appendingPathComponent("last-frame.mp4")
        try makeTestVideo(at: source)
        let original = try Data(contentsOf: source)
        var settings = ConversionSettings()
        settings.exactTrim = true
        settings.trimStart = 0.213
        settings.trimEnd = 0.902
        settings.frameTime = 0.688
        let result = try await LivePhotoEngine.convert(input: source,
            outputDir: tmp.appendingPathComponent("last-frame-pair"), baseName: "LAST", settings: settings)
        let marker = try await stillMetadataRange(result.movURL)
        XCTAssertEqual(marker.start.seconds, result.stillTime, accuracy: 0.001)
        XCTAssertGreaterThan(marker.duration.seconds, 0)
        XCTAssertLessThanOrEqual(marker.end.seconds, result.clipDuration + 0.0001)
        let checks = await Verifier.verify(imageURL: result.imageURL, movURL: result.movURL,
            expectedDuration: settings.trimEnd - settings.trimStart,
            expectedStillTime: result.stillTime, expectedAudio: false)
        for check in checks { XCTAssertEqual(check.status, .pass, "\(check.code): \(check.detail)") }
        XCTAssertEqual(try Data(contentsOf: source), original)
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

    func testFallbackDriverWaitsForReadinessAndResumesWithoutNativeCallback() async {
        // All fake source/sink state belongs to the production pump's queue.
        final class State: @unchecked Sendable {
            var ready = false
            var checks = 0
            var blockedChecks = 0
            var reads = 0
            var appends = 0
            var eof = 0
            var marks = 0
            var checksAtFinish = 0
            var groupNotifications = 0
        }
        let state = State()
        let group = DispatchGroup()
        let pump = LivePhotoEngine.WritePump(label: "test.write.driver.recovery", group: group)
        let initiallyBlocked = expectation(description: "two not-ready timer checks without reading")
        let sampleWritten = expectation(description: "ready transition writes one source buffer")
        let blockedAgain = expectation(description: "backpressure after the first buffer")
        let finished = expectation(description: "second unannounced ready transition reaches EOF")
        let quietAfterFinish = expectation(description: "finished driver remains stopped")
        pump.installFallbackDriver(interval: .milliseconds(20), shouldStop: { false }, isReady: {
            dispatchPrecondition(condition: .onQueue(pump.queue))
            state.checks += 1
            if !state.ready {
                state.blockedChecks += 1
                if state.blockedChecks == 2 {
                    if state.reads == 0 { initiallyBlocked.fulfill() }
                    else { blockedAgain.fulfill() }
                }
            }
            return state.ready
        }, drive: {
            dispatchPrecondition(condition: .onQueue(pump.queue))
            // The production driver itself must withhold this work when false.
            XCTAssertTrue(state.ready)
            state.reads += 1
            if state.reads == 1 {
                state.appends += 1
                state.ready = false
                state.blockedChecks = 0
                sampleWritten.fulfill()
            } else {
                state.eof += 1
                state.checksAtFinish = state.checks
                pump.finish { state.marks += 1 }
            }
        })
        group.notify(queue: pump.queue) {
            state.groupNotifications += 1
            finished.fulfill()
        }

        await fulfillment(of: [initiallyBlocked], timeout: 2)
        XCTAssertEqual(pump.queue.sync { state.reads }, 0)
        XCTAssertEqual(pump.queue.sync { state.appends }, 0)
        // Deliberately send no native readiness callback, only change readiness.
        pump.queue.async { state.ready = true }
        await fulfillment(of: [sampleWritten, blockedAgain], timeout: 2)
        XCTAssertEqual(pump.queue.sync { state.reads }, 1)
        XCTAssertEqual(pump.queue.sync { state.appends }, 1)
        pump.queue.async { state.ready = true }
        await fulfillment(of: [finished], timeout: 2)
        pump.queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
            pump.finish { state.marks += 1000 }
            XCTAssertEqual(state.reads, 2)
            XCTAssertEqual(state.appends, 1)
            XCTAssertEqual(state.eof, 1)
            XCTAssertEqual(state.marks, 1)
            XCTAssertEqual(state.checks, state.checksAtFinish)
            XCTAssertEqual(state.groupNotifications, 1)
            XCTAssertEqual(pump.snapshot(ready: state.ready)["fallbackTimerActive"] as? Bool, false)
            quietAfterFinish.fulfill()
        }
        await fulfillment(of: [quietAfterFinish], timeout: 2)
    }

    func testFallbackDriverStopsOnCancellationBeforeReadinessReturns() async {
        final class State: @unchecked Sendable {
            var ready = false
            var checks = 0
            var reads = 0
            var groupNotifications = 0
        }
        let state = State()
        let group = DispatchGroup()
        let pump = LivePhotoEngine.WritePump(label: "test.write.driver.cancel", group: group)
        let finishQueue = DispatchQueue(label: "test.write.driver.cancel.finish")
        let coordinator = LivePhotoEngine.FailureCoordinator(finishQueue: finishQueue)
        let initiallyBlocked = expectation(description: "driver checked readiness while blocked")
        let cancelled = expectation(description: "cancellation completed through safe drain")
        let drained = expectation(description: "input group leaves once on cancellation")
        let quietAfterCancellation = expectation(description: "cancelled driver remains stopped")
        pump.installFallbackDriver(interval: .milliseconds(20), shouldStop: { coordinator.shouldStop }, isReady: {
            dispatchPrecondition(condition: .onQueue(pump.queue))
            state.checks += 1
            if state.checks == 2 { initiallyBlocked.fulfill() }
            return state.ready
        }, drive: {
            state.reads += 1
            XCTFail("A cancelled input must never resume pulling source data")
        })
        coordinator.activate(pumps: [pump]) { error in
            guard case EngineError.cancelled = error else {
                XCTFail("Cancellation must remain the original failure"); cancelled.fulfill(); return
            }
            cancelled.fulfill()
        }
        group.notify(queue: pump.queue) {
            state.groupNotifications += 1
            drained.fulfill()
        }
        await fulfillment(of: [initiallyBlocked], timeout: 2)
        pump.queue.async {
            coordinator.fail(EngineError.cancelled)
            state.ready = true
        }
        await fulfillment(of: [cancelled, drained], timeout: 2)
        let checksAtCancellation = pump.queue.sync { state.checks }
        pump.queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
            XCTAssertTrue(pump.isFinished)
            XCTAssertEqual(state.reads, 0)
            XCTAssertEqual(state.checks, checksAtCancellation)
            XCTAssertEqual(state.groupNotifications, 1)
            XCTAssertEqual(pump.snapshot(ready: state.ready)["fallbackTimerActive"] as? Bool, false)
            quietAfterCancellation.fulfill()
        }
        await fulfillment(of: [quietAfterCancellation], timeout: 2)
    }

    func testFallbackDriverRejectsLateInstallationAndReleasesFinishedPump() async {
        final class Lifetime: @unchecked Sendable {
            weak var pump: LivePhotoEngine.WritePump?
            var checks = 0
        }
        let installed = expectation(description: "fallback timer was installed and ticked")
        let lateInstallChecked = expectation(description: "late installation remained stopped")
        let released = expectation(description: "finished timer releases its strongly captured pump")
        func exerciseLifetime() async -> Lifetime {
            let lifetime = Lifetime()
            let group = DispatchGroup()
            let pump = LivePhotoEngine.WritePump(label: "test.write.driver.lifetime", group: group)
            lifetime.pump = pump
            pump.installFallbackDriver(interval: .milliseconds(20), shouldStop: { false }, isReady: {
                lifetime.checks += 1
                if lifetime.checks == 1 { installed.fulfill() }
                return false
            }, drive: {
                // Deliberately establish timer -> drive -> pump ownership.
                // finish must clear the handler, rather than rely on weak self.
                pump.finish()
            })
            await fulfillment(of: [installed], timeout: 2)
            pump.queue.async {
                pump.finish()
                pump.installFallbackDriver(interval: .milliseconds(20), shouldStop: { false },
                                           isReady: { true }, drive: { pump.finish() })
                pump.queue.async {
                    XCTAssertEqual(pump.snapshot(ready: true)["fallbackTimerActive"] as? Bool, false)
                    lateInstallChecked.fulfill()
                }
            }
            await fulfillment(of: [lateInstallChecked], timeout: 2)
            return lifetime
        }
        let lifetime = await exerciseLifetime()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            XCTAssertNil(lifetime.pump, "A finished driver must not retain the native operation")
            released.fulfill()
        }
        await fulfillment(of: [released], timeout: 2)
    }

    func testWriteFailureDrainsNeverReadyPumpAndPreservesFirstError() async {
        let finishQueue = DispatchQueue(label: "test.write.failure.finish")
        let group = DispatchGroup()
        let video = LivePhotoEngine.WritePump(label: "test.write.failure.video", group: group)
        // This input never invokes a readiness callback. Stopping must not wait
        // for AVFoundation to make it ready after another input has failed.
        let neverReady = LivePhotoEngine.WritePump(label: "test.write.failure.never-ready", group: group)
        let coordinator = LivePhotoEngine.FailureCoordinator(finishQueue: finishQueue)
        let stopped = expectation(description: "failure completed after both queues drained")
        let drained = expectation(description: "all input group entries left")
        var failureCount = 0
        let first = NSError(domain: "first-append", code: 17)
        coordinator.activate(pumps: [video, neverReady]) { error in
            failureCount += 1
            XCTAssertEqual((error as NSError).domain, first.domain)
            XCTAssertEqual((error as NSError).code, first.code)
            stopped.fulfill()
        }
        group.notify(queue: finishQueue) { drained.fulfill() }
        video.queue.async {
            coordinator.fail(first)
            coordinator.fail(NSError(domain: "later-timeout", code: 120))
        }
        await fulfillment(of: [stopped, drained], timeout: 2)
        XCTAssertTrue(video.queue.sync { video.isFinished })
        XCTAssertTrue(neverReady.queue.sync { neverReady.isFinished })
        XCTAssertEqual(finishQueue.sync { failureCount }, 1)
        XCTAssertFalse(coordinator.finishSuccessfully { XCTFail("A failed writer cannot succeed") })
    }

    func testWriteCancellationBeforeSetupWaitsForEveryPump() async {
        let finishQueue = DispatchQueue(label: "test.write.pre-setup.finish")
        let coordinator = LivePhotoEngine.FailureCoordinator(finishQueue: finishQueue)
        coordinator.fail(EngineError.cancelled)
        XCTAssertTrue(coordinator.shouldStop)
        let group = DispatchGroup()
        let first = LivePhotoEngine.WritePump(label: "test.write.pre-setup.first", group: group)
        let last = LivePhotoEngine.WritePump(label: "test.write.pre-setup.last", group: group)
        let stopped = expectation(description: "pre-setup cancellation completed")
        let drained = expectation(description: "complete setup was drained")
        var failureCount = 0
        coordinator.activate(pumps: [first, last]) { error in
            failureCount += 1
            guard case EngineError.cancelled = error else {
                XCTFail("The original cancellation must be preserved"); stopped.fulfill(); return
            }
            stopped.fulfill()
        }
        group.notify(queue: finishQueue) { drained.fulfill() }
        coordinator.fail(NSError(domain: "later-append", code: 1))
        await fulfillment(of: [stopped, drained], timeout: 2)
        XCTAssertTrue(first.queue.sync { first.isFinished })
        XCTAssertTrue(last.queue.sync { last.isFinished })
        XCTAssertEqual(finishQueue.sync { failureCount }, 1)
    }

    func testWriteCancellationDuringEOFLeavesEachPumpOnce() async {
        let finishQueue = DispatchQueue(label: "test.write.eof.finish")
        let group = DispatchGroup()
        let eof = LivePhotoEngine.WritePump(label: "test.write.eof.input", group: group)
        let neverReady = LivePhotoEngine.WritePump(label: "test.write.eof.never-ready", group: group)
        let coordinator = LivePhotoEngine.FailureCoordinator(finishQueue: finishQueue)
        let stopped = expectation(description: "EOF cancellation completed")
        let drained = expectation(description: "EOF and stop share one group leave")
        var failureCount = 0
        coordinator.activate(pumps: [eof, neverReady]) { _ in
            failureCount += 1
            stopped.fulfill()
        }
        group.notify(queue: finishQueue) {
            XCTAssertFalse(coordinator.finishSuccessfully { XCTFail("Cancellation won before EOF left") })
            drained.fulfill()
        }
        eof.queue.async {
            eof.finish {
                // Stop is requested while EOF completion is still on the input
                // queue. Its queued stop must not leave this input a second time.
                coordinator.fail(EngineError.cancelled)
            }
        }
        await fulfillment(of: [stopped, drained], timeout: 2)
        XCTAssertEqual(finishQueue.sync { failureCount }, 1)
    }

    func testWriteSuccessfulFinishRejectsLateCancellation() async {
        let finishQueue = DispatchQueue(label: "test.write.success.finish")
        let coordinator = LivePhotoEngine.FailureCoordinator(finishQueue: finishQueue)
        let finished = expectation(description: "successful completion wins once")
        var failureCount = 0
        var successCount = 0
        coordinator.activate(pumps: []) { _ in failureCount += 1 }
        finishQueue.async {
            XCTAssertTrue(coordinator.finishSuccessfully { successCount += 1 })
            coordinator.fail(EngineError.cancelled)
            XCTAssertFalse(coordinator.finishSuccessfully { successCount += 1 })
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(finishQueue.sync { successCount }, 1)
        XCTAssertEqual(finishQueue.sync { failureCount }, 0)
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
