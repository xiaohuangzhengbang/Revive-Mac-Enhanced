import XCTest
import AVFoundation
import Darwin
@testable import Revive

final class ModelParityTests: XCTestCase {
    @MainActor
    func testDefaultsAreExactJPGAndConfirmationIsInitiallyFalse() async {
        let item = QueueItem(url: URL(fileURLWithPath: "/nonexistent/revive-test.mp4"))
        XCTAssertTrue(item.exactTrim)
        XCTAssertFalse(item.useHEIC)
        XCTAssertFalse(item.coverConfirmed)
        XCTAssertFalse(item.canDeliver)
    }

    @MainActor
    func testChangedSettingsInvalidateCoverAndOperationIdentity() async {
        let item = QueueItem(url: URL(fileURLWithPath: "/nonexistent/revive-test.mp4"))
        item.coverConfirmed = true
        item.previewReady = true
        item.previewToken = UUID()
        item.operationID = UUID()
        item.preparedSettings = item.snapshot
        item.frameTime = 1.25
        XCTAssertFalse(item.coverConfirmed)
        XCTAssertFalse(item.previewReady)
        XCTAssertNil(item.previewToken)
        XCTAssertNil(item.operationID)
        XCTAssertNil(item.preparedSettings)
        XCTAssertFalse(item.canDeliver)
    }

    @MainActor
    func testClosingModelRejectsNewInput() async {
        let model = AppModel()
        var replied = false
        model.requestTermination { replied = true }
        XCTAssertTrue(replied)
        XCTAssertTrue(model.isClosing)
        model.add(urls: [URL(fileURLWithPath: "/nonexistent/revive-test.mp4")])
        XCTAssertTrue(model.items.isEmpty)
    }

