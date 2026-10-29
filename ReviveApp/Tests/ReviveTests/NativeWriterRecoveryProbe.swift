import AVFoundation
import Foundation
@testable import Revive

/// Records real AVFoundation input state. The only injected fault is withholding
/// subsequent native callback forwarding after one successful AAC append.
/// Reader, writer, ready checks, sample reads/appends and the recovery timer stay
/// the production implementations. This is not a spontaneous OS-stall claim.
final class NativeWriterRecoveryProbe: @unchecked Sendable {
    enum Mode: String { case positive, negative }

    let operationID = UUID().uuidString
    let mode: Mode
    let configuration: String
    let architecture: String
    let receiptURL: URL
    let eventURL: URL
    private let lock = NSLock()
    private let handle: FileHandle
    private let expectedAudioSamples: Int
    private let notifyNegativeHold: @Sendable () -> Void
    private var events: [[String: Any]] = []
    private var injected = false
    private var armed = false
    private var metadataFinished = false
    private var firstCheckpoint: (time: Double, reads: Int, appends: Int)?
    private var confirmedAt: Double?
    private var negativeHoldNotified = false
    private var suppressedCallbacks = 0
    private var recordingFailure: String?
    private var ended = false

    init(mode: Mode, expectedAudioSamples: Int,
         notifyNegativeHold: @escaping @Sendable () -> Void = {}) throws {
        self.mode = mode
        self.expectedAudioSamples = expectedAudioSamples
        self.notifyNegativeHold = notifyNegativeHold
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
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ci-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "WriterRecovery-\(configuration)-\(mode.rawValue)-\(operationID)"
        receiptURL = directory.appendingPathComponent(name + ".json")
        eventURL = directory.appendingPathComponent(name + ".jsonl")
        guard FileManager.default.createFile(atPath: eventURL.path, contents: nil) else {
            throw Self.error("Cannot create native recovery event journal")
        }
        handle = try FileHandle(forWritingTo: eventURL)
    }

    deinit { try? handle.close() }

    var probe: LivePhotoEngine.WriterProbe {
        LivePhotoEngine.WriterProbe(
            allowsNativeCallback: { [self] mediaType in
                lock.lock(); defer { lock.unlock() }
                if mediaType == AVMediaType.audio.rawValue && injected {
                    suppressedCallbacks += 1
                    return false
                }
                return true
            },
            yieldAfterAppend: { [self] mediaType, origin, _ in
                lock.lock(); defer { lock.unlock() }
                guard mediaType == AVMediaType.audio.rawValue, origin == "native", !injected else { return false }
                injected = true
                recordLocked("test.native.delivery.withheld", fields: ["mediaType": mediaType,
                    "origin": origin, "faultKind": "CONTROLLED_NATIVE_CALLBACK_DELIVERY_LOSS"])
                return true
            },
            allowsFallback: { [self] mediaType in
                lock.lock(); defer { lock.unlock() }
                return mediaType != AVMediaType.audio.rawValue || armed
            },
            observe: { [self] name, fields in observe(name, fields: fields) })
    }

    private func observe(_ name: String, fields: [String: Any]) {
        lock.lock()
        recordLocked(name, fields: fields)
        if name == "input.finished", fields["mediaType"] as? String == AVMediaType.metadata.rawValue,
           fields["markAsFinishedReturned"] as? Bool == true { metadataFinished = true }
        var notify = false
        if name == "pump.poll", fields["mediaType"] as? String == AVMediaType.audio.rawValue,
           injected, !armed, metadataFinished,
           fields["readerStatus"] as? Int == 1, fields["writerStatus"] as? Int == 1,
           fields["stage"] as? String == "pumping", fields["ready"] as? Bool == true,
           fields["eof"] as? Bool == false, fields["finished"] as? Bool == false,
           let reads = fields["readSamples"] as? Int, reads > 0, reads < expectedAudioSamples,
           let appends = fields["appendBuffers"] as? Int, appends == 1 {
            let now = ProcessInfo.processInfo.systemUptime
            if let first = firstCheckpoint, first.reads == reads, first.appends == appends {
                var checkpoint = fields
                checkpoint["stableSeconds"] = now - first.time
                recordLocked("test.stall.checkpoint", fields: checkpoint)
                if now - first.time >= 1,
                   (fields["progressAgeSeconds"] as? Double ?? 0) >= 1, confirmedAt == nil {
                    confirmedAt = now
                    recordLocked("test.stall.confirmed", fields: checkpoint)
                    if mode == .positive {
                        armed = true
                        recordLocked("test.recovery.armed", fields: checkpoint)
                    }
                }
                if mode == .negative, let confirmedAt, now - confirmedAt >= 1,
                   !negativeHoldNotified {
                    negativeHoldNotified = true
                    recordLocked("test.negative.control.held", fields: checkpoint)
                    notify = true
                }
            } else {
                firstCheckpoint = (now, reads, appends)
                var checkpoint = fields
                checkpoint["stableSeconds"] = 0.0
                recordLocked("test.stall.checkpoint", fields: checkpoint)
            }
        }
        lock.unlock()
        if notify { notifyNegativeHold() }
    }

