import XCTest
import AVFoundation
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
        XCTAssertTrue(prepared)
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
}
