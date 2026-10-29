import XCTest
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import Revive

final class StillMotionModelTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Revive-StillModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testImageImportPreparesRealPairAndExportsGIFWithoutChangingOriginal() async throws {
        let source = try makeImage()
        let original = try SafeExport.sha256(source)
        let model = AppModel()
        model.add(urls: [source, source])
        XCTAssertEqual(model.items.count, 1)
        let item = try XCTUnwrap(model.items.first)
        defer { item.invalidatePreview() }
        try await waitUntilLoaded(item)
        XCTAssertTrue(item.isStillImage)
        XCTAssertEqual(item.url.path, source.path)
        XCTAssertEqual(item.duration, 3)
        XCTAssertEqual(item.trimStart, 0)
        XCTAssertEqual(item.trimEnd, 3)
        XCTAssertNil(item.sourcePlaybackURL, "Import must not launch an untracked background encoder")
        let prepared = await model.convert(item)
        XCTAssertTrue(prepared, "Still-image preview failed: \(item.state)")
        guard prepared else { return }
        XCTAssertFalse(item.coverConfirmed)
        XCTAssertFalse(item.canDeliver)
        XCTAssertEqual(item.inputSHA256, original)
        XCTAssertNotNil(item.motionSourceURL)
        XCTAssertFalse(item.checks.isEmpty)
        XCTAssertTrue(item.checks.allSatisfy { $0.status == .pass })
        XCTAssertEqual(try SafeExport.sha256(source), original)
        let rejected = await model.exportAnimatedGIF(item, revealOutput: false)
        XCTAssertFalse(rejected, "GIF delivery must not bypass current cover confirmation")
        XCTAssertNil(item.gifExportURL)
        item.coverConfirmed = true
        let exported = await model.exportAnimatedGIF(item, revealOutput: false)
        XCTAssertTrue(exported, "GIF export failed: \(item.state)")
        guard exported else { return }
        let gif = try XCTUnwrap(item.gifExportURL)
        let folder = try XCTUnwrap(item.exportDirectory)
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("Revive_GIF_"))
        XCTAssertEqual(folder.deletingLastPathComponent().path, directory.path)
        XCTAssertEqual(gif.deletingLastPathComponent().path, folder.path)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(decoded), 1)
        let receipt = try report(in: folder)
        XCTAssertEqual(receipt["status"] as? String, "ANIMATED_GIF_VERIFIED")
        XCTAssertEqual(receipt["sourcePath"] as? String, source.path)
        XCTAssertEqual(receipt["sourceSHA256Before"] as? String, original)
        XCTAssertEqual(receipt["sourceSHA256After"] as? String, original)
        XCTAssertEqual(receipt["gifSHA256"] as? String, try SafeExport.sha256(gif))
        XCTAssertEqual(receipt["motionEffect"] as? String, "local_gentle_zoom_pan")
        XCTAssertEqual(receipt["generatedPersonMotion"] as? Bool, false)
        XCTAssertEqual(receipt["decodedFramesVerified"] as? Bool, true)
        XCTAssertEqual(receipt["frameCount"] as? Int, CGImageSourceGetCount(decoded))
        XCTAssertEqual(receipt["duration"] as? Double ?? 0, item.clipDuration, accuracy: 0.02)
        XCTAssertEqual(try SafeExport.sha256(source), original)
        XCTAssertEqual(model.activeOperations, 0)
    }

    @MainActor
    func testChangedImageIsRejectedBeforeGIFOutputDirectoryIsCreated() async throws {
        let source = try makeImage()
        let model = AppModel()
        model.add(urls: [source])
        let item = try XCTUnwrap(model.items.first)
        defer { item.invalidatePreview() }
        try await waitUntilLoaded(item)
        let prepared = await model.convert(item)
        XCTAssertTrue(prepared, "Still-image preview failed: \(item.state)")
        guard prepared else { return }
        item.coverConfirmed = true
        var changed = try Data(contentsOf: source)
        changed.append(0x42)
        try changed.write(to: source)
        let exported = await model.exportAnimatedGIF(item, revealOutput: false)
        XCTAssertFalse(exported)
        XCTAssertFalse(item.previewReady)
        XCTAssertFalse(item.coverConfirmed)
        XCTAssertNil(item.gifExportURL)
        XCTAssertNil(item.exportDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: source), changed, "Rejection must not rewrite the changed source")
        XCTAssertEqual(model.activeOperations, 0)
    }

    @MainActor
    func testImageLivePhotoDeliveryKeepsOriginalIdentityAndUsesNewSiblingFolder() async throws {
        let source = try makeImage()
        let original = try SafeExport.sha256(source)
        let model = AppModel()
        model.add(urls: [source])
        let item = try XCTUnwrap(model.items.first)
        defer { item.invalidatePreview() }
        try await waitUntilLoaded(item)
        let prepared = await model.convert(item)
        XCTAssertTrue(prepared, "Still-image preview failed: \(item.state)")
        guard prepared else { return }
        let pair = try XCTUnwrap(item.result)
        let previewedImageHash = try SafeExport.sha256(pair.imageURL)
        let previewedMovieHash = try SafeExport.sha256(pair.movURL)
        item.coverConfirmed = true
        await model.convertAndDeliver(item, to: .folder, revealOutput: false)
        XCTAssertEqual(item.state, .done)
        let folder = try XCTUnwrap(item.exportDirectory)
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("Revive_Live_"))
        XCTAssertEqual(folder.deletingLastPathComponent().path, directory.path)
        XCTAssertEqual(try SafeExport.sha256(folder.appendingPathComponent("IMG_LIVE.JPG")), previewedImageHash)
        XCTAssertEqual(try SafeExport.sha256(folder.appendingPathComponent("IMG_LIVE.MOV")), previewedMovieHash)
        let receipt = try report(in: folder)
        XCTAssertEqual(receipt["status"] as? String, "FILES_VERIFIED")
        XCTAssertEqual(receipt["sourceKind"] as? String, "still_image")
        XCTAssertEqual(receipt["motionEffect"] as? String, "local_gentle_zoom_pan")
        XCTAssertEqual(receipt["sourcePath"] as? String, source.path)
        XCTAssertEqual(receipt["sourceSHA256Before"] as? String, original)
        XCTAssertEqual(receipt["sourceSHA256After"] as? String, original)
        XCTAssertEqual(try SafeExport.sha256(source), original)
        XCTAssertEqual(model.activeOperations, 0)
    }

    @MainActor
    private func waitUntilLoaded(_ item: QueueItem) async throws {
        let deadline = Date().addingTimeInterval(10)
        while item.state == .loading, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(item.state, .ready)
        guard item.state == .ready else {
            throw NSError(domain: "ReviveStillMotionModelTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Image did not load: \(item.state)"])
        }
    }

    private func makeImage() throws -> URL {
        let url = directory.appendingPathComponent("TEST_still_model.png")
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 240,
            bitsPerComponent: 8, bytesPerRow: 320 * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        context.setFillColor(NSColor.systemOrange.cgColor)
        context.fill(CGRect(x: 30, y: 40, width: 140, height: 110))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 210, y: 70, width: 45, height: 140))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func report(in folder: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: folder.appendingPathComponent("检查报告.json"))) as? [String: Any])
    }
}
