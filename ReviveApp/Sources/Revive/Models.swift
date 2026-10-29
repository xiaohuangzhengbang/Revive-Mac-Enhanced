import SwiftUI
import AVFoundation
import AppKit
import os

enum ItemState: Equatable {
    case loading
    case ready
    case converting(String)
    case done
    case failed(String)
}

enum Destination: String, CaseIterable, Identifiable {
    case photoLibrary
    case folder
    var id: String { rawValue }
}

struct PreviewSettings: Equatable, Codable {
    let start: Double
    let end: Double
    let frame: Double
    let heic: Bool
    let exact: Bool
    let muted: Bool
}

@MainActor
final class QueueItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    @Published var duration: Double = 0
    @Published var thumbnail: NSImage?
    @Published var filmstrip: [NSImage] = []
    @Published var state: ItemState = .loading

    @Published var trimStart: Double = 0 { didSet { if oldValue != trimStart { invalidatePreview() } } }
    @Published var trimEnd: Double = 0 { didSet { if oldValue != trimEnd { invalidatePreview() } } }
    @Published var frameTime: Double = 0 { didSet { if oldValue != frameTime { invalidatePreview() } } }
    @Published var useHEIC = false { didSet { if oldValue != useHEIC { invalidatePreview() } } }
    @Published var exactTrim = true { didSet { if oldValue != exactTrim { invalidatePreview() } } }
    @Published var dropAudio = false { didSet { if oldValue != dropAudio { invalidatePreview() } } }

    @Published var result: ConversionResult?
    @Published var checks: [Check] = []
    @Published var savedToLibrary = false
    @Published var coverImage: NSImage?
    @Published var coverConfirmed = false
    @Published var previewReady = false
    @Published var previewToken: UUID?
    @Published var exportDirectory: URL?
    @Published var operationID: UUID?
    var preparedSettings: PreviewSettings?
    var inputSHA256: String?
    var imageSHA256: String?
    var movieSHA256: String?
    var expectedAudio: Bool?

    var clipDuration: Double { max(0, trimEnd - trimStart) }
    var snapshot: PreviewSettings {
        PreviewSettings(start: trimStart, end: trimEnd, frame: frameTime,
                        heic: useHEIC, exact: exactTrim, muted: dropAudio)
    }
    var canDeliver: Bool {
        previewReady && coverConfirmed && result != nil && preparedSettings == snapshot
            && !checks.isEmpty && checks.allSatisfy { $0.status == .pass } && operationID == nil
    }

    init(url: URL) {
        self.url = url.resolvingSymlinksInPath().standardizedFileURL
        Task { await load() }
    }

    func invalidatePreview() {
        coverConfirmed = false
        previewReady = false
        previewToken = nil
        operationID = nil
        coverImage = nil
        preparedSettings = nil
        inputSHA256 = nil
        imageSHA256 = nil
        movieSHA256 = nil
        expectedAudio = nil
        checks = []
        savedToLibrary = false
        exportDirectory = nil
        if let result { TempStore.remove(result) }
        result = nil
        if state == .done { state = .ready }
    }

    private func load() async {
        do {
            let asset = AVURLAsset(url: url)
            let length = try await asset.load(.duration).seconds
            guard length.isFinite, length >= 3 else {
                throw NSError(domain: "Revive", code: 1, userInfo: [NSLocalizedDescriptionKey: "原视频不足 3 秒或时长无效。"])
            }
            duration = length
            trimStart = max(0, (length - 3) / 2)
            trimEnd = trimStart + 3
            frameTime = 1.5
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            let time = CMTime(seconds: trimStart + frameTime, preferredTimescale: 600)
            let (image, _) = try await generator.image(at: time)
            thumbnail = NSImage(cgImage: image, size: .zero)
            state = .ready

            let strip = AVAssetImageGenerator(asset: asset)
            strip.appliesPreferredTrackTransform = true
            strip.maximumSize = CGSize(width: 160, height: 160)
            strip.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
            strip.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)
            var frames: [NSImage] = []
            for index in 0..<10 {
                let time = CMTime(seconds: length * (Double(index) + 0.5) / 10, preferredTimescale: 600)
                if let (image, _) = try? await strip.image(at: time) {
                    frames.append(NSImage(cgImage: image, size: .zero))
                }
            }
            filmstrip = frames
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func settings() -> ConversionSettings {
        ConversionSettings(trimStart: trimStart, trimEnd: trimEnd, frameTime: frameTime,
                           useHEIC: useHEIC, exactTrim: exactTrim, dropAudio: dropAudio)
    }
}