    @MainActor
    func testActualPreparedPairRequiresConfirmationAndSourceStaysUnchanged() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "TEST_synthetic_six_seconds", withExtension: "mp4", subdirectory: "Fixtures"))
        let originalHash = try SafeExport.sha256(source)
        let model = AppModel()
        model.add(urls: [source])
        let item = try XCTUnwrap(model.items.first)
        let deadline = Date().addingTimeInterval(20)
        while item.state == .loading && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(item.state, .ready)
        item.trimStart = 1.11
        item.trimEnd = 4.11
        item.frameTime = 1.49
        let prepared = await model.convert(item)
        XCTAssertTrue(prepared, "Actual preview conversion failed: \(item.state); checks: \(item.checks)")
        defer { item.invalidatePreview() }
        XCTAssertTrue(item.previewReady)
        XCTAssertNotNil(item.coverImage)
        XCTAssertFalse(item.coverConfirmed)
        XCTAssertFalse(item.canDeliver)
        XCTAssertFalse(item.checks.isEmpty)
        XCTAssertTrue(item.checks.allSatisfy { $0.status == .pass })
        let result = try XCTUnwrap(item.result)
        XCTAssertEqual(result.clipDuration, 3, accuracy: 1.0 / 30 + 0.002)
        XCTAssertEqual(item.inputSHA256, originalHash)
        XCTAssertEqual(try SafeExport.sha256(source), originalHash)
        item.coverConfirmed = true
        XCTAssertTrue(item.canDeliver)
        item.operationID = UUID()
        XCTAssertFalse(item.canDeliver)
        item.operationID = nil
        item.trimStart = 1.2
        XCTAssertFalse(item.canDeliver)
        XCTAssertNil(item.result)
        XCTAssertEqual(try SafeExport.sha256(source), originalHash)
    }

    @MainActor
    func testRepeatedNativePreviewsKeepProducingVerifiedPairs() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "TEST_synthetic_six_seconds",
            withExtension: "mp4", subdirectory: "Fixtures"))
        let original = try SafeExport.sha256(source)
        var iterations = 6
        var reuseItem = false
        var traceDirectory: String?
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["REVIVE_STRESS_ITERATIONS"] {
            guard let count = Int(configured), (1...1000).contains(count) else {
                XCTFail("REVIVE_STRESS_ITERATIONS must be an integer in 1...1000")
                return
            }
            iterations = count
        }
        reuseItem = environment["REVIVE_STRESS_REUSE_ITEM"] == "1"
        traceDirectory = environment["REVIVE_WRITER_TRACE_DIR"]
        #endif

        let stressID = UUID().uuidString
        let startedAt = ProcessInfo.processInfo.systemUptime
        let reusedModel = reuseItem ? AppModel() : nil
        var traceHandle: FileHandle?
        if let directory = traceDirectory, !directory.isEmpty {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let traceURL = root.appendingPathComponent("StressIterations.jsonl")
            if !FileManager.default.fileExists(atPath: traceURL.path) {
                guard FileManager.default.createFile(atPath: traceURL.path, contents: nil) else {
                    throw NSError(domain: "ReviveStressTrace", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Cannot create stress iteration trace"])
                }
            }
            traceHandle = try FileHandle(forWritingTo: traceURL)
            try traceHandle?.seekToEnd()
        }
        defer { try? traceHandle?.close() }

        func trace(_ event: String, iteration: Int, iterationStartedAt: TimeInterval,
                   detail: String? = nil) throws {
            let now = ProcessInfo.processInfo.systemUptime
            var entry: [String: Any] = [
                "event": event, "stressID": stressID, "iteration": iteration,
                "totalIterations": iterations, "reuseItem": reuseItem,
                "elapsedSeconds": now - startedAt,
                "iterationSeconds": now - iterationStartedAt,
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

        for iteration in 1...iterations {
            let iterationStartedAt = ProcessInfo.processInfo.systemUptime
            try trace("start", iteration: iteration, iterationStartedAt: iterationStartedAt)
            do {
                let model = reusedModel ?? AppModel()
                if model.items.isEmpty { model.add(urls: [source]) }
                let item = try XCTUnwrap(model.items.first)
                defer { item.invalidatePreview() }
                let deadline = Date().addingTimeInterval(20)
                while item.state == .loading && Date() < deadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                XCTAssertEqual(item.state, .ready)
                guard item.state == .ready else {
                    try trace("failed", iteration: iteration, iterationStartedAt: iterationStartedAt,
                              detail: "Source did not become ready: \(item.state)")
                    return
                }
                item.trimStart = 1.11
                item.trimEnd = 4.11
                item.frameTime = 1.49
                let prepared = await model.convert(item)
                guard prepared else {
                    let detail = "Native preview iteration \(iteration): \(item.state); checks=\(item.checks)"
                    XCTFail(detail)
                    try trace("failed", iteration: iteration, iterationStartedAt: iterationStartedAt, detail: detail)
                    return
                }
                let previewReady = item.previewReady
                let checksPresent = !item.checks.isEmpty
                let checksPassed = item.checks.allSatisfy { $0.status == .pass }
                let currentHash = try SafeExport.sha256(source)
                XCTAssertTrue(previewReady)
                XCTAssertTrue(checksPresent)
                XCTAssertTrue(checksPassed)
                XCTAssertEqual(currentHash, original)
                guard previewReady, checksPresent, checksPassed, currentHash == original else {
                    try trace("failed", iteration: iteration, iterationStartedAt: iterationStartedAt,
                              detail: "Preview, verification checks or original source hash failed")
                    return
                }
                try trace("finish", iteration: iteration, iterationStartedAt: iterationStartedAt)
            } catch {
                try trace("failed", iteration: iteration, iterationStartedAt: iterationStartedAt,
                          detail: error.localizedDescription)
                throw error
            }
        }
    }

    func testReceiptDoesNotCallEmptyOrWarningChecksAFilePass() throws {
        let result = ConversionResult(imageURL: URL(fileURLWithPath: "/test/IMG_LIVE.JPG"),
                                      movURL: URL(fileURLWithPath: "/test/IMG_LIVE.MOV"), assetID: UUID().uuidString,
                                      baseName: "IMG_LIVE", clipDuration: 3, videoWasCopied: false, stillTime: 1.5)
        let settings = PreviewSettings(start: 0, end: 3, frame: 1.5, heic: false, exact: true, muted: false)
        var receipt = ConversionReceipt(source: URL(fileURLWithPath: "/test/source.mp4"), sourceSHA256: "original",
                                        settings: settings, result: result, expectedAudio: true)
        receipt.complete(sourceSHA256After: "original", checks: [], imageSHA256: "jpg", movieSHA256: "mov")
        XCTAssertEqual(receipt.status, "FAILED")
        receipt.complete(sourceSHA256After: "original", checks: [Check(status: .warn, label: "unknown", detail: "unknown")],
                         imageSHA256: "jpg", movieSHA256: "mov")
        XCTAssertEqual(receipt.status, "FAILED")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: receipt.data()) as? [String: Any])
        XCTAssertEqual(json["automaticEyeDetection"] as? Bool, false)
        XCTAssertEqual(json["applePhotosLivePlaybackVerified"] as? Bool, false)
    }

    @MainActor
    func testConfirmedPreviewExportsVerifiedPairTwiceWithoutOverwriting() async throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "TEST_synthetic_six_seconds",
                                                     withExtension: "mp4", subdirectory: "Fixtures"))
        let sourceHash = try SafeExport.sha256(source)
        let outputRoot = try SafeExport.createOutputDirectory(
            parent: FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
            baseName: "ModelParityTests")
        defer { try? FileManager.default.removeItem(at: outputRoot) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outputRoot.path).isEmpty)

        let model = AppModel()
        model.outputParent = outputRoot
        model.add(urls: [source])
        let item = try XCTUnwrap(model.items.first)
        defer { item.invalidatePreview() }
        let deadline = Date().addingTimeInterval(20)
        while item.state == .loading && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(item.state, .ready)
        item.trimStart = 1.11
        item.trimEnd = 4.11
        item.frameTime = 1.49
        let converted = await model.convert(item)
        XCTAssertTrue(converted, "Actual preview conversion failed: \(item.state)")
        let preview = try XCTUnwrap(item.result)
        let previewImageHash = try SafeExport.sha256(preview.imageURL)
        let previewMovieHash = try SafeExport.sha256(preview.movURL)
        XCTAssertEqual(item.imageSHA256, previewImageHash)
        XCTAssertEqual(item.movieSHA256, previewMovieHash)
        XCTAssertFalse(item.canDeliver)

        // Synthetic test confirmation exercises the real delivery gate; it is
        // not a claim that a human inspected a real person's eyes.
        item.coverConfirmed = true
        XCTAssertTrue(item.canDeliver)

        func exportedEntries(_ directory: URL) throws -> Set<String> {
            // Delivery intentionally reveals its files in Finder. Finder can
            // write this view-state file asynchronously, including on CI.
            // Keep every other unexpected file visible to the assertions.
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0 != ".DS_Store" })
        }

        func inspectExport(_ directory: URL) throws -> Data {
            XCTAssertEqual(directory.deletingLastPathComponent().path, outputRoot.path)
            XCTAssertNotEqual(directory.path, preview.imageURL.deletingLastPathComponent().path)
            let image = directory.appendingPathComponent("IMG_LIVE.JPG")
            let movie = directory.appendingPathComponent("IMG_LIVE.MOV")
            let report = directory.appendingPathComponent("检查报告.json")
            XCTAssertEqual(try exportedEntries(directory),
                           Set(["IMG_LIVE.JPG", "IMG_LIVE.MOV", "检查报告.json"]))
            XCTAssertEqual(try SafeExport.sha256(image), previewImageHash)
            XCTAssertEqual(try SafeExport.sha256(movie), previewMovieHash)
            let reportData = try Data(contentsOf: report)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: reportData) as? [String: Any])
            XCTAssertEqual(json["status"] as? String, "FILES_VERIFIED")
            XCTAssertEqual(json["inputUnchanged"] as? Bool, true)
            XCTAssertEqual(json["sourceSHA256Before"] as? String, sourceHash)
            XCTAssertEqual(json["sourceSHA256After"] as? String, sourceHash)
            XCTAssertEqual(json["imageSHA256"] as? String, previewImageHash)
            XCTAssertEqual(json["movieSHA256"] as? String, previewMovieHash)
            XCTAssertEqual(json["assetIdentifier"] as? String, preview.assetID)
            XCTAssertEqual(json["coverHumanConfirmed"] as? Bool, true)
            XCTAssertEqual(json["previewedPairReused"] as? Bool, true)
            XCTAssertEqual(json["applePhotosLivePlaybackVerified"] as? Bool, false)
            let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
            XCTAssertFalse(checks.isEmpty)
            XCTAssertTrue(checks.allSatisfy { $0["status"] as? String == "pass" })
            return reportData
        }

        await model.convertAndDeliver(item, to: .folder)
        XCTAssertEqual(item.state, .done)
        XCTAssertEqual(model.activeOperations, 0)
        XCTAssertFalse(item.savedToLibrary)
        let first = try XCTUnwrap(item.exportDirectory)
        let firstReport = try inspectExport(first)
        XCTAssertEqual(try SafeExport.sha256(source), sourceHash)
        XCTAssertTrue(item.canDeliver)

        await model.convertAndDeliver(item, to: .folder)
        XCTAssertEqual(item.state, .done)
        XCTAssertEqual(model.activeOperations, 0)
        XCTAssertFalse(item.savedToLibrary)
        let second = try XCTUnwrap(item.exportDirectory)
        XCTAssertNotEqual(second.path, first.path)
        _ = try inspectExport(second)
        XCTAssertEqual(try inspectExport(first), firstReport, "Second export must preserve the first report and pair")
        XCTAssertEqual(try exportedEntries(outputRoot),
                       Set([first.lastPathComponent, second.lastPathComponent]))
        XCTAssertEqual(try SafeExport.sha256(source), sourceHash)
        XCTAssertEqual(try SafeExport.sha256(preview.imageURL), previewImageHash)
        XCTAssertEqual(try SafeExport.sha256(preview.movURL), previewMovieHash)
        XCTAssertEqual(item.result?.assetID, preview.assetID)
    }
}
