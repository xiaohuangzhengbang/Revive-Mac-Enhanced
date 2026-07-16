import SwiftUI
import AVFoundation
import AppKit

enum ItemState: Equatable {
    case loading
    case ready
    case converting(String)
    case done
    case failed(String)
}

enum Destination: String, CaseIterable, Identifiable {
    case photoLibrary   // label shown via Localizer ("dest_photos")
    case folder         // label shown via Localizer ("dest_folder")
    var id: String { rawValue }
}

@MainActor
final class QueueItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL

    @Published var duration: Double = 0
    @Published var thumbnail: NSImage?
    @Published var filmstrip: [NSImage] = []
    @Published var state: ItemState = .loading

    // editing settings
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var frameTime: Double = 0     // relative to trimStart
    @Published var useHEIC: Bool = false
    @Published var exactTrim: Bool = false
    @Published var dropAudio: Bool = false

    @Published var result: ConversionResult?
    @Published var checks: [Check] = []
    @Published var savedToLibrary = false

    var clipDuration: Double { max(0, trimEnd - trimStart) }

    init(url: URL) {
        self.url = url
        Task { await load() }
    }

    private func load() async {
        let asset = AVURLAsset(url: url)
        do {
            let d = try await asset.load(.duration).seconds
            duration = d
            trimEnd = d
            // default: middle 3 seconds when the video is longer
            if d > 3.0 {
                trimStart = max(0, (d - 3.0) / 2)
                trimEnd = trimStart + 3.0
            }
            frameTime = clipDuration / 2
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            let time = CMTime(seconds: min(trimStart + frameTime, d), preferredTimescale: 600)
            if let (cg, _) = try? await generator.image(at: time) {
                thumbnail = NSImage(cgImage: cg, size: .zero)
            }
            state = .ready

            // film-strip for the timeline scrubber
            let stripGen = AVAssetImageGenerator(asset: asset)
            stripGen.appliesPreferredTrackTransform = true
            stripGen.maximumSize = CGSize(width: 160, height: 160)
            stripGen.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
            stripGen.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)
            let frames = 10
            var strip: [NSImage] = []
            for i in 0..<frames {
                let ts = d * (Double(i) + 0.5) / Double(frames)
                if let (cg, _) = try? await stripGen.image(at: CMTime(seconds: ts, preferredTimescale: 600)) {
                    strip.append(NSImage(cgImage: cg, size: .zero))
                }
            }
            filmstrip = strip
        } catch {
            state = .failed("無法讀取:\(error.localizedDescription)")
        }
    }

    func settings() -> ConversionSettings {
        ConversionSettings(
            trimStart: trimStart, trimEnd: trimEnd,
            frameTime: frameTime, useHEIC: useHEIC, exactTrim: exactTrim,
            dropAudio: dropAudio
        )
    }
}

/// Owns the scratch directory that holds conversion intermediates. These are
/// full copies of the user's photo/video, so they must not linger in /tmp.
/// All members are nonisolated so cleanup can run from any context (launch,
/// app-quit notification, delivery completion).
enum TempStore {
    static var dir: URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("Revive", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Remove everything in the scratch dir (leftovers from a prior run/crash).
    static func sweep() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        for url in contents { try? fm.removeItem(at: url) }
    }

    /// Remove one conversion's output pair once it has been delivered.
    static func remove(_ result: ConversionResult) {
        try? FileManager.default.removeItem(at: result.imageURL)
        try? FileManager.default.removeItem(at: result.movURL)
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var items: [QueueItem] = []
    @Published var selectionID: QueueItem.ID?
    @Published var isBatchRunning = false
    @Published var lastMessage: String?

    var selection: QueueItem? { items.first { $0.id == selectionID } }

    var workDir: URL { TempStore.dir }

    init() {
        TempStore.sweep()  // clear anything left behind by a previous run
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            TempStore.sweep()  // belt-and-suspenders on a clean quit
        }
    }

    // MARK: queue management

