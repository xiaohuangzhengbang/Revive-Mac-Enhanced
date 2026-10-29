import AVFoundation
import Foundation
@testable import Revive

/// Passive natural-stall capture: native callbacks, reads, appends, input
/// readiness and queue scheduling are never suppressed, delayed or fabricated.
/// Only the pre-existing fallback is held until live stalled state is recorded.
final class NativeNaturalRecoveryProbe: @unchecked Sendable {
    static let evidenceKind = "NATURAL_NATIVE_CALLBACK_STALL"
    let operationID = UUID().uuidString
    let configuration: String
    let architecture: String
    let receiptURL: URL
    let eventURL: URL
    private let lock = NSLock()
    private let expectedAudioSamples: Int
    private let handle: FileHandle
    private var events: [[String: Any]] = []
    private var callbackHookInvocations = 0
    private var yieldHookInvocations = 0
    private var metadataFinished = false
    private var checkpoint: (time: Double, samples: Int, appends: Int)?
    private var armed = false
    private var ended = false
    private var journalError: String?

    init(expectedAudioSamples: Int, directory: URL) throws {
        self.expectedAudioSamples = expectedAudioSamples
        #if DEBUG
        configuration = "debug"
        #else
        configuration = "release"
        #endif
        #if arch(arm64)
        architecture = "arm64"
        #elseif arch(x86_64)
        architecture = "x86_64"
        #else
        architecture = "unsupported"
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "NaturalWriterAttempt-\(architecture)-\(configuration)-\(operationID)"
        receiptURL = directory.appendingPathComponent(name + ".json")
        eventURL = directory.appendingPathComponent(name + ".jsonl")
        guard FileManager.default.createFile(atPath: eventURL.path, contents: nil) else {
            throw Self.error("Cannot create natural native writer journal")
        }
        handle = try FileHandle(forWritingTo: eventURL)
    }

    deinit { try? handle.close() }

    var probe: LivePhotoEngine.WriterProbe {
        LivePhotoEngine.WriterProbe(
            allowsNativeCallback: { [self] _ in
                lock.lock(); defer { lock.unlock() }
                callbackHookInvocations += 1
                recordLocked("test.forbidden.callback.hook.invoked", fields: [:])
                return true
            },
            yieldAfterAppend: { [self] _, _, _ in
                lock.lock(); defer { lock.unlock() }
                yieldHookInvocations += 1
                recordLocked("test.forbidden.yield.hook.invoked", fields: [:])
                return false
            },
            allowsFallback: { [self] _ in
                lock.lock(); defer { lock.unlock() }
                return armed
            },
            observe: { [self] name, fields in observe(name, fields: fields) },
            passiveNaturalCapture: true)
    }

    private func observe(_ name: String, fields: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        recordLocked(name, fields: fields)
        if name == "input.finished", fields["mediaType"] as? String == AVMediaType.metadata.rawValue,
           fields["markAsFinishedReturned"] as? Bool == true {
            metadataFinished = true
        }
        guard name == "pump.poll", fields["mediaType"] as? String == AVMediaType.audio.rawValue,
              !armed else { return }
        guard metadataFinished,
              fields["readerStatus"] as? Int == 1, fields["writerStatus"] as? Int == 1,
              fields["stage"] as? String == "pumping", fields["ready"] as? Bool == true,
              fields["eof"] as? Bool == false, fields["finished"] as? Bool == false,
              let samples = fields["readSamples"] as? Int,
              samples > 0, samples < expectedAudioSamples,
              let appends = fields["appendBuffers"] as? Int, appends > 0 else {
            checkpoint = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let first = checkpoint, first.samples == samples, first.appends == appends {
            var state = fields
            state["stableSeconds"] = now - first.time
            state["checkpointStartedAtUptime"] = first.time
            state["evidenceKind"] = Self.evidenceKind
            recordLocked("test.natural.stall.checkpoint", fields: state)
            if now - first.time >= 1,
               (fields["progressAgeSeconds"] as? Double ?? 0) >= 2 {
                recordLocked("test.natural.stall.confirmed", fields: state)
                armed = true
                recordLocked("test.natural.recovery.armed", fields: state)
            }
        } else {
            checkpoint = (now, samples, appends)
            var state = fields
            state["stableSeconds"] = 0.0
            state["checkpointStartedAtUptime"] = now
            state["evidenceKind"] = Self.evidenceKind
            recordLocked("test.natural.stall.checkpoint", fields: state)
        }
    }

    var didObserveNaturalStall: Bool {
        lock.lock(); defer { lock.unlock() }
        return armed
    }

    var hookInvocationCounts: (nativeCallback: Int, yield: Int) {
        lock.lock(); defer { lock.unlock() }
        return (callbackHookInvocations, yieldHookInvocations)
    }

    func note(_ name: String, fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        recordLocked(name, fields: fields)
    }

    func passiveIntegrityFailures() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return passiveIntegrityFailuresLocked()
    }

    private func passiveIntegrityFailuresLocked() -> [String] {
        var failures: [String] = []
        if callbackHookInvocations != 0 { failures.append("Native callback hook was invoked in passive mode") }
        if yieldHookInvocations != 0 { failures.append("Yield hook was invoked in passive mode") }
        if events.contains(where: { ($0["event"] as? String) == "driver.yielded" }) {
            failures.append("Native driver yielded under synthetic control")
        }
        if let journalError { failures.append("Journal error: \(journalError)") }
        let starts = events.filter { $0["event"] as? String == "writer.started" }
        if starts.count != 1 || starts.first?["passiveNaturalCapture"] as? Bool != true {
            failures.append("Passive capture was not bound to one writer invocation")
        }
        return failures
    }