    func note(_ name: String, fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        recordLocked(name, fields: fields)
    }

    private func recordLocked(_ name: String, fields: [String: Any]) {
        guard !ended else { return }
        var entry = fields
        entry["event"] = name
        entry["operationID"] = operationID
        entry["sequence"] = events.count + 1
        entry["monotonicSeconds"] = ProcessInfo.processInfo.systemUptime
        events.append(entry)
        do {
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch { recordingFailure = error.localizedDescription }
    }

    func validationFailures(negativeCancelled: Bool = false, requireFilesVerified: Bool = false) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var failures: [String] = []
        if let recordingFailure { failures.append("Event recording failed: " + recordingFailure) }
        func rows(_ name: String) -> [[String: Any]] { events.filter { $0["event"] as? String == name } }
        func require(_ condition: Bool, _ detail: String) { if !condition { failures.append(detail) } }
        let starts = rows("writer.started")
        require(starts.count == 1, "Expected exactly one real reader/writer start")
        if let start = starts.first {
            require(!(start["readerIdentity"] as? String ?? "").isEmpty, "Missing real reader identity")
            require(!(start["writerIdentity"] as? String ?? "").isEmpty, "Missing real writer identity")
            let reader = start["readerIdentity"] as? String
            let writer = start["writerIdentity"] as? String
            let nativeEvents = events.filter { !($0["event"] as? String ?? "").hasPrefix("test.") }
            require(nativeEvents.allSatisfy {
                $0["readerIdentity"] as? String == reader && $0["writerIdentity"] as? String == writer
            }, "Recovery events changed the real reader or writer instance")
        }
        require(rows("test.native.delivery.withheld").count == 1, "Native forwarding fault was not injected exactly once")
        let stalls = rows("test.stall.confirmed")
        require(stalls.count == 1, "No unique live native stall was confirmed")
        require(rows("test.stall.checkpoint").count >= 2, "Need multiple live unchanged checkpoints")
        let stall = stalls.first
        let beforeReads = stall?["readSamples"] as? Int ?? 0
        let beforeAppends = stall?["appendBuffers"] as? Int ?? 0
        require(beforeReads > 0 && beforeReads < expectedAudioSamples && beforeAppends == 1,
                "Stall must retain unread audio samples after a real append")
        require((stall?["stableSeconds"] as? Double ?? 0) >= 1, "Native no-progress interval must reach one second")
        require((stall?["progressAgeSeconds"] as? Double ?? 0) >= 1,
                "All native inputs must have made no successful media append for one second")
        require(stall?["ready"] as? Bool == true && stall?["readerStatus"] as? Int == 1
                && stall?["writerStatus"] as? Int == 1 && stall?["stage"] as? String == "pumping"
                && stall?["eof"] as? Bool == false && stall?["finished"] as? Bool == false,
                "Stall must be measured live while the original reader/writer remain active and audio is ready")
        let faultSequence = rows("test.native.delivery.withheld").first?["sequence"] as? Int ?? Int.max
        let laterNativeAudio = rows("append.success").filter {
            $0["mediaType"] as? String == AVMediaType.audio.rawValue && $0["origin"] as? String == "native"
            && ($0["sequence"] as? Int ?? 0) > faultSequence
        }
        require(laterNativeAudio.isEmpty, "Native forwarding resumed after the injected loss")
        let stallSequence = stall?["sequence"] as? Int ?? 0
        require(faultSequence < stallSequence, "Stall was recorded before callback forwarding loss")
        let metadataFinishedSequence = rows("input.finished").first {
            $0["mediaType"] as? String == AVMediaType.metadata.rawValue
        }?["sequence"] as? Int ?? Int.max
        require(metadataFinishedSequence < stallSequence, "Metadata must finish before the live stalled checkpoints")
        if mode == .positive {
            let armedRows = rows("test.recovery.armed")
            require(armedRows.count == 1, "Recovery was not armed exactly once after the live stall")
            let armedSequence = armedRows.first?["sequence"] as? Int ?? Int.max
            require(stallSequence < armedSequence, "Recovery was armed before the live stall proof")
            let entries = rows("fallback.enter").filter {
                $0["mediaType"] as? String == AVMediaType.audio.rawValue
                && ($0["sequence"] as? Int ?? 0) > armedSequence
            }
            require(!entries.isEmpty, "Existing production fallback did not enter after arming")
            let fallbackSequence = entries.first?["sequence"] as? Int ?? Int.max
            let appends = rows("append.success").filter {
                $0["mediaType"] as? String == AVMediaType.audio.rawValue && $0["origin"] as? String == "fallback"
                && ($0["sequence"] as? Int ?? 0) > fallbackSequence
                && ($0["bufferSamples"] as? Int ?? 0) > 0
                && ($0["readSamples"] as? Int ?? 0) > beforeReads
                && ($0["appendBuffers"] as? Int ?? 0) > beforeAppends
            }
            require(!appends.isEmpty, "Fallback must successfully append new nonempty audio samples, not merely EOF")
            let recoveredAppendSequence = appends.first?["sequence"] as? Int ?? Int.max
            let audioEOFSequence = rows("input.eof").first {
                $0["mediaType"] as? String == AVMediaType.audio.rawValue
            }?["sequence"] as? Int ?? 0
            require(recoveredAppendSequence < audioEOFSequence, "Recovered audio append must precede its actual EOF")
            for media in [AVMediaType.audio.rawValue, AVMediaType.video.rawValue] {
                require(rows("input.eof").filter { $0["mediaType"] as? String == media }.count == 1,
                        "Expected one EOF for " + media)
            }
            for media in [AVMediaType.audio.rawValue, AVMediaType.video.rawValue, AVMediaType.metadata.rawValue] {
                let finished = rows("input.finished").filter { $0["mediaType"] as? String == media }
                require(finished.count == 1 && finished.first?["markAsFinishedReturned"] as? Bool == true,
                        "Expected one returned native finish marker for " + media)
            }
            require(rows("writer.finish.enter").count == 1, "Expected one finishWriting entry")
            let finishSequence = rows("writer.finish.enter").first?["sequence"] as? Int ?? 0
            require(rows("input.eof").allSatisfy { ($0["sequence"] as? Int ?? Int.max) < finishSequence }
                    && rows("input.finished").allSatisfy { ($0["sequence"] as? Int ?? Int.max) < finishSequence },
                    "Native finishWriting started before all inputs ended")
            let callbacks = rows("writer.finish.callback")
            require(callbacks.count == 1 && callbacks.first?["writerStatus"] as? Int == 2,
                    "Expected one completed native finishWriting callback")
            require(rows("completion.success").count == 1 && rows("completion.failure").isEmpty,
                    "Native write did not complete successfully exactly once")
            let callbackSequence = callbacks.first?["sequence"] as? Int ?? 0
            let completedSequence = rows("completion.success").first?["sequence"] as? Int ?? 0
            require(finishSequence < callbackSequence && callbackSequence < completedSequence,
                    "Native finish entry, callback and completion ordering changed")
            if requireFilesVerified {
                let verified = rows("test.files.verified")
                require(verified.count == 1 && completedSequence < (verified.first?["sequence"] as? Int ?? 0),
                        "Strict JPG/MOV verification must follow successful native completion")
            }
        } else {
            require(!armed && rows("test.recovery.armed").isEmpty, "Negative control unexpectedly armed recovery")
            require(rows("test.negative.control.held").count == 1, "Negative control did not remain stalled for the extra hold window")
            require(rows("fallback.enter").filter { $0["mediaType"] as? String == AVMediaType.audio.rawValue }.isEmpty,
                    "Negative control allowed an audio fallback drive")
            require(rows("completion.success").isEmpty && rows("writer.finish.callback").isEmpty,
                    "Negative control completed without audio recovery")
            require(negativeCancelled && rows("completion.failure").count == 1,
                    "Negative control did not cancel through the real failure/drain path")
        }
        return failures
    }