    func add(urls: [URL]) {
        let videoExts = ["mp4", "mov", "m4v"]
        for url in urls where videoExts.contains(url.pathExtension.lowercased()) {
            guard !items.contains(where: { $0.url == url }) else { continue }
            items.append(QueueItem(url: url))
        }
        if selectionID == nil { selectionID = items.first?.id }
    }

    func remove(_ item: QueueItem) {
        if let result = item.result { TempStore.remove(result) }  // drop any undelivered temp pair
        items.removeAll { $0.id == item.id }
        if selectionID == item.id { selectionID = items.first?.id }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    private func freeBaseName() -> String {
        var name: String
        repeat {
            name = String(format: "IMG_%04d", Int.random(in: 0...9999))
        } while items.contains { $0.result?.baseName == name }
        return name
    }

    // MARK: conversion

    /// Convert one item into the temp work dir (does not deliver anywhere yet).
    func convert(_ item: QueueItem) async -> Bool {
        item.savedToLibrary = false
        item.state = .converting(Localizer.shared.t("converting"))
        do {
            let result = try await LivePhotoEngine.convert(
                input: item.url,
                outputDir: workDir,
                baseName: freeBaseName(),
                settings: item.settings(),
                progress: { key in
                    Task { @MainActor in item.state = .converting(Localizer.shared.t(key)) }
                }
            )
            item.result = result
            item.checks = await Verifier.verify(imageURL: result.imageURL, movURL: result.movURL)
            if item.checks.contains(where: { $0.status == .fail }) {
                item.state = .failed(Localizer.shared.t("verify_failed"))
                return false
            }
            item.state = .done
            return true
        } catch {
            item.state = .failed(error.localizedDescription)
            return false
        }
    }

    func convertAndDeliver(_ item: QueueItem, to destination: Destination) async {
        guard await convert(item), let result = item.result else { return }
        await deliver(items: [item], results: [result], to: destination)
    }

    func convertAll(to destination: Destination) async {
        isBatchRunning = true
        defer { isBatchRunning = false }
        var delivered: [QueueItem] = []
        var results: [ConversionResult] = []
        for item in items where item.state == .ready || isRetryable(item.state) {
            if await convert(item), let result = item.result {
                delivered.append(item)
                results.append(result)
            }
        }
        await deliver(items: delivered, results: results, to: destination)
    }

    private func isRetryable(_ state: ItemState) -> Bool {
        if case .failed = state { return true }
        if case .done = state { return true }
        return false
    }

    // MARK: delivery

    private func deliver(items delivered: [QueueItem], results: [ConversionResult], to destination: Destination) async {
        guard !results.isEmpty else { return }
        switch destination {
        case .photoLibrary:
            var saved = 0
            for (item, result) in zip(delivered, results) {
                do {
                    try await PhotoLibrarySaver.save(imageURL: result.imageURL, movURL: result.movURL)
                    item.savedToLibrary = true
                    TempStore.remove(result)  // Photos has its own copy now
                    saved += 1
                } catch {
                    item.state = .failed(error.localizedDescription)
                }
            }
            lastMessage = saved > 0 ? Localizer.shared.t("saved_n", saved) : nil
        case .folder:
            exportToFolder(results: results)
        }
    }

    func exportToFolder(results: [ConversionResult]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "匯出到這裡"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        var copied: [URL] = []
        do {
            for result in results {
                for src in [result.imageURL, result.movURL] {
                    let dst = dir.appendingPathComponent(src.lastPathComponent)
                    try? FileManager.default.removeItem(at: dst)
                    try FileManager.default.copyItem(at: src, to: dst)
                    copied.append(dst)
                }
            }
            results.forEach { TempStore.remove($0) }  // exported copies exist now
            lastMessage = Localizer.shared.t("exported_n", results.count, dir.lastPathComponent)
            NSWorkspace.shared.activateFileViewerSelecting(copied)
        } catch {
            lastMessage = Localizer.shared.t("export_failed", error.localizedDescription)
        }
    }
}