    func recoveryValidationFailures(requireFilesVerified: Bool = false) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var failures = passiveIntegrityFailuresLocked()
        func index(_ name: String, audioOnly: Bool = false, after: Int = -1) -> Int? {
            events.indices.first { i in
                i > after && events[i]["event"] as? String == name &&
                (!audioOnly || events[i]["mediaType"] as? String == AVMediaType.audio.rawValue)
            }
        }
        guard let stall = index("test.natural.stall.confirmed") else {
            return failures + ["NATURAL_STALL_NOT_OBSERVED"]
        }
        let state = events[stall]
        guard (state["stableSeconds"] as? Double ?? 0) >= 1,
              (state["progressAgeSeconds"] as? Double ?? 0) >= 2,
              state["ready"] as? Bool == true,
              state["readerStatus"] as? Int == 1, state["writerStatus"] as? Int == 1,
              state["stage"] as? String == "pumping",
              let beforeSamples = state["readSamples"] as? Int,
              let beforeAppends = state["appendBuffers"] as? Int,
              beforeSamples > 0, beforeSamples < expectedAudioSamples else {
            return failures + ["Natural stalled checkpoint is not live and partial"]
        }
        guard let arm = index("test.natural.recovery.armed", after: stall),
              let fallback = index("fallback.enter", audioOnly: true, after: arm),
              let appended = index("append.success", audioOnly: true, after: fallback),
              let eof = index("input.eof", audioOnly: true, after: appended),
              let finished = index("input.finished", audioOnly: true, after: eof),
              let finishEnter = index("writer.finish.enter", after: finished),
              let finishCallback = index("writer.finish.callback", after: finishEnter),
              let success = index("completion.success", after: finishCallback) else {
            return failures + ["Missing natural stall→fallback→append→EOF→finish→completion chain"]
        }
        let resumed = events[appended]
        if resumed["origin"] as? String != "fallback" ||
           (resumed["bufferSamples"] as? Int ?? 0) <= 0 ||
           (resumed["readSamples"] as? Int ?? 0) <= beforeSamples ||
           (resumed["appendBuffers"] as? Int ?? 0) <= beforeAppends {
            failures.append("Fallback did not append additional real audio samples")
        }
        if events[eof]["readSamples"] as? Int != expectedAudioSamples ||
           events[eof]["eof"] as? Bool != true ||
           events[finished]["readSamples"] as? Int != expectedAudioSamples ||
           events[finished]["markAsFinishedReturned"] as? Bool != true ||
           events[finished]["finished"] as? Bool != true {
            failures.append("Recovered input did not reach real EOF and finished marker")
        }
        if events[finishCallback]["writerStatus"] as? Int != 2 ||
           events[success]["writerStatus"] as? Int != 2 {
            failures.append("The original native writer did not complete")
        }
        if index("completion.failure") != nil || index("test.deadline.expired") != nil {
            failures.append("Native recovery failed or exceeded the attempt deadline")
        }
        guard let writerID = events[stall]["writerIdentity"] as? String,
              let readerID = events[stall]["readerIdentity"] as? String else {
            return failures + ["Natural stall lacks reader/writer object identities"]
        }
        if events[stall...success].contains(where: { event in
            if let current = event["writerIdentity"] as? String, current != writerID { return true }
            if let current = event["readerIdentity"] as? String, current != readerID { return true }
            return false
        }) {
            failures.append("Recovery replaced the native reader or writer")
        }
        if requireFilesVerified && index("test.files.verified", after: success) == nil {
            failures.append("Recovered pair did not receive strict file validation")
        }
        return failures
    }

    private func recordLocked(_ name: String, fields: [String: Any]) {
        guard !ended else { return }
        var entry = fields
        entry["event"] = name
        entry["sequence"] = events.count + 1
        entry["operationID"] = operationID
        entry["configuration"] = configuration
        entry["architecture"] = architecture
        entry["capturedAtUptime"] = ProcessInfo.processInfo.systemUptime
        events.append(entry)
        do {
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            if journalError == nil { journalError = error.localizedDescription }
        }
    }

    func finish(status: String, details: [String: Any] = [:]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { throw Self.error("Natural attempt receipt already finished") }
        if let journalError { throw Self.error(journalError) }
        try handle.synchronize()
        var result = details
        result["status"] = status
        result["evidenceKind"] = Self.evidenceKind
        result["operationID"] = operationID
        result["architecture"] = architecture
        result["configuration"] = configuration
        result["sourceCommit"] = ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "LOCAL_NOT_CI_BOUND"
        result["nativeCallbackHookInvocations"] = callbackHookInvocations
        result["yieldHookInvocations"] = yieldHookInvocations
        result["naturalStallObserved"] = armed
        result["artificialFaultInjected"] = false
        result["perBufferInstrumentationBeforeFallback"] = false
        result["productionNoProgressTimeoutSeconds"] = 120
        result["eventFile"] = eventURL.lastPathComponent
        result["events"] = events
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: receiptURL, options: .atomic)
        ended = true
        try handle.close()
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "ReviveNaturalWriterRecovery", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
