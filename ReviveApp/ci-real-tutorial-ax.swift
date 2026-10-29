// CI-only external accessibility client. Running AXUIElement against this
// process itself can invoke SwiftUI internals on the wrong thread; keeping the
// client in a separate process preserves the system's target-main-thread IPC.
import Foundation
import ApplicationServices

@main
enum TutorialAXMain {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3, let pid = Int32(args[1]), pid != ProcessInfo.processInfo.processIdentifier else {
            emit(["pressed": false, "error": "Usage: ReviveTutorialAX <different-target-pid> <control-title>"])
            exit(64)
        }
        let title = args[2]
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        let enhanced = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
            return result
        }
        var queue: [(AXUIElement, Int)] = [(app, 0)]
        var seen = Set<CFHashCode>()
        var index = 0
        var rows: [[String: Any]] = []
        while index < queue.count && index < 5000 {
            let (element, depth) = queue[index]
            index += 1
            if !seen.insert(CFHash(element)).inserted { continue }
            let role = value(element, kAXRoleAttribute) as? String ?? ""
            let parts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
                .compactMap { value(element, $0) as? String }
            let text = parts.joined(separator: " ")
            let enabled = (value(element, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? false
            rows.append(["role": role, "text": text, "enabled": enabled, "depth": depth])
            if (role == kAXButtonRole || role == kAXCheckBoxRole), enabled, text.contains(title) {
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                emit(["pressed": result == .success, "pressResult": result.rawValue,
                      "enhancedResult": enhanced.rawValue, "manualResult": manual.rawValue,
                      "matchedRole": role, "matchedText": text, "helperPID": ProcessInfo.processInfo.processIdentifier,
                      "targetPID": pid, "clientTrusted": AXIsProcessTrusted()])
                return
            }
            if depth < 32 {
                for key in [kAXWindowsAttribute, kAXChildrenAttribute, kAXContentsAttribute] {
                    if let children = value(element, key) as? [AXUIElement] {
                        queue.append(contentsOf: children.map { ($0, depth + 1) })
                    }
                }
            }
        }
        emit(["pressed": false, "enhancedResult": enhanced.rawValue,
              "manualResult": manual.rawValue, "searchedNodes": index, "nodes": rows,
              "helperPID": ProcessInfo.processInfo.processIdentifier, "targetPID": pid,
              "clientTrusted": AXIsProcessTrusted()])
    }

    private static func emit(_ value: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            FileHandle.standardOutput.write(Data("{\"pressed\":false,\"error\":\"JSON encoding failed\"}\n".utf8))
        }
    }
}
