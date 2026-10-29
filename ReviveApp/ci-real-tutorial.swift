// CI-only entry point. Compiled with the unchanged production view/model/engine
// sources, excluding Main.swift. This file is never part of the delivered app.
import SwiftUI
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreText
import ImageIO

private func tutorialError(_ message: String) -> NSError {
    NSError(domain: "ReviveRealTutorial", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func tutorialLog(_ message: String) {
    print(message)
    fflush(stdout)
}

@available(macOS 15.0, *)
final class TutorialRecorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    private(set) var stream: SCStream?
    private(set) var output: SCRecordingOutput?
    private(set) var filter: SCContentFilter?
    private(set) var configuration: SCStreamConfiguration?
    private let lock = NSLock()
    private var hasStarted = false
    private var hasFinished = false
    private var failure: Error?

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        tutorialLog("SCK delegate: recording started")
        lock.lock(); hasStarted = true; lock.unlock()
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        tutorialLog("SCK delegate: recording finished")
        lock.lock(); hasFinished = true; lock.unlock()
    }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        tutorialLog("SCK delegate failure: \(error.localizedDescription)")
        lock.lock(); failure = error; lock.unlock()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        tutorialLog("SCK stream failure: \(error.localizedDescription)")
        lock.lock(); failure = error; lock.unlock()
    }
    private func state() -> (Bool, Bool, Error?) {
        lock.lock(); defer { lock.unlock() }
        return (hasStarted, hasFinished, failure)
    }

    func start(to url: URL?) async throws {
        tutorialLog("SCK preflight: \(CGPreflightScreenCaptureAccess()); bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
        tutorialLog("SCK awaiting shareable content")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        tutorialLog("SCK shareable content: \(content.displays.count) displays; \(content.windows.count) windows")
        guard let display = content.displays.first else { throw tutorialError("No capturable desktop display") }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = false
        self.filter = filter; self.configuration = configuration
        guard let url else {
            tutorialLog("SCK screenshot-only mode: no SCStream or SCRecordingOutput encoding is active")
            return
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mp4
        recording.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        try stream.addRecordingOutput(output)
        self.stream = stream; self.output = output
        tutorialLog("SCK startCapture: \(display.width)x\(display.height) -> \(url.lastPathComponent)")
        try await stream.startCapture()
        tutorialLog("SCK startCapture returned; awaiting recording delegate")
        for _ in 0..<100 {
            let status = state()
            if let failure = status.2 { throw failure }
            if status.0 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw tutorialError("ScreenCaptureKit did not start recording within 10 seconds")
    }

    func screenshot(to url: URL) async throws {
        guard let filter, let configuration else { throw tutorialError("Recorder not configured") }
        tutorialLog("SCK screenshot: \(url.lastPathComponent)")
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let target = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw tutorialError("Cannot create native screenshot")
        }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw tutorialError("Cannot finalize native screenshot") }
    }

    func stop() async throws -> Double {
        guard let stream, let output else { throw tutorialError("Recorder not running") }
        tutorialLog("SCK stopCapture begin")
        try await stream.stopCapture()
        tutorialLog("SCK stopCapture returned; awaiting file finalization")
        for _ in 0..<100 {
            let status = state()
            if let failure = status.2 { throw failure }
            if status.1 { return output.recordedDuration.seconds }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw tutorialError("ScreenCaptureKit did not finish recording within 10 seconds")
    }
}

@available(macOS 15.0, *)
@MainActor
final class RealTutorial: ObservableObject {
    static let shared = RealTutorial()
    private var didRun = false
    private var started = Date()
    private var events: [[String: Any]] = []
    private let recorder = TutorialRecorder()
    private var root: URL!
    private var window: NSWindow!
    private var model: AppModel { AppModel.shared }
    private let recordingRequired = ProcessInfo.processInfo.environment["REVIVE_TUTORIAL_RECORDING"] != "0"
    private var currentItem: QueueItem?
    private var initialScratchNames = Set<String>()
    private var scratchRoots: [String: URL] = [:]
    private var waitSamples: [[String: Any]] = []

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    private func event(_ step: String, _ detail: String, additional: [String: Any] = [:]) {
        var value: [String: Any] = ["seconds": Date().timeIntervalSince(started), "step": step, "title": detail, "detail": detail]
        for (key, item) in additional { value[key] = item }
        events.append(value)
        print("TUTORIAL \(step): \(detail)")
        fflush(stdout)
    }
    private func saveJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
    private func descendants(_ object: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 32, let ax = object as? any NSAccessibilityProtocol else { return [] }
        return [ax] + (ax.accessibilityChildren() ?? []).flatMap { descendants($0, depth: depth + 1) }
    }
    private func axText(_ object: any NSAccessibilityProtocol) -> String {
        [object.accessibilityTitle(), object.accessibilityLabel(), object.accessibilityHelp()]
            .compactMap { $0 }.joined(separator: " ")
    }
    private func controls() -> [any NSAccessibilityProtocol] {
        NSApp.windows.filter { $0.isVisible }.flatMap { descendants($0) }
    }
    private func dumpAccessibility() throws {
        let rows = controls().map { ["role": $0.accessibilityRole()?.rawValue ?? "", "text": axText($0), "enabled": String($0.isAccessibilityEnabled())] }
        try saveJSON(rows, to: root.appendingPathComponent("Accessibility.json"))
    }
    private func scrollEditor(bottom: Bool) {
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.frame.width > 450,
               let document = scroll.documentView, document.bounds.height > scroll.contentView.bounds.height {
                let lower = max(0, document.bounds.height - scroll.contentView.bounds.height)
                let y: CGFloat = document.isFlipped ? (bottom ? lower : 0) : (bottom ? 0 : lower)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            for child in view.subviews { visit(child) }
        }
        if let view = window.contentView { visit(view); view.layoutSubtreeIfNeeded() }
    }
    private func press(_ key: String) async throws {
        let title = Localizer.shared.t(key)
        var remoteDiagnostic: [String: Any] = [:]
        for _ in 0..<25 {
            let candidates = controls().filter { ax in
                let role = ax.accessibilityRole()
                return (role == .button || role == .checkBox) && ax.isAccessibilityEnabled()
                    && (axText(ax).contains(title) || (ax.accessibilityChildren() ?? []).contains { child in
                        guard let child = child as? any NSAccessibilityProtocol else { return false }
                        return axText(child).contains(title)
                    })
            }
            if let button = candidates.first {
                event("ui.press", title, additional: ["mechanism": "NSAccessibility.accessibilityPerformPress", "localizationKey": key])
                guard button.accessibilityPerformPress() else { throw tutorialError("Control rejected press: \(title)") }
                try await pause(0.5)
                return
            }
            // SwiftUI's virtual accessibility children need not formally adopt
            // NSAccessibilityProtocol. Ask a genuinely separate AX helper
            // process, so SwiftUI dispatches requests onto this app's main loop.
            // AXPress still invokes the actual control; no model action is used.
            let remote = await Task.detached(priority: .userInitiated) {
                Self.remotePress(title: title)
            }.value
            remoteDiagnostic = remote
            if remote["pressed"] as? Bool == true {
                event("ui.press", title, additional: ["mechanism": "AXUIElementPerformAction AXPress on actual native UI", "localizationKey": key])
                try await pause(0.5)
                return
            }
            try await pause(0.2)
        }
        try dumpAccessibility()
        try saveJSON(remoteDiagnostic, to: root.appendingPathComponent("RemoteAccessibility.json"))
        tutorialLog("Remote AX failure: \(remoteDiagnostic)")
        throw tutorialError("Could not find enabled actual UI control: \(title)")
    }

    private nonisolated static func remotePress(title: String) -> [String: Any] {
        let helper = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ReviveTutorialAX")
        let process = Process()
        process.executableURL = helper
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), title]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            // Reading before waiting drains large failure diagnostics without a
            // pipe deadlock. This helper runs on a detached worker; UI stays live.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ["pressed": false, "error": "AX helper returned non-object JSON"]
            }
            return result
        } catch {
            return ["pressed": false, "error": "Separate AX helper failed: \(error.localizedDescription)"]
        }
    }
    private func scratchSnapshot() -> [[String: Any]] {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let children = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for child in children where child.lastPathComponent.hasPrefix("Revive-") && !initialScratchNames.contains(child.lastPathComponent) {
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                scratchRoots[child.lastPathComponent] = child
            }
        }
        var files: [[String: Any]] = []
        for (name, directory) in scratchRoots {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else { continue }
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), values.isRegularFile == true else { continue }
                files.append(["path": name + "/" + String(file.path.dropFirst(directory.path.count + 1)), "bytes": values.fileSize ?? -1, "modified": values.contentModificationDate?.timeIntervalSince1970 ?? 0])
            }
        }
        return files.sorted { ($0["path"] as! String) < ($1["path"] as! String) }
    }

    private func waitUntil(_ description: String, seconds: Double = 100, observeItem: QueueItem? = nil, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        var nextSample = Date()
        while !condition() && Date() < deadline {
            if let item = observeItem, Date() >= nextSample {
                let sample: [String: Any] = ["seconds": Date().timeIntervalSince(started), "waitingFor": description, "mainActorHeartbeat": true, "state": String(describing: item.state), "previewReady": item.previewReady, "scratchFiles": scratchSnapshot()]
                waitSamples.append(sample)
                if let data = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
                    tutorialLog("WAIT_DIAGNOSTIC " + text)
                }
                nextSample = Date().addingTimeInterval(1)
            }
            try await pause(0.1)
        }
        guard condition() else { throw tutorialError("Timed out waiting for \(description)") }
    }

    func run() async {
        tutorialLog("Tutorial run entered on main actor; windows=\(NSApp.windows.count)")
        guard !didRun else { return }; didRun = true
        do {
            let args = CommandLine.arguments
            guard args.count == 4 else { throw tutorialError("Usage: RealTutorial <photo.jpg> <video.mp4> <new-output-folder>") }
            root = URL(fileURLWithPath: args[3], isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let scratchParent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            initialScratchNames = Set(((try? FileManager.default.contentsOfDirectory(atPath: scratchParent.path)) ?? []).filter { $0.hasPrefix("Revive-") })
            Localizer.shared.lang = .zhHans
            NSApp.setActivationPolicy(.regular)
            try await pause(2)
            guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible }) else { throw tutorialError("Native app window unavailable") }
            self.window = window
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
            window.setContentSize(NSSize(width: max(900, min(1100, visible.width - 32)), height: max(620, min(900, visible.height - 52))))
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            tutorialLog("Native window ready: visible=\(window.isVisible) frame=\(window.frame)")
            if let host = window.contentView, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.layoutSubtreeIfNeeded()
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: root.appendingPathComponent("LaunchWindow-DIAGNOSTIC.png"))
                }
            }
            let font = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Support/fonts/GreatVibes-Regular.ttf")
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
            try await pause(2)
            try await recorder.start(to: recordingRequired ? root.appendingPathComponent("操作教程-原生连续录屏.mp4") : nil)
            started = Date()
            event(recordingRequired ? "recording.start" : "screenshots.ready", recordingRequired
                ? "ScreenCaptureKit 实际桌面连续采集；与发布版本同源的 CI 自动操作，不是人工录制或界面模拟"
                : "ScreenCaptureKit 实际截图模式；没有持续录制编码，仍通过实际界面完成全部转换和文件检查")
            try await pause(2)
            var results: [[String: Any]] = []
            for (kind, source) in [("photo", URL(fileURLWithPath: args[1])), ("video", URL(fileURLWithPath: args[2]))] {
                results.append(try await performCase(kind: kind, source: source))
            }
            event("recording.finish", "两组案例导入、预览、实际封面确认、导出完成；原素材哈希未变")
            try await pause(2)
            let recordedDuration: Double
            if recordingRequired { recordedDuration = try await recorder.stop() }
            else { recordedDuration = 0 }
            let report: [String: Any] = ["status": "REAL_MEDIA_NATIVE_UI_EXPORT_AND_SCREEN_RECORDING_VERIFIED", "sourceCommit": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "LOCAL_UNRECORDED", "applicationSourceCommit": ProcessInfo.processInfo.environment["REVIVE_APP_SOURCE_COMMIT"] ?? "UNKNOWN", "buildConfiguration": "debug CI-only entry; unchanged production views models engine verifier", "recordingMethod": "ScreenCaptureKit continuous desktop capture H264 MP4", "uiActionsMethod": "actual native controls through NSAccessibility.accessibilityPerformPress", "importMethod": "AppModel.add, same original-file entry used by drag/drop and Open With; no manual file picker claimed", "humanOperated": false, "recordedDuration": recordedDuration, "applePhotosLivePlaybackVerified": false, "cases": results, "events": events]
            var finalReport = report
            finalReport["status"] = recordingRequired ? "REAL_MEDIA_NATIVE_UI_EXPORT_AND_SCREEN_RECORDING_VERIFIED" : "REAL_MEDIA_NATIVE_UI_EXPORT_VERIFIED_NO_CONTINUOUS_RECORDING"
            finalReport["recordingRequired"] = recordingRequired
            finalReport["continuousRecordingVerified"] = recordingRequired
            finalReport["recordingMethod"] = recordingRequired ? "ScreenCaptureKit continuous desktop capture H264 MP4" : "ScreenCaptureKit screenshots only; no SCStream/SCRecordingOutput encoding"
            finalReport["recordingFile"] = recordingRequired ? "操作教程-原生连续录屏.mp4" : ""
            finalReport["captionsFile"] = recordingRequired ? "操作教程.zh-CN.vtt" : ""
            try saveJSON(finalReport, to: root.appendingPathComponent("RealTutorialReceipt.json"))
            try saveJSON(waitSamples, to: root.appendingPathComponent("WaitDiagnostics.json"))
            if recordingRequired { try writeVTT(duration: recordedDuration) }
            print("REAL TUTORIAL PASSED")
            fflush(stdout)
            NSApp.terminate(nil)
        } catch {
            print("REAL TUTORIAL FAILED: \(error.localizedDescription)")
            if let root {
                let failureState = currentItem.map { String(describing: $0.state) } ?? "no current queue item"
                let files = scratchSnapshot()
                try? await recorder.screenshot(to: root.appendingPathComponent("FailureScreen.png"))
                var failureRecordingSeconds = 0.0
                if recordingRequired, recorder.stream != nil { failureRecordingSeconds = (try? await recorder.stop()) ?? 0 }
                try? saveJSON(["status": "FAILED", "error": error.localizedDescription, "screenCapturePermissionPreflight": CGPreflightScreenCaptureAccess(), "recordingRequired": recordingRequired, "failureRecordingSeconds": failureRecordingSeconds, "itemState": failureState, "scratchFiles": files, "events": events], to: root.appendingPathComponent("RealTutorialFailure.json"))
                try? saveJSON(waitSamples, to: root.appendingPathComponent("WaitDiagnostics.json"))
                let failureScratch = root.appendingPathComponent("FailureScratch", isDirectory: true)
                try? FileManager.default.createDirectory(at: failureScratch, withIntermediateDirectories: false)
                for (name, path) in scratchRoots { try? FileManager.default.copyItem(at: path, to: failureScratch.appendingPathComponent(name, isDirectory: true)) }
                let sampleURL = root.appendingPathComponent("FailureProcessSample.txt")
                await Task.detached {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "-file", sampleURL.path]
                    process.standardOutput = FileHandle.standardError
                    process.standardError = FileHandle.standardError
                    do { try process.run(); process.waitUntilExit() } catch { tutorialLog("Failure sample unavailable: \(error.localizedDescription)") }
                }.value
                try? dumpAccessibility()
            }
            fflush(stdout)
            exit(1)
        }
    }

    private func performCase(kind: String, source: URL) async throws -> [String: Any] {
        let caseRoot = root.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: false)
        let before = try SafeExport.sha256(source)
        model.outputParent = caseRoot
        event("\(kind).import", "自动导入真实原素材（与拖入 / Open With 相同入口）", additional: ["sourceName": source.lastPathComponent, "sourceSHA256": before])
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        model.add(urls: [source])
        guard let item = model.items.last else { throw tutorialError("Import produced no queue item") }
        currentItem = item
        model.selectionID = item.id
        try await waitUntil("source loading", seconds: 30) { item.state != .loading }
        guard item.state == .ready else { throw tutorialError("Source load failed: \(item.state)") }
        try await pause(3)
        try await recorder.screenshot(to: caseRoot.appendingPathComponent("01-导入.png"))
        scrollEditor(bottom: false)
        if kind == "video" {
            // This is the same binding state changed by the timeline's custom
            // DragGesture. It has no AX slider action, so never claim a mouse
            // drag was performed. The audited stable shot avoids a hard cut in
            // this source's default middle selection.
            item.trimStart = 15
            item.trimEnd = 18
            item.frameTime = 1.5
            event("video.trim", "自动设置已审核的连续镜头 15.0–18.0 秒，封面为原片 16.5 秒；手动操作时拖动时间轴两侧蓝边", additional: ["mechanism": "actual timeline model bindings; no mouse drag claimed"])
            try await press("play_clip")
            try await pause(3.5)
        }
        scrollEditor(bottom: true)
        try await pause(1)
        try await press("prepare_preview")
        try await waitUntil("verified output preview", observeItem: item) { item.previewReady || { if case .failed = item.state { return true }; return false }() }
        guard item.previewReady, item.coverImage != nil, !item.checks.isEmpty,
              item.checks.allSatisfy({ $0.status == .pass }) else { throw tutorialError("Actual JPG/MOV preview failed") }
        event("\(kind).preview.ready", "原生引擎已生成并严格复验实际 JPG/MOV；封面尚未确认")
        try await pause(2)
        try await recorder.screenshot(to: caseRoot.appendingPathComponent("02-成片预览.png"))
        scrollEditor(bottom: false)
        try await press("play_clip")
        try await pause(3.5)
        scrollEditor(bottom: true)
        try await press("preview_full")
        event("\(kind).cover.inspect", "查看实际编码 JPG 封面；演示由自动化勾选确认，狐狸封面另作人工目视核验，不声称自动闭眼检测")
        try await pause(3)
        try await recorder.screenshot(to: caseRoot.appendingPathComponent("03-实际JPG封面.png"))
        try await press("cover_confirm")
        guard item.coverConfirmed else { throw tutorialError("Actual cover checkbox did not change model confirmation") }
        try await press("preview_close")
        try await pause(1)
        try await press("convert_export")
        try await waitUntil("folder export") { item.state == .done || { if case .failed = item.state { return true }; return false }() }
        guard item.state == .done, let liveFolder = item.exportDirectory,
              liveFolder.lastPathComponent.hasPrefix("Revive_Live_") else { throw tutorialError("Actual folder export did not finish") }
        event("\(kind).live.exported", "实际导出并在 Finder 显示新文件夹中的 JPG/MOV", additional: ["folder": liveFolder.lastPathComponent])
        try await pause(3)
        try await recorder.screenshot(to: caseRoot.appendingPathComponent("04-导出文件夹.png"))
        let image = liveFolder.appendingPathComponent("IMG_LIVE.JPG")
        let movie = liveFolder.appendingPathComponent("IMG_LIVE.MOV")
        let checks = await Verifier.verify(imageURL: image, movURL: movie, expectedDuration: 3, expectedStillTime: item.result?.stillTime, expectedAudio: item.expectedAudio)
        guard !checks.isEmpty, checks.allSatisfy({ $0.status == .pass }) else { throw tutorialError("Exported JPG/MOV strict verifier failed") }
        var gifPath = ""
        if kind == "photo" {
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            scrollEditor(bottom: true)
            try await pause(1)
            try await press("export_gif")
            try await waitUntil("real image GIF export") { item.gifExportURL != nil || { if case .failed = item.state { return true }; return false }() }
            guard let gif = item.gifExportURL else { throw tutorialError("Real image GIF not exported") }
            gifPath = "photo/" + gif.deletingLastPathComponent().lastPathComponent + "/" + gif.lastPathComponent
            event("photo.gif.exported", "GIF 编码与解码检查通过，实际导出并在 Finder 显示独立新文件夹", additional: ["file": gifPath])
            try await pause(3)
            try await recorder.screenshot(to: caseRoot.appendingPathComponent("05-GIF导出.png"))
        }
        let after = try SafeExport.sha256(source)
        guard before == after else { throw tutorialError("Original source changed") }
        var result: [String: Any] = ["kind": kind, "sourceName": source.lastPathComponent, "sourceSHA256Before": before, "sourceSHA256After": after, "sourceUnchanged": true, "actualUIDelivery": true, "coverConfirmation": "automated UI checkbox; fox eye state requires separate visual review; no automated eye detection", "trimStart": item.trimStart, "trimEnd": item.trimEnd, "stillTime": item.result?.stillTime ?? -1, "liveFolder": kind + "/" + liveFolder.lastPathComponent, "imageSHA256": try SafeExport.sha256(image), "movieSHA256": try SafeExport.sha256(movie), "gifFile": gifPath, "checks": checks.map { ["code": $0.code, "status": $0.status.rawValue, "detail": $0.detail] }, "allStrictChecksPassed": true, "applePhotosLivePlaybackVerified": false]
        if kind == "photo" {
            guard let motionSource = item.motionSourceURL else { throw tutorialError("Native still-motion intermediate missing") }
            let motionCopy = caseRoot.appendingPathComponent("PHOTO_MOTION.MP4")
            let motionHash = try SafeExport.sha256(motionSource)
            try FileManager.default.copyItem(at: motionSource, to: motionCopy)
            guard try SafeExport.sha256(motionCopy) == motionHash else { throw tutorialError("Native motion intermediate copy hash mismatch") }
            result["nativeMotionFile"] = "photo/PHOTO_MOTION.MP4"
            result["nativeMotionSHA256"] = motionHash
            result["nativeMotionCopiedByteForByte"] = true
        }
        try saveJSON(result, to: caseRoot.appendingPathComponent("CaseReceipt.json"))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await pause(1)
        model.remove(item)
        currentItem = nil
        try await pause(1)
        return result
    }

    private func writeVTT(duration: Double) throws {
        func clock(_ seconds: Double) -> String {
            let ms = Int(max(0, seconds) * 1000)
            return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        var vtt = "WEBVTT\n\n"
        for (index, item) in events.enumerated() {
            let start = item["seconds"] as! Double
            let end = index + 1 < events.count ? min(duration, events[index + 1]["seconds"] as! Double) : duration
            if end > start { vtt += "\(index + 1)\n\(clock(start)) --> \(clock(end))\n\(item["detail"] as! String)\n\n" }
        }
        try vtt.write(to: root.appendingPathComponent("操作教程.zh-CN.vtt"), atomically: true, encoding: .utf8)
    }
}

@available(macOS 15.0, *)
@main
enum RealTutorialMain {
    @MainActor static func main() {
        setbuf(stdout, nil)
        tutorialLog("Native tutorial main entered; pid=\(ProcessInfo.processInfo.processIdentifier)")
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        Localizer.shared.lang = .zhHans
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let size = NSSize(width: max(900, min(1100, visible.width - 32)), height: max(620, min(900, visible.height - 52)))
        let host = NSHostingView(rootView: ContentView()
            .environmentObject(AppModel.shared)
            .environmentObject(Localizer.shared))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Revive"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        tutorialLog("Explicit NSApplication/NSHostingView window created: visible=\(window.isVisible), frame=\(window.frame)")
        Task { @MainActor in
            await RealTutorial.shared.run()
        }
        tutorialLog("Entering NSApplication.run event loop")
        // This lexical lifetime retains the actual window for the whole event
        // loop, matching the previously verified --ui-smoke initialization.
        withExtendedLifetime(window) { app.run() }
        tutorialLog("NSApplication event loop returned")
    }
}
