import XCTest
@testable import Revive

final class SafeExportTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ReviveExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tmp)
    }

    func testSHA256ReadsRealFileWithoutChangingIt() throws {
        let source = tmp.appendingPathComponent("original.mov")
        let bytes = Data("abc".utf8)
        try bytes.write(to: source)
        XCTAssertEqual(try SafeExport.sha256(source), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testSHA256IncludesEveryChunkAndFinalPartialChunk() throws {
        let source = tmp.appendingPathComponent("large.mov")
        try Data(repeating: 0x61, count: 2 * 1024 * 1024 + 3).write(to: source)
        XCTAssertEqual(try SafeExport.sha256(source), "94444f79251aaf2956ac6d46ef04f4e1cb8aa188d97f21fecd00e068e2b235b2")
    }

    func testCreatesUniqueEmptyDirectoriesAndPreservesExistingFolder() throws {
        let old = tmp.appendingPathComponent("Revive_Live")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        let original = old.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: original)
        let first = try SafeExport.createOutputDirectory(parent: tmp)
        let second = try SafeExport.createOutputDirectory(parent: tmp)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, old)
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL.path, tmp.standardizedFileURL.path)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: first.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: original), Data("keep".utf8))
    }

    func testInvalidBaseNameCannotEscapeParent() throws {
        for name in ["", ".", "..", "../escape", "nested/name", "bad\0name"] {
            XCTAssertThrowsError(try SafeExport.createOutputDirectory(parent: tmp, baseName: name), name)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: tmp.path).isEmpty)
    }

    func testCopyPreservesBothSourcesAndUsesNewFiles() throws {
        let pair = try makePair()
        let destination = try SafeExport.createOutputDirectory(parent: tmp)
        let copied = try SafeExport.copyPair(pair, to: destination)
        XCTAssertEqual(try Data(contentsOf: copied.image), Data("photo bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: copied.mov), Data("movie bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: pair.imageURL), Data("photo bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: pair.movURL), Data("movie bytes".utf8))
        // Mutating an exported copy must never mutate the source through a hard link.
        try Data("edited export".utf8).write(to: copied.image)
        XCTAssertEqual(try Data(contentsOf: pair.imageURL), Data("photo bytes".utf8))
    }

    func testCollisionNeverOverwritesOrDeletesExistingFiles() throws {
        let pair = try makePair()
        let destination = try SafeExport.createOutputDirectory(parent: tmp)
        let collision = destination.appendingPathComponent(pair.movURL.lastPathComponent)
        try Data("existing movie".utf8).write(to: collision)
        XCTAssertThrowsError(try SafeExport.copyPair(pair, to: destination))
        XCTAssertEqual(try Data(contentsOf: collision), Data("existing movie".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(pair.imageURL.lastPathComponent).path))
        XCTAssertEqual(try Data(contentsOf: pair.imageURL), Data("photo bytes".utf8))
    }

    func testRejectsNonemptyDestinationEvenWithoutFilenameCollision() throws {
        let pair = try makePair()
        let destination = try SafeExport.createOutputDirectory(parent: tmp)
        let unrelated = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        XCTAssertThrowsError(try SafeExport.copyPair(pair, to: destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["keep.txt"])
    }

    func testRejectsSourceSymlinkAndLeavesTargetUnchanged() throws {
        let pair = try makePair()
        let alias = tmp.appendingPathComponent("alias.JPG")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: pair.imageURL)
        let linkedPair = ConversionResult(imageURL: alias, movURL: pair.movURL, assetID: pair.assetID,
                                          baseName: pair.baseName, clipDuration: pair.clipDuration, videoWasCopied: true)
        let destination = try SafeExport.createOutputDirectory(parent: tmp)
        XCTAssertThrowsError(try SafeExport.sha256(alias))
        XCTAssertThrowsError(try SafeExport.copyPair(linkedPair, to: destination))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: pair.imageURL), Data("photo bytes".utf8))
    }

    func testRejectsOutputDirectorySymlink() throws {
        let pair = try makePair()
        let real = try SafeExport.createOutputDirectory(parent: tmp)
        let alias = tmp.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        XCTAssertThrowsError(try SafeExport.createOutputDirectory(parent: alias))
        XCTAssertThrowsError(try SafeExport.copyPair(pair, to: alias))
        let directoryAlias = URL(fileURLWithPath: alias.path + "/", isDirectory: true)
        XCTAssertThrowsError(try SafeExport.createOutputDirectory(parent: directoryAlias))
        XCTAssertThrowsError(try SafeExport.copyPair(pair, to: directoryAlias))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
    }

    func testRejectsTwoNamesForSameSourceResource() throws {
        let pair = try makePair()
        try FileManager.default.removeItem(at: pair.movURL)
        try FileManager.default.linkItem(at: pair.imageURL, to: pair.movURL)
        let destination = try SafeExport.createOutputDirectory(parent: tmp)
        XCTAssertThrowsError(try SafeExport.copyPair(pair, to: destination))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    func testMissingSecondSourceLeavesNoPartialExport() throws {
        let pair = try makePair()
        try FileManager.default.removeItem(at: pair.movURL)
        let destination = try SafeExport.createOutputDirectory(parent: tmp)
        XCTAssertThrowsError(try SafeExport.copyPair(pair, to: destination))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: pair.imageURL), Data("photo bytes".utf8))
    }

    func testReportIsExclusiveAndDoesNotOverwriteExistingReport() throws {
        let destination = try SafeExport.createOutputDirectory(parent: tmp)
        let first = Data("{\"status\":\"FAILED\"}".utf8)
        let report = try SafeExport.writeReport(first, to: destination)
        XCTAssertEqual(report.lastPathComponent, "检查报告.json")
        XCTAssertThrowsError(try SafeExport.writeReport(Data("replacement".utf8), to: destination))
        XCTAssertEqual(try Data(contentsOf: report), first)
    }

    func testReportRejectsSymlinkWithoutChangingItsTarget() throws {
        let destination = try SafeExport.createOutputDirectory(parent: tmp)
        let protected = tmp.appendingPathComponent("protected.json")
        try Data("keep".utf8).write(to: protected)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("检查报告.json"),
                                                  withDestinationURL: protected)
        XCTAssertThrowsError(try SafeExport.writeReport(Data("new".utf8), to: destination))
        XCTAssertEqual(try Data(contentsOf: protected), Data("keep".utf8))
    }

    private func makePair() throws -> ConversionResult {
        let image = tmp.appendingPathComponent("IMG_TEST.JPG")
        let mov = tmp.appendingPathComponent("IMG_TEST.MOV")
        try Data("photo bytes".utf8).write(to: image)
        try Data("movie bytes".utf8).write(to: mov)
        return ConversionResult(imageURL: image, movURL: mov, assetID: "fixture", baseName: "IMG_TEST",
                                clipDuration: 1, videoWasCopied: true)
    }
}