/// One process owns one random scratch root. Never sweep another running app.
@MainActor
enum TempStore {
    private static let session = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        .appendingPathComponent("Revive-\(UUID().uuidString)", isDirectory: true)
    private static var created = false

    static func makeOperationDirectory() throws -> URL {
        if !created {
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
            created = true
        }
        return try SafeExport.createOutputDirectory(parent: session, baseName: "Preview")
    }

    static func removeDirectory(_ directory: URL) {
        let path = directory.standardizedFileURL.path
        guard created, path.hasPrefix(session.path + "/"), directory.deletingLastPathComponent() == session else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    static func remove(_ result: ConversionResult) {
        let directory = result.imageURL.deletingLastPathComponent()
        guard directory == result.movURL.deletingLastPathComponent() else { return }
        removeDirectory(directory)
    }

    static func sweep() {
        guard created else { return }
        try? FileManager.default.removeItem(at: session)
        created = false
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var items: [QueueItem] = []
    @Published var selectionID: QueueItem.ID?
    @Published var isBatchRunning = false
    @Published var lastMessage: String?
    @Published var lastMessageIsError = false
    @Published var outputParent: URL?
    @Published private(set) var activeOperations = 0
    @Published private(set) var isClosing = false
    private var terminationReply: (() -> Void)?
    var selection: QueueItem? { items.first { $0.id == selectionID } }

    private func error(_ message: String) -> NSError {
        NSError(domain: "Revive", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func stillCurrent(_ item: QueueItem, operation: UUID, snapshot: PreviewSettings) -> Bool {
        items.contains { $0 === item } && item.operationID == operation && item.snapshot == snapshot
    }

    private func finishOperation(_ item: QueueItem, operation: UUID) {
        if item.operationID == operation { item.operationID = nil }
        activeOperations = max(0, activeOperations - 1)
        if activeOperations == 0, let reply = terminationReply {
            terminationReply = nil
            reply()
        }
    }

    func requestTermination(_ reply: @escaping () -> Void) {
        isClosing = true
        if activeOperations == 0 { reply() } else { terminationReply = reply }
    }

    func add(urls: [URL]) {
        guard !isClosing else { return }
        for url in urls where ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            let source = url.resolvingSymlinksInPath().standardizedFileURL
            guard !items.contains(where: { $0.url == source }) else { continue }
            items.append(QueueItem(url: source))
        }
        if selectionID == nil { selectionID = items.first?.id }
    }

    func remove(_ item: QueueItem) {
        guard item.operationID == nil, !isBatchRunning, !isClosing else {
            lastMessage = "当前任务完成后才能移除视频。"
            return
        }
        item.invalidatePreview()
        items.removeAll { $0.id == item.id }
        if selectionID == item.id { selectionID = items.first?.id }
    }

    func openPanel() {
        guard !isClosing else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    func chooseOutputParent() {
        guard activeOperations == 0, !isClosing else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择输出位置"
        if panel.runModal() == .OK { outputParent = panel.url }
    }

    /// Generate and verify an actual pair for the cover preview; delivery never regenerates it.
    func convert(_ item: QueueItem) async -> Bool {
        guard !isClosing, item.operationID == nil, items.contains(where: { $0 === item }) else { return false }
        let captured = item.snapshot
        guard captured.exact, !captured.heic else {
            item.state = .failed("当前增强版使用精准剪辑和 JPG/MOV 配对。")
            return false
        }
        guard [captured.start, captured.end, captured.frame].allSatisfy(\.isFinite),
              captured.start >= 0, captured.end > captured.start, captured.end <= item.duration,
              captured.frame >= 0, captured.frame < item.clipDuration else {
            item.state = .failed("请选择有效片段，并让封面位于片段内部。")
            return false
        }
        item.invalidatePreview()
        lastMessage = nil
        lastMessageIsError = false
        let operation = UUID()
        item.operationID = operation
        activeOperations += 1
        item.state = .converting("准备成片封面预览…")
        defer { finishOperation(item, operation: operation) }
        var folder: URL?
        do {
            let source = item.url
            let before = try await Task.detached(priority: .userInitiated) { try SafeExport.sha256(source) }.value
            guard stillCurrent(item, operation: operation, snapshot: captured) else { return false }
            let directory = try TempStore.makeOperationDirectory()
            folder = directory
            let result = try await LivePhotoEngine.convert(
                input: source, outputDir: directory, baseName: "IMG_LIVE", settings: item.settings(),
                progress: { key in
                    Task { @MainActor in
                        guard self.stillCurrent(item, operation: operation, snapshot: captured) else { return }
                        item.state = .converting(Localizer.shared.t(key))
                    }
                })
            guard stillCurrent(item, operation: operation, snapshot: captured) else {
                TempStore.removeDirectory(directory)
                return false
            }
            let sourceAsset = AVURLAsset(url: source)
            let expectedAudio = captured.muted ? false : !(try await sourceAsset.loadTracks(withMediaType: .audio)).isEmpty
            let checks = await Verifier.verify(imageURL: result.imageURL, movURL: result.movURL,
                                                expectedDuration: item.clipDuration, expectedStillTime: result.stillTime,
                                                expectedAudio: expectedAudio)
            let after = try await Task.detached(priority: .userInitiated) { try SafeExport.sha256(source) }.value
            guard stillCurrent(item, operation: operation, snapshot: captured) else {
                TempStore.removeDirectory(directory)
                return false
            }
            guard before == after else { throw error("原视频在预览期间发生变化，请重新选择。") }
            guard !checks.isEmpty, checks.allSatisfy({ $0.status == .pass }) else {
                item.checks = checks
                throw error("JPG/MOV 检查未通过，请展开检查明细。")
            }
            guard let cover = NSImage(contentsOf: result.imageURL) else { throw error("无法读取实际导出封面。") }
            let imageURL = result.imageURL
            let movURL = result.movURL
            let imageHash = try await Task.detached { try SafeExport.sha256(imageURL) }.value
            let movieHash = try await Task.detached { try SafeExport.sha256(movURL) }.value
            guard stillCurrent(item, operation: operation, snapshot: captured) else {
                TempStore.removeDirectory(directory)
                return false
            }
            item.result = result
            item.checks = checks
            item.coverImage = cover
            item.preparedSettings = captured
            item.inputSHA256 = before
            item.imageSHA256 = imageHash
            item.movieSHA256 = movieHash
            item.expectedAudio = expectedAudio
            item.coverConfirmed = false
            item.previewToken = operation
            item.previewReady = true
            item.state = .ready
            return true
        } catch {
            if let folder { TempStore.removeDirectory(folder) }
            guard stillCurrent(item, operation: operation, snapshot: captured) else { return false }
            item.previewReady = false
            item.coverConfirmed = false
            item.state = .failed(error.localizedDescription)
            return false
        }
    }

    func convertAndDeliver(_ item: QueueItem, to destination: Destination) async {
        guard !isClosing, !isBatchRunning else { return }
        await deliver(item, to: destination)
    }

    func convertAll(to destination: Destination) async {
        guard !isClosing, !isBatchRunning, !items.isEmpty else { return }
        guard items.allSatisfy(\.canDeliver) else {
            lastMessage = "请先逐个生成并确认当前封面，再批量导出。"
            return
        }
        isBatchRunning = true
        defer { isBatchRunning = false }
        for item in items {
            guard !isClosing else { break }
            await deliver(item, to: destination)
        }
    }

    private func deliver(_ item: QueueItem, to destination: Destination) async {
        guard item.canDeliver, let prepared = item.result,
              let expectedSourceHash = item.inputSHA256,
              let expectedImageHash = item.imageSHA256,
              let expectedMovieHash = item.movieSHA256,
              let expectedAudio = item.expectedAudio else {
            item.state = .failed("请先生成当前成片封面，查看原图并确认没有闭眼。")
            return
        }
        let captured = item.snapshot
        let operation = UUID()
        item.operationID = operation
        activeOperations += 1
        item.state = .converting("检查原片并写入新的输出文件夹…")
        defer { finishOperation(item, operation: operation) }
        let parent = outputParent ?? item.url.deletingLastPathComponent()
        var destinationFolder: URL?
        var receipt = ConversionReceipt(source: item.url, sourceSHA256: expectedSourceHash,
                                        settings: captured, result: prepared, expectedAudio: expectedAudio)
        do {
            let source = item.url
            let currentHash = try await Task.detached { try SafeExport.sha256(source) }.value
            guard stillCurrent(item, operation: operation, snapshot: captured) else { throw error("当前任务已失效。") }
            guard currentHash == expectedSourceHash else { throw error("原视频已改变，请重新预览并确认。") }
            let (imageHash, movieHash) = try await Task.detached {
                (try SafeExport.sha256(prepared.imageURL), try SafeExport.sha256(prepared.movURL))
            }.value
            guard stillCurrent(item, operation: operation, snapshot: captured) else { throw error("当前任务已失效。") }
            guard imageHash == expectedImageHash, movieHash == expectedMovieHash else {
                throw error("预览文件已经改变，请重新生成封面。")
            }
            let directory = try await Task.detached { try SafeExport.createOutputDirectory(parent: parent) }.value
            destinationFolder = directory
            guard stillCurrent(item, operation: operation, snapshot: captured) else { throw error("当前任务已失效。") }
            let pair = try await Task.detached { try SafeExport.copyPair(prepared, to: directory) }.value
            guard stillCurrent(item, operation: operation, snapshot: captured) else { throw error("当前任务已失效。") }
            let checks = await Verifier.verify(imageURL: pair.image, movURL: pair.mov,
                                                expectedDuration: item.clipDuration,
                                                expectedStillTime: prepared.stillTime,
                                                expectedAudio: expectedAudio)
            guard stillCurrent(item, operation: operation, snapshot: captured) else { throw error("当前任务已失效。") }
            guard !checks.isEmpty, checks.allSatisfy({ $0.status == .pass }) else {
                receipt.checks = checks
                throw error("输出文件复检未通过。")
            }
            let outputHashes = try await Task.detached {
                (try SafeExport.sha256(pair.image), try SafeExport.sha256(pair.mov))
            }.value
            guard stillCurrent(item, operation: operation, snapshot: captured) else { throw error("当前任务已失效。") }
            guard outputHashes.0 == expectedImageHash, outputHashes.1 == expectedMovieHash else { throw error("输出文件与预览不一致。") }
            let afterHash = try await Task.detached { try SafeExport.sha256(source) }.value
            guard stillCurrent(item, operation: operation, snapshot: captured) else { throw error("当前任务已失效。") }
            guard afterHash == expectedSourceHash else { throw error("原视频在导出期间发生变化。") }
            receipt.complete(sourceSHA256After: afterHash, checks: checks,
                             imageSHA256: expectedImageHash, movieSHA256: expectedMovieHash)
            let receiptData = try receipt.data()
            _ = try await Task.detached { try SafeExport.writeReport(receiptData, to: directory) }.value
            guard stillCurrent(item, operation: operation, snapshot: captured) else { throw error("当前任务已失效。") }
            item.checks = checks
            item.exportDirectory = directory
            lastMessageIsError = false
            lastMessage = "文件检查通过，已保存到新文件夹：\(directory.lastPathComponent)"
            if destination == .photoLibrary {
                // This external write happens only after the user's explicit Photos action.
                guard stillCurrent(item, operation: operation, snapshot: captured) else { throw error("当前任务已失效。") }
                item.state = .converting("文件已保存，正在加入照片图库…")
                do {
                    try await PhotoLibrarySaver.save(imageURL: pair.image, movURL: pair.mov)
                    guard stillCurrent(item, operation: operation, snapshot: captured) else { return }
                    item.savedToLibrary = true
                    item.state = .done
                    lastMessage = "已保存文件并加入照片图库；请在苹果设备确认 LIVE 播放。"
                } catch {
                    guard stillCurrent(item, operation: operation, snapshot: captured) else { return }
                    item.state = .failed("文件已保存；图库导入失败：\(error.localizedDescription)")
                    lastMessageIsError = true
                    lastMessage = "文件已保存到 \(directory.lastPathComponent)，图库导入失败。"
                }
            } else {
                item.state = .done
            }
            guard stillCurrent(item, operation: operation, snapshot: captured) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([pair.image, pair.mov])
        } catch {
            receipt.fail(error.localizedDescription)
            if let directory = destinationFolder {
                // If a completed immutable report already exists, leave it untouched.
                if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("检查报告.json").path),
                   let data = try? receipt.data() {
                    _ = try? SafeExport.writeReport(data, to: directory)
                }
            }
            item.state = .failed(error.localizedDescription)
            lastMessageIsError = true
            lastMessage = "导出未完成：\(error.localizedDescription)"
        }
    }
}