    func finish(status: String, details: [String: Any]) throws {
        lock.lock(); defer { lock.unlock() }
        var receipt = details
        receipt["status"] = status
        receipt["operationID"] = operationID
        receipt["configuration"] = configuration
        receipt["architecture"] = architecture
        receipt["mode"] = mode.rawValue
        receipt["faultKind"] = "CONTROLLED_NATIVE_CALLBACK_DELIVERY_LOSS"
        receipt["sourceCommit"] = ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "LOCAL_NATIVE_TEST"
        receipt["suppressedNativeCallbacks"] = suppressedCallbacks
        receipt["events"] = events
        receipt["eventJournal"] = eventURL.lastPathComponent
        receipt["expectedAudioSamples"] = expectedAudioSamples
        receipt["liveStallMinimumSeconds"] = 1.0
        receipt["nativeCallbackForwardingRemainedDisabled"] = injected
        receipt["recoveryArmed"] = armed
        receipt["recordingFailure"] = recordingFailure.map { $0 as Any } ?? NSNull()
        try handle.synchronize()
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: receiptURL, options: .atomic)
        ended = true
        print("Native writer recovery receipt: \(receiptURL.path) status=\(status)")
    }

    private static func error(_ detail: String) -> NSError {
        NSError(domain: "ReviveNativeWriterRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
}
