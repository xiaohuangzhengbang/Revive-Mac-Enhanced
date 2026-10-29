import SwiftUI
import AppKit
import CoreText

struct ReviveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(AppModel.shared)
                .environmentObject(Localizer.shared)
        }
    }
}

/// Handles Finder integration: "Open With → Revive", drag-onto-icon, and the
/// right-click Services entry. All routes funnel the dropped video files into
/// the shared queue.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.activeOperations > 0 else {
            TempStore.sweep()
            return .terminateNow
        }
        model.requestTermination {
            TempStore.sweep()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.add(urls: urls) }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        Task { @MainActor in AppModel.shared.add(urls: [URL(fileURLWithPath: filename)]) }
        return true
    }

    /// Right-click → Services. Declared in Info.plist NSServices.
    @objc func convertToLivePhoto(_ pboard: NSPasteboard, userData: String,
                                  error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            AppModel.shared.add(urls: urls)
        }
    }
}

@main
enum Main {
    // In DEBUG builds, `--convert` / `--ui-smoke` provide terminal-only harnesses
    // for verifying the engine and UI without the GUI. Compiled out of release.
    //   Revive --convert in.mp4 outdir NAME [start] [end]   (env REVIVE_MUTE=1)
    //   Revive --ui-smoke [video] [out.png]                 (env REVIVE_LANG=en…)
    static func main() {
        #if DEBUG
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--convert"), args.count >= idx + 4 {
            let input = URL(fileURLWithPath: args[idx + 1])
            let outDir = URL(fileURLWithPath: args[idx + 2])
            let name = args[idx + 3]
            var settings = ConversionSettings()
            if args.count > idx + 4 { settings.trimStart = Double(args[idx + 4]) ?? 0 }
            if args.count > idx + 5 { settings.trimEnd = Double(args[idx + 5]) ?? 0 }
            if ProcessInfo.processInfo.environment["REVIVE_MUTE"] == "1" { settings.dropAudio = true }
            var finished = false
            Task {
                do {
                    let result = try await LivePhotoEngine.convert(
                        input: input, outputDir: outDir, baseName: name, settings: settings,
                        progress: { print("  \($0)") }
                    )
                    print("asset id : \(result.assetID)")
                    print("duration : \(String(format: "%.2f", result.clipDuration))s  copied=\(result.videoWasCopied)")
                    for check in await Verifier.verify(imageURL: result.imageURL, movURL: result.movURL) {
                        let mark = check.status == .pass ? "PASS" : check.status == .warn ? "WARN" : "FAIL"
                        print("  [\(mark)] \(check.label): \(check.detail)")
                    }
                } catch {
                    print("ERROR: \(error.localizedDescription)")
                    exit(1)
                }
                finished = true
            }
            while !finished {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            exit(0)
        }

        if let idx = args.firstIndex(of: "--ui-smoke") {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            // dev-only: register the OFL brand font from the source tree so the
            // wordmark renders offscreen (the real app uses ATSApplicationFontsPath)
            let fontURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Support/fonts/GreatVibes-Regular.ttf")
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
            if let langRaw = ProcessInfo.processInfo.environment["REVIVE_LANG"],
               let l = Lang(rawValue: langRaw) {
                Localizer.shared.lang = l
            }
            let model = AppModel()
            if args.count > idx + 1 {
                model.add(urls: [URL(fileURLWithPath: args[idx + 1])])
            }
            let host = NSHostingView(rootView: ContentView()
                .environmentObject(model)
                .environmentObject(Localizer.shared))
            host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            host.layoutSubtreeIfNeeded()
            if args.count > idx + 1 {
                guard let item = model.items.first else {
                    print("UI smoke FAILED: fixture was not added")
                    exit(1)
                }
                let loadDeadline = Date().addingTimeInterval(20)
                while item.state == .loading && Date() < loadDeadline {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                guard item.state == .ready else {
                    print("UI smoke FAILED: fixture did not load")
                    exit(1)
                }
                var prepared = false
                var preparationFinished = false
                Task { @MainActor in
                    prepared = await model.convert(item)
                    preparationFinished = true
                }
                let prepareDeadline = Date().addingTimeInterval(30)
                while !preparationFinished && Date() < prepareDeadline {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                    host.layoutSubtreeIfNeeded()
                }
                guard preparationFinished, prepared, item.previewReady,
                      item.coverImage != nil, !item.checks.isEmpty,
                      item.checks.allSatisfy({ $0.status == .pass }) else {
                    print("UI smoke FAILED: actual JPG/MOV preview was not verified")
                    exit(1)
                }
                print("UI smoke: actual JPG/MOV preview verified; human cover confirmation remains false")
            }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                host.layoutSubtreeIfNeeded()
            }
            if args.count > idx + 2 {
                let outPath = args[idx + 2]
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: outPath))
                        print("wrote screenshot: \(outPath)")
                    }
                }
            }
            for item in model.items { item.invalidatePreview() }
            TempStore.sweep()
            print("UI smoke OK — items: \(model.items.count)")
            exit(0)
        }
        #endif

        NSApplication.shared.setActivationPolicy(.regular)
        ReviveApp.main()
    }
}
