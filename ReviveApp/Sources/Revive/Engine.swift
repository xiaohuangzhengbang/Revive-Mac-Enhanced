import AVFoundation
import AudioToolbox
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation
import Darwin

enum EngineError: LocalizedError {
    case noVideoTrack
    case cannotRead(String)
    case cannotWrite(String)
    case stillExtractionFailed(String)
    case cancelled

    var errorDescription: String? {
        let L = Localizer.shared
        func join(_ key: String, _ detail: String) -> String {
            detail.isEmpty ? L.t(key) : "\(L.t(key)): \(detail)"
        }
        switch self {
        case .noVideoTrack: return L.t("err_no_video")
        case .cannotRead(let d): return join("err_read", d)
        case .cannotWrite(let d): return join("err_write", d)
        case .stillExtractionFailed(let d): return join("err_still", d)
        case .cancelled: return L.t("err_cancelled")
        }
    }
}

struct ConversionSettings {
    var trimStart: Double = 0
    var trimEnd: Double = 0          // 0 = until end (filled in from duration)
    var frameTime: Double? = nil     // relative to trimStart; nil = clip midpoint
    var useHEIC: Bool = false
    var exactTrim: Bool = false      // re-encode once for frame-accurate cuts
    var dropAudio: Bool = false      // mute: omit the audio track entirely
}

struct ConversionResult {
    let imageURL: URL
    let movURL: URL
    let assetID: String
    let baseName: String
    let clipDuration: Double
    let videoWasCopied: Bool
    /// Actual cover frame timestamp, relative to the exported MOV timeline.
    let stillTime: Double

    init(imageURL: URL, movURL: URL, assetID: String, baseName: String,
         clipDuration: Double, videoWasCopied: Bool, stillTime: Double = 0) {
        self.imageURL = imageURL
        self.movURL = movURL
        self.assetID = assetID
        self.baseName = baseName
        self.clipDuration = clipDuration
        self.videoWasCopied = videoWasCopied
        self.stillTime = stillTime
    }
}

/// Converts a video into a Live Photo pair. The video bitstream is copied
/// byte-for-byte (AVAssetReader/Writer passthrough) unless `exactTrim` is on
/// or the container needs conversion AVFoundation can't passthrough.
enum LivePhotoEngine {
    static let keyContentID = "com.apple.quicktime.content.identifier"
    static let keyStillImageTime = "com.apple.quicktime.still-image-time"
    static let keySpaceMDTA = "mdta"
    static let makerAppleAssetIDKey = "17"

    // MARK: metadata items

    private static func item(_ key: String, _ value: NSObject & NSCopying, _ dataType: String) -> AVMutableMetadataItem {
        let m = AVMutableMetadataItem()
        m.key = key as NSString
        m.keySpace = AVMetadataKeySpace(rawValue: keySpaceMDTA)
        m.value = value
        m.dataType = dataType
        return m
    }

    private static func topLevelMetadata(assetID: String) -> [AVMetadataItem] {
        [
            item(keyContentID, assetID as NSString, "com.apple.metadata.datatype.UTF-8"),
            // present in real captured Live Photos; helps downstream consumers
            item("com.apple.quicktime.live-photo.auto", NSNumber(value: 1), "com.apple.metadata.datatype.int8"),
            item("com.apple.quicktime.live-photo.vitality-score", NSNumber(value: Float(1.0)), "com.apple.metadata.datatype.float32"),
            item("com.apple.quicktime.live-photo.vitality-scoring-version", NSNumber(value: Int64(4)), "com.apple.metadata.datatype.int64"),
        ]
    }

    private static func stillImageTimeFormatDescription() throws -> CMFormatDescription {
        let spec: [CFString: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: "\(keySpaceMDTA)/\(keyStillImageTime)",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: "com.apple.metadata.datatype.int8",
        ]
        var desc: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &desc
        )
        guard status == noErr, let desc else {
            throw EngineError.cannotWrite("still-image-time format description failed (OSStatus \(status))")
        }
        return desc
    }

    // MARK: keyframe snapping

    /// Passthrough can only start at a sync (key) frame; find the one at/before `time`.
    private static func snapToPreviousSync(track: AVAssetTrack, time: CMTime) -> CMTime {
        guard track.canProvideSampleCursors,
              let cursor = track.makeSampleCursor(presentationTimeStamp: time) else { return time }
        var steps = 0
        while !cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue && steps < 100_000 {
            if cursor.stepInDecodeOrder(byCount: -1) == 0 { break }
            steps += 1
        }
        let snapped = cursor.presentationTimeStamp
        return snapped.isNumeric && snapped <= time ? snapped : time
    }

    // MARK: main entry

    /// Convert `input` into a Live Photo pair inside `outputDir` (created if needed).
    static func convert(
        input: URL,
        outputDir: URL,
        baseName: String,
        settings: ConversionSettings,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ConversionResult {
        try Task.checkCancellation()
        guard input.isFileURL, outputDir.isFileURL,
              !baseName.isEmpty, baseName != ".", baseName != "..",
              !baseName.contains("/"), !baseName.contains("\\"), !baseName.contains("\0") else {
            throw EngineError.cannotWrite("Invalid local output name or directory")
        }
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              settings.trimStart.isFinite, settings.trimEnd.isFinite,
              settings.trimStart >= 0, settings.trimStart < duration,
              settings.trimEnd >= 0, settings.trimEnd <= duration else {
            throw EngineError.cannotRead("Trim times must be finite and within the source duration")
        }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw EngineError.noVideoTrack
        }
        let trimStart = settings.trimStart
        let trimEnd = settings.trimEnd == 0 ? duration : settings.trimEnd
        let requestedDuration = trimEnd - trimStart
        guard requestedDuration > 0 else {
            throw EngineError.cannotRead("Trim end must be after trim start")
        }
        let frameRel = settings.frameTime ?? requestedDuration / 2
        guard frameRel.isFinite, frameRel >= 0, frameRel < requestedDuration else {
            throw EngineError.stillExtractionFailed("Cover time must be finite and before the clip end")
        }
        try Task.checkCancellation()
        let outputDirectory = try canonicalOutputDirectory(outputDir)
        try validateOutputDirectory(outputDirectory)
        let fm = FileManager.default
        let imageURL = outputDirectory.appendingPathComponent("\(baseName).\(settings.useHEIC ? "HEIC" : "JPG")")
        let movURL = outputDirectory.appendingPathComponent("\(baseName).MOV")
        try requireAbsent(imageURL)
        try requireAbsent(movURL)
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try validateOutputDirectory(outputDirectory)

        // Own a fresh private directory; never delete/reuse a guessed temp name.
        // Both completed files are committed with non-overwriting moveItem calls.
        let staging = outputDirectory.appendingPathComponent(".revive-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        let stagedIdentity = try fileIdentity(staging)
        defer { removeOwnedItem(staging, identity: stagedIdentity) }
        let preparedURL = staging.appendingPathComponent("prepared.MOV")
        let stagedImage = staging.appendingPathComponent(imageURL.lastPathComponent)
        let stagedMovie = staging.appendingPathComponent(movURL.lastPathComponent)
        let assetID = UUID().uuidString.uppercased()
        let videoWasCopied: Bool
        let preparedCoverTime: Double
        if settings.exactTrim {
            progress?("prog_exact")
            try await exactTrimExport(asset: asset, start: trimStart, end: trimEnd, to: preparedURL)
            preparedCoverTime = frameRel
            videoWasCopied = false
        } else {
            let videoCompatible = await isVideoPassthroughCompatible(videoTrack)
            progress?(videoCompatible ? "prog_mux" : "prog_reencode")
            var range: CMTimeRange? = nil
            if trimStart > 0.01 || trimEnd < duration - 0.01 {
                let start = videoCompatible
                    ? snapToPreviousSync(track: videoTrack,
                                         time: CMTime(seconds: trimStart, preferredTimescale: 600))
                    : CMTime(seconds: trimStart, preferredTimescale: 600)
                let end = CMTime(seconds: trimEnd, preferredTimescale: 600)
                range = CMTimeRange(start: start, end: end)
            }
            let preparedStart = range?.start.seconds ?? 0
            preparedCoverTime = trimStart + frameRel - preparedStart
            videoWasCopied = try await passthroughWrite(
                asset: asset, to: preparedURL, assetID: assetID,
                timeRange: range, stillTimeAbs: range?.start ?? .zero,
                dropAudio: settings.dropAudio)
        }
        try Task.checkCancellation()
        let prepared = AVURLAsset(url: preparedURL)
        let preparedDuration = try await prepared.load(.duration).seconds
        guard preparedDuration.isFinite, preparedDuration > 0,
              preparedCoverTime >= 0, preparedCoverTime < preparedDuration else {
            throw EngineError.stillExtractionFailed("Cover time is outside the rendered video")
        }
        progress?("prog_still")
        let actualTime = try await extractStill(asset: prepared, at: preparedCoverTime,
                                               to: stagedImage, heic: settings.useHEIC, assetID: assetID)
        guard actualTime.isNumeric, actualTime.seconds.isFinite,
              actualTime.seconds >= 0, actualTime.seconds < preparedDuration else {
            throw EngineError.stillExtractionFailed("Decoder returned an invalid cover frame time")
        }
        // Only remux these exact media samples. Re-encoding here would make the
        // full-resolution JPEG cease to be the final MOV's selected frame.
        try await passthroughWrite(asset: prepared, to: stagedMovie, assetID: assetID,
                                   timeRange: nil, stillTimeAbs: actualTime,
                                   dropAudio: settings.dropAudio, allowVideoReencode: false)
        let outDuration = try await AVURLAsset(url: stagedMovie).load(.duration).seconds
        guard outDuration.isFinite, outDuration > actualTime.seconds else {
            throw EngineError.cannotWrite("Final movie does not contain the cover frame")
        }
        try Task.checkCancellation()
        try validateOutputDirectory(outputDirectory)
        try requireAbsent(imageURL)
        try requireAbsent(movURL)
        let imageIdentity = try fileIdentity(stagedImage)
        let movieIdentity = try fileIdentity(stagedMovie)
        var committed = false
        defer {
            if !committed {
                removeOwnedItem(imageURL, identity: imageIdentity)
                removeOwnedItem(movURL, identity: movieIdentity)
            }
        }
        try fm.moveItem(at: stagedImage, to: imageURL)
        try Task.checkCancellation()
        try fm.moveItem(at: stagedMovie, to: movURL)
        try Task.checkCancellation()
        committed = true
        return ConversionResult(
            imageURL: imageURL, movURL: movURL, assetID: assetID, baseName: baseName,
            clipDuration: outDuration, videoWasCopied: videoWasCopied, stillTime: actualTime.seconds
        )
    }

    // MARK: output ownership

    private static func canonicalOutputDirectory(_ url: URL) throws -> URL {
        // /var and /tmp are normal macOS parent aliases. Resolve parents once,
        // but inspect the requested leaf first so it cannot alias another pair.
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory else {
                throw EngineError.cannotWrite("Output directory must be a real directory")
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            // A missing leaf is created only after validating the canonical path.
        }
        return try physicalDirectoryURL(url.deletingLastPathComponent())
            .appendingPathComponent(url.lastPathComponent, isDirectory: true)
    }

    /// Foundation's path standardization can turn /private/var back into /var.
    /// Keep the physical path from realpath, including when new parents are needed.
    static func physicalDirectoryURL(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.path.utf8.contains(0) else {
            throw EngineError.cannotWrite("Invalid local directory")
        }
        var ancestor = url
        var missing: [String] = []
        while true {
            if let resolved = Darwin.realpath(ancestor.path, nil) {
                defer { Darwin.free(resolved) }
                var physical = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
                for component in missing.reversed() {
                    physical.appendPathComponent(component, isDirectory: true)
                }
                return physical
            }
            let code = errno
            guard code == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            guard ancestor.path != "/" else { throw POSIXError(.ENOENT) }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { throw POSIXError(.ENOENT) }
            missing.append(ancestor.lastPathComponent)
            ancestor = parent
        }
    }

    private static func validateOutputDirectory(_ url: URL) throws {
        var current = url
        while true {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: current.path)
                let type = attrs[.type] as? FileAttributeType
                guard type == .typeDirectory else {
                    throw EngineError.cannotWrite("Output directory components must be real directories: \(current.path) [\(type?.rawValue ?? "unknown")]")
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
                // A new directory is allowed, but every existing ancestor is checked.
            }
            // URL.deletingLastPathComponent() may append ".." at the volume
            // root. The physical root has already been checked and ends the walk.
            if current.path == "/" { return }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
    }

    private static func requireAbsent(_ url: URL) throws {
        // attributesOfItem also detects a dangling symbolic link.
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            return
        }
        throw EngineError.cannotWrite("Output already exists: \(url.lastPathComponent)")
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private static func fileIdentity(_ url: URL) throws -> FileIdentity {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attrs[.systemNumber] as? NSNumber,
              let inode = attrs[.systemFileNumber] as? NSNumber else {
            throw EngineError.cannotWrite("Cannot determine output ownership")
        }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }

    private static func removeOwnedItem(_ url: URL, identity: FileIdentity) {
        guard (try? fileIdentity(url)) == identity else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Opt-in diagnostics only. File writes have their own lock and never wait
    /// on an input queue. Release builds never create a trace or copy media.
    private final class WriterTrace: @unchecked Sendable {
        #if DEBUG
        private let lock = NSLock()
        private let directory: URL
        private let source: URL?
        private let output: URL
        private let handle: FileHandle
        private let operationID: String
        private var sequence = 0
        private var phase = "setup"
        private var preservedFailure = false
        #endif

        init?(asset: AVAsset, output: URL) {
            #if DEBUG
            guard let path = ProcessInfo.processInfo.environment["REVIVE_WRITER_TRACE_DIR"],
                  !path.isEmpty else { return nil }
            let operationID = UUID().uuidString
            let directory = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("writer-\(operationID)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let log = directory.appendingPathComponent("writer.jsonl")
                guard FileManager.default.createFile(atPath: log.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else { return nil }
                self.handle = try FileHandle(forWritingTo: log)
            } catch { return nil }
            self.directory = directory
            self.operationID = operationID
            self.source = (asset as? AVURLAsset)?.url
            self.output = output
            event("trace.begin", fields: ["assetURL": source?.absoluteString ?? "unknown",
                                          "outputURL": output.absoluteString,
                                          "expectedSamples": "NOT_SCANNED",
                                          "pid": ProcessInfo.processInfo.processIdentifier])
            #else
            return nil
            #endif
        }

        func event(_ name: String, phase: String? = nil, fields: [String: Any] = [:]) {
            #if DEBUG
            lock.lock(); defer { lock.unlock() }
            if let phase { self.phase = phase }
            sequence += 1
            var record = fields
            record["event"] = name
            record["phase"] = self.phase
            record["operationID"] = operationID
            record["sequence"] = sequence
            record["unixTime"] = Date().timeIntervalSince1970
            record["uptimeNanoseconds"] = DispatchTime.now().uptimeNanoseconds
            guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
            data.append(0x0a)
            try? handle.write(contentsOf: data)
            #endif
        }

        static func sampleFields(_ sample: CMSampleBuffer) -> [String: Any] {
            func number(_ time: CMTime) -> Any { time.seconds.isFinite ? time.seconds as Any : NSNull() }
            return ["pts": number(CMSampleBufferGetPresentationTimeStamp(sample)),
                    "dts": number(CMSampleBufferGetDecodeTimeStamp(sample)),
                    "duration": number(CMSampleBufferGetDuration(sample)),
                    "sampleCount": CMSampleBufferGetNumSamples(sample)]
        }

        /// Best effort forensic copies; never rename, delete or change sources.
        /// A partial output copied while native writing is stuck may be invalid.
        func preserveFailure(_ reason: String) {
            #if DEBUG
            lock.lock()
            guard !preservedFailure else { lock.unlock(); return }
            preservedFailure = true
            lock.unlock()
            event("failure.preserve.enter", fields: ["reason": reason])
            for (label, url) in [("partial-output", Optional(output)), ("prepared-source", source)] {
                guard let url, url.isFileURL else { continue }
                let suffix = url.pathExtension.isEmpty ? "MOV" : url.pathExtension
                let destination = directory.appendingPathComponent("\(label).\(suffix)")
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    event("failure.preserve.copied", fields: ["kind": label,
                          "sourceURL": url.absoluteString, "copyURL": destination.absoluteString])
                } catch {
                    event("failure.preserve.failed", fields: ["kind": label,
                          "error": error.localizedDescription])
                }
            }
            event("failure.preserve.return")
            #endif
        }
    }

    /// All accesses, including forced stop, stay on this input's serial queue.
    /// A failed writer may never invoke another readiness callback.
    final class WritePump: @unchecked Sendable {
        let queue: DispatchQueue
        private let group: DispatchGroup
        private(set) var isFinished = false
        private let diagnosticLock = NSLock()
        private var phase = "waiting for first readiness callback"
        private var samples = 0
        private var lastPTS: Double?
        private var lastDTS: Double?
        private var reads = 0
        private var appendAttempts = 0
        private var sampleCount = 0
        private var eof = false
        private var markedFinished = false

        init(label: String, group: DispatchGroup) {
            queue = DispatchQueue(label: label)
            self.group = group
            group.enter()
        }

        func finish(_ beforeLeave: () -> Void = {}) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard !isFinished else { return }
            isFinished = true
            note("finished")
            beforeLeave()
            group.leave()
        }

        func note(_ phase: String, appendedPTS: Double? = nil, appendedDTS: Double? = nil) {
            diagnosticLock.lock(); defer { diagnosticLock.unlock() }
            self.phase = phase
            if phase == "appending sample" || phase == "appending metadata" { appendAttempts += 1 }
            if let appendedPTS { samples += 1; lastPTS = appendedPTS }
            if let appendedDTS { lastDTS = appendedDTS }
            if phase == "EOF" { eof = true }
            if phase == "markAsFinished returned" { markedFinished = true }
        }

        func noteRead(_ sample: CMSampleBuffer) {
            diagnosticLock.lock(); defer { diagnosticLock.unlock() }
            reads += 1
            sampleCount += CMSampleBufferGetNumSamples(sample)
        }

        func snapshot(ready: Bool) -> [String: Any] {
            diagnosticLock.lock(); defer { diagnosticLock.unlock() }
            func number(_ value: Double?) -> Any {
                guard let value, value.isFinite else { return NSNull() }
                return value
            }
            return ["queue": queue.label, "phase": phase, "ready": ready,
                    "readBuffers": reads, "readSamples": sampleCount,
                    "appendAttempts": appendAttempts, "appendBuffers": samples,
                    "lastPTS": number(lastPTS), "lastDTS": number(lastDTS),
                    "eof": eof, "markAsFinishedReturned": markedFinished]
        }

        var diagnostic: String {
            diagnosticLock.lock(); defer { diagnosticLock.unlock() }
            return "\(queue.label): \(phase), samples=\(samples), lastPTS=\(lastPTS.map(String.init(describing:)) ?? "none")"
        }
    }

    /// Preserve the first failure and drain every input before native teardown.
    /// Setup may still be registering callbacks when cancellation first arrives.
    final class FailureCoordinator: @unchecked Sendable {
        private let lock = NSLock()
        private let finishQueue: DispatchQueue
        private var firstError: Error?
        private var setupReady = false
        private var stopScheduled = false
        private var didFinish = false
        private var pumps: [WritePump] = []
        private var onFailure: ((Error) -> Void)?
        private let observe: ((String, [String: Any]) -> Void)?

        init(finishQueue: DispatchQueue, observe: ((String, [String: Any]) -> Void)? = nil) {
            self.finishQueue = finishQueue
            self.observe = observe
        }

        var shouldStop: Bool {
            lock.lock(); defer { lock.unlock() }
            return firstError != nil || didFinish
        }

        func fail(_ error: Error) {
            lock.lock()
            guard !didFinish else { lock.unlock(); return }
            let isFirstFailure = firstError == nil
            if firstError == nil { firstError = error }
            let stop = stopWorkIfReady()
            lock.unlock()
            if isFirstFailure { observe?("failure.recorded", ["error": error.localizedDescription]) }
            stop?()
        }

        func activate(pumps: [WritePump], onFailure: @escaping (Error) -> Void) {
            lock.lock()
            guard !setupReady else { lock.unlock(); return }
            self.pumps = pumps
            self.onFailure = onFailure
            setupReady = true
            let stop = stopWorkIfReady()
            lock.unlock()
            stop?()
        }

        @discardableResult
        func finishSuccessfully(_ finish: () -> Void) -> Bool {
            lock.lock()
            guard setupReady, firstError == nil, !didFinish else { lock.unlock(); return false }
            didFinish = true
            pumps = []
            onFailure = nil
            lock.unlock()
            finish()
            return true
        }

        // Called under lock; invoke the returned work only after unlocking.
        private func stopWorkIfReady() -> (() -> Void)? {
            guard setupReady, !stopScheduled, let error = firstError,
                  let onFailure else { return nil }
            stopScheduled = true
            let pending = pumps
            let finishQueue = finishQueue
            let observe = observe
            pumps = []
            self.onFailure = nil
            return {
                let drained = DispatchGroup()
                for pump in pending {
                    drained.enter()
                    observe?("drain.enqueued", ["queue": pump.queue.label])
                    pump.queue.async {
                        observe?("drain.enter", ["queue": pump.queue.label])
                        pump.finish()
                        observe?("drain.return", ["queue": pump.queue.label])
                        drained.leave()
                    }
                }
                drained.notify(queue: finishQueue) {
                    observe?("drain.allReturned", [:])
                    onFailure(error)
                }
            }
        }
    }

    /// AVFoundation callbacks may stop arriving after cancellation or failure.
    /// Resume the awaiting task exactly once, independently of dispatch groups.
    private final class WriteCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?
        private var timer: DispatchSourceTimer?
        private var lastProgress = DispatchTime.now().uptimeNanoseconds

        var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }
            return result != nil
        }

        func begin(_ continuation: CheckedContinuation<Void, Error>, timer: DispatchSourceTimer) -> Bool {
            lock.lock()
            if let result {
                lock.unlock()
                timer.cancel()
                continuation.resume(with: result)
                return false
            }
            self.continuation = continuation
            self.timer = timer
            lock.unlock()
            return true
        }

        func noteProgress() {
            lock.lock(); lastProgress = DispatchTime.now().uptimeNanoseconds; lock.unlock()
        }

        var hasStalled: Bool {
            lock.lock(); defer { lock.unlock() }
            return result == nil && DispatchTime.now().uptimeNanoseconds - lastProgress > 120_000_000_000
        }

        func finish(_ outcome: Result<Void, Error>, beforeResume: () -> Void = {}) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = outcome
            let waiting = continuation
            continuation = nil
            let watchdog = timer
            timer = nil
            lock.unlock()
            watchdog?.cancel()
            beforeResume()
            waiting?.resume(with: outcome)
        }
    }

    // MARK: still extraction

    private static func extractStill(
        asset: AVAsset, at time: Double, to url: URL, heic: Bool, assetID: String
    ) async throws -> CMTime {
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let duration = try await asset.load(.duration)
        var cmTime = CMTime(seconds: time, preferredTimescale: 60_000)
        // A valid value just below the end can round up to the excluded endpoint.
        if cmTime >= duration {
            cmTime = duration - CMTime(value: 1, timescale: 60_000)
        }
        guard cmTime.isNumeric, cmTime >= .zero, cmTime < duration else {
            throw EngineError.stillExtractionFailed("Cover time is outside the rendered video")
        }
        let cgImage: CGImage
        let actualTime: CMTime
        do {
            (cgImage, actualTime) = try await withTaskCancellationHandler {
                try await generator.image(at: cmTime)
            } onCancel: {
                generator.cancelAllCGImageGeneration()
            }
        } catch {
            if Task.isCancelled { throw EngineError.cancelled }
            throw EngineError.stillExtractionFailed(error.localizedDescription)
        }

        try Task.checkCancellation()

        let type = heic ? UTType.heic : UTType.jpeg
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw EngineError.stillExtractionFailed("Couldn't create \(type.preferredFilenameExtension ?? "") destination")
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: heic ? 0.95 : 0.98,
            kCGImagePropertyMakerAppleDictionary: [makerAppleAssetIDKey: assetID],
        ]
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw EngineError.stillExtractionFailed("image encoding failed")
        }
        return actualTime
    }

    // MARK: exact trim (one visually lossless-ish re-encode, frame accurate)

    private static func exactTrimExport(asset: AVAsset, start: Double, end: Double, to url: URL) async throws {
        let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let preset = presets.contains(AVAssetExportPresetHEVCHighestQuality)
            ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw EngineError.cannotWrite("couldn't create export session")
        }
        session.outputURL = url
        session.outputFileType = .mov
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        try Task.checkCancellation()
        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            session.cancelExport()
        }
        try Task.checkCancellation()
        if session.status != .completed {
            throw EngineError.cannotWrite(session.error?.localizedDescription ?? "export failed")
        }
    }

    // MARK: codec compatibility (copy vs. re-encode, decided per track)

    /// Video codecs a QuickTime .mov accepts for stream-copy passthrough.
    private static let passthroughVideoCodecs: Set<FourCharCode> = [
        kCMVideoCodecType_H264,
        kCMVideoCodecType_HEVC,
        kCMVideoCodecType_HEVCWithAlpha,
        kCMVideoCodecType_AppleProRes4444XQ,
        kCMVideoCodecType_AppleProRes4444,
        kCMVideoCodecType_AppleProRes422HQ,
        kCMVideoCodecType_AppleProRes422,
        kCMVideoCodecType_AppleProRes422LT,
        kCMVideoCodecType_AppleProRes422Proxy,
        kCMVideoCodecType_JPEG,
        kCMVideoCodecType_JPEG_OpenDML,
    ]

    /// Audio formats a QuickTime .mov accepts for stream-copy passthrough.
    private static let passthroughAudioFormats: Set<FourCharCode> = [
        kAudioFormatMPEG4AAC,
        kAudioFormatMPEG4AAC_HE,
        kAudioFormatMPEG4AAC_HE_V2,
        kAudioFormatMPEG4AAC_LD,
        kAudioFormatMPEG4AAC_ELD,
        kAudioFormatAppleLossless,
        kAudioFormatLinearPCM,
    ]

    // Debug-only test hook: REVIVE_FORCE_REENCODE=1 forces the video re-encode
    // branch even for a copy-compatible codec, so the transcode path can be
    // exercised on a codec the OS can actually decode (e.g. H.264). Release
    // builds always return false (the whole check is compiled out).
    private static var forceReencodeVideo: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["REVIVE_FORCE_REENCODE"] == "1"
        #else
        return false
        #endif
    }

    private static func isPassthroughCompatible(_ desc: CMFormatDescription, mediaType: AVMediaType) -> Bool {
        let subtype = CMFormatDescriptionGetMediaSubType(desc)
        if mediaType == .video { return !forceReencodeVideo && passthroughVideoCodecs.contains(subtype) }
        if mediaType == .audio { return passthroughAudioFormats.contains(subtype) }
        return false
    }

    static func isVideoPassthroughCompatible(_ track: AVAssetTrack) async -> Bool {
        if forceReencodeVideo { return false }
        guard let desc = try? await track.load(.formatDescriptions).first else { return false }
        return passthroughVideoCodecs.contains(CMFormatDescriptionGetMediaSubType(desc))
    }

    /// Near visually-lossless HEVC (VideoToolbox constant-quality). Used only
    /// when the source video codec cannot be stream-copied into a .mov.
    private static func reencodeVideoSettings(width: Int, height: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: 0.9,
            ],
        ]
    }

    private static func reencodeAudioSettings(sampleRate: Double, channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate > 0 ? sampleRate : 44_100,
            AVNumberOfChannelsKey: max(1, channels),
            AVEncoderBitRateKey: 256_000,
        ]
    }

    private static let videoDecodeSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ]
    private static let audioDecodeSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    // MARK: writer (lossless passthrough per track; re-encode only when forced)
    //
    // Returns true iff the video track was stream-copied (bit-for-bit).

    @discardableResult
    private static func passthroughWrite(
        asset: AVAsset, to url: URL, assetID: String,
        timeRange: CMTimeRange?, stillTimeAbs: CMTime, dropAudio: Bool = false,
        allowVideoReencode: Bool = true
    ) async throws -> Bool {
        try Task.checkCancellation()
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw EngineError.cannotRead(error.localizedDescription) }
        if let timeRange { reader.timeRange = timeRange }

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mov) }
        catch { throw EngineError.cannotWrite(error.localizedDescription) }
        let trace = WriterTrace(asset: asset, output: url)
        defer {
            trace?.event("scope.exit", fields: ["readerStatus": reader.status.rawValue,
                                                "writerStatus": writer.status.rawValue])
            if writer.status != .completed { trace?.preserveFailure("scope exited without completed writer") }
            if reader.status == .reading {
                trace?.event("defer.cancelReading.enter", phase: "cancelling reader")
                reader.cancelReading()
                trace?.event("defer.cancelReading.return", fields: ["readerStatus": reader.status.rawValue])
            }
            if writer.status == .writing {
                trace?.event("defer.cancelWriting.enter", phase: "cancelling writer")
                writer.cancelWriting()
                trace?.event("defer.cancelWriting.return", fields: ["writerStatus": writer.status.rawValue])
            }
        }
        writer.metadata = topLevelMetadata(assetID: assetID)
        writer.movieTimeScale = 60_000

        var videoCopied = true
        var markerFrameDuration = CMTime(value: 1, timescale: 30)
        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        let tracks = try await asset.load(.tracks)
        for track in tracks where track.mediaType == .video || (track.mediaType == .audio && !dropAudio) {
            guard let formatDesc = try await track.load(.formatDescriptions).first else { continue }
            let compatible = track.mediaType == .video && !allowVideoReencode
                ? passthroughVideoCodecs.contains(CMFormatDescriptionGetMediaSubType(formatDesc))
                : isPassthroughCompatible(formatDesc, mediaType: track.mediaType)
            guard allowVideoReencode || track.mediaType != .video || compatible else {
                throw EngineError.cannotWrite("Final movie would require another video encode")
            }

            // reader: nil = deliver compressed samples (copy); settings = decode
            let readerSettings: [String: Any]?
            let writerSettings: [String: Any]?
            if compatible {
                readerSettings = nil
                writerSettings = nil
            } else if track.mediaType == .video {
                let size = try await track.load(.naturalSize)
                readerSettings = videoDecodeSettings
                writerSettings = reencodeVideoSettings(
                    width: Int(abs(size.width)), height: Int(abs(size.height)))
                videoCopied = false
            } else {
                var sampleRate = 44_100.0
                var channels = 2
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee {
                    sampleRate = asbd.mSampleRate
                    channels = Int(asbd.mChannelsPerFrame)
                }
                readerSettings = audioDecodeSettings
                writerSettings = reencodeAudioSettings(sampleRate: sampleRate, channels: channels)
            }

            let output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
            guard reader.canAdd(output) else { throw EngineError.cannotRead("can't read \(track.mediaType.rawValue) track") }
            reader.add(output)

            let input: AVAssetWriterInput
            if writerSettings == nil {  // passthrough
                input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil,
                                           sourceFormatHint: formatDesc)
            } else {                    // re-encode
                input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: writerSettings)
            }
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video {
                input.transform = try await track.load(.preferredTransform)
                let frameDuration = try await track.load(.minFrameDuration)
                if frameDuration.isNumeric, frameDuration.seconds > 0 {
                    markerFrameDuration = frameDuration
                } else {
                    let frameRate = try await track.load(.nominalFrameRate)
                    if frameRate.isFinite, frameRate > 0 {
                        markerFrameDuration = CMTime(seconds: 1 / Double(frameRate), preferredTimescale: 60_000)
                    }
                }
            }
            guard writer.canAdd(input) else { throw EngineError.cannotWrite("can't write \(track.mediaType.rawValue) track") }
            writer.add(input)
            pairs.append((output, input))
            trace?.event("track.configured", fields: ["index": pairs.count - 1,
                          "mediaType": track.mediaType.rawValue, "passthrough": compatible,
                          "expectedCompressedSamples": "NOT_SCANNED"])
        }
        guard pairs.contains(where: { $0.1.mediaType == .video }) else { throw EngineError.noVideoTrack }

        let metaInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                           sourceFormatHint: try stillImageTimeFormatDescription())
        metaInput.mediaTimeScale = 60_000
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metaInput)
        guard writer.canAdd(metaInput) else { throw EngineError.cannotWrite("can't add still-image-time metadata track") }
        writer.add(metaInput)

        let markerEnd: CMTime
        if let timeRange { markerEnd = timeRange.end }
        else { markerEnd = try await asset.load(.duration) }
        let remaining = CMTimeSubtract(markerEnd, stillTimeAbs)
        guard remaining.isNumeric, remaining.seconds > 0 else {
            throw EngineError.cannotWrite("still-image-time sample must be inside the movie")
        }
        // Give the marker the selected frame's interval, clipped at the end.
        // A one-tick interval can round to an empty edit and disappear on read.
        let markerDuration = CMTimeMinimum(markerFrameDuration, remaining)
        trace?.event("startReading.enter", phase: "starting reader")
        let readingStarted = reader.startReading()
        trace?.event("startReading.return", fields: ["result": readingStarted,
                                                    "readerStatus": reader.status.rawValue])
        guard readingStarted else {
            throw EngineError.cannotRead(reader.error?.localizedDescription ?? "startReading failed")
        }
        trace?.event("startWriting.enter", phase: "starting writer")
        let writingStarted = writer.startWriting()
        trace?.event("startWriting.return", fields: ["result": writingStarted,
                                                    "writerStatus": writer.status.rawValue])
        guard writingStarted else {
            throw EngineError.cannotWrite(writer.error?.localizedDescription ?? "startWriting failed")
        }
        let sessionStart = timeRange?.start ?? .zero
        trace?.event("startSession.enter", fields: ["start": sessionStart.seconds])
        writer.startSession(atSourceTime: sessionStart)
        trace?.event("startSession.return", phase: "pumping", fields: ["stillTime": stillTimeAbs.seconds,
                                                                     "markerDuration": markerDuration.seconds])

        let stillGroup = AVTimedMetadataGroup(
            items: [item(keyStillImageTime, NSNumber(value: 0), "com.apple.metadata.datatype.int8")],
            timeRange: CMTimeRange(
                start: stillTimeAbs,
                duration: markerDuration
            )
        )

        let completion = WriteCompletion()
        let finishQueue = DispatchQueue(label: "revive.finish")
        let failure = FailureCoordinator(finishQueue: finishQueue, observe: trace.map { trace in
            { name, fields in trace.event(name, phase: "draining", fields: fields) }
        })
        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            let metaPump = WritePump(label: "revive.meta", group: group)
            let mediaPumps = pairs.enumerated().map { index, pair in
                WritePump(label: "revive.pump.\(index).\(pair.1.mediaType.rawValue)", group: group)
            }
            let pumps = [metaPump] + mediaPumps
            let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "revive.watchdog"))
            watchdog.schedule(deadline: .now() + 5, repeating: 5)
            watchdog.setEventHandler {
                // This observation must not depend on finishQueue progressing.
                // Native readiness is sampled directly; never queue.sync a pump.
                trace?.event("watchdog.snapshot", fields: ["readerStatus": reader.status.rawValue,
                    "writerStatus": writer.status.rawValue, "stalled": completion.hasStalled,
                    "shouldStop": failure.shouldStop, "pumps": pumps.enumerated().map { index, pump in
                        pump.snapshot(ready: index == 0 ? metaInput.isReadyForMoreMediaData
                                                       : pairs[index - 1].1.isReadyForMoreMediaData)
                    }])
                if completion.hasStalled { trace?.preserveFailure("watchdog no-progress deadline") }
                finishQueue.async {
                    guard !failure.shouldStop else { return }
                    if reader.status == .failed {
                        failure.fail(EngineError.cannotRead(reader.error?.localizedDescription ?? "read failed"))
                    } else if writer.status == .failed {
                        failure.fail(EngineError.cannotWrite(writer.error?.localizedDescription ?? "writing failed"))
                    } else if completion.hasStalled {
                        let detail = pumps.map(\.diagnostic).joined(separator: "; ")
                        trace?.event("watchdog.failure", phase: "draining", fields: ["detail": detail])
                        failure.fail(EngineError.cannotWrite("Media writer made no progress for 120 seconds; reader=\(reader.status.rawValue), writer=\(writer.status.rawValue); \(detail)"))
                    }
                }
            }
            // A suspended dispatch source must be resumed even on early cancel.
            watchdog.resume()
            guard completion.begin(cont, timer: watchdog) else { return }
            // Enter every input before any callback can fail or finish. Forced
            // stop runs on these same queues, even for inputs never made ready.
            metaInput.requestMediaDataWhenReady(on: metaPump.queue) {
                guard !metaPump.isFinished, !failure.shouldStop else { return }
                metaPump.note("readiness callback: ready=\(metaInput.isReadyForMoreMediaData)")
                trace?.event("readiness", fields: ["queue": metaPump.queue.label,
                                                   "ready": metaInput.isReadyForMoreMediaData])
                guard metaInput.isReadyForMoreMediaData else { return }
                metaPump.note("appending metadata")
                trace?.event("metadata.append.enter", fields: ["pts": stillTimeAbs.seconds,
                                                              "duration": markerDuration.seconds])
                if !adaptor.append(stillGroup) {
                    trace?.event("metadata.append.return", fields: ["result": false,
                                                                   "writerStatus": writer.status.rawValue])
                    failure.fail(EngineError.cannotWrite(
                        "still-image-time append failed: \(writer.error?.localizedDescription ?? "?")"))
                    return
                }
                trace?.event("metadata.append.return", fields: ["result": true,
                                                               "writerStatus": writer.status.rawValue])
                metaPump.note("metadata appended", appendedPTS: stillTimeAbs.seconds)
                completion.noteProgress()
                metaPump.finish {
                    if !failure.shouldStop, writer.status == .writing {
                        metaPump.note("markAsFinished entered")
                        trace?.event("markAsFinished.enter", fields: ["queue": metaPump.queue.label])
                        metaInput.markAsFinished()
                        metaPump.note("markAsFinished returned")
                        trace?.event("markAsFinished.return", fields: ["queue": metaPump.queue.label])
                    }
                }
            }

            for (index, (output, input)) in pairs.enumerated() {
                let pump = mediaPumps[index]
                input.requestMediaDataWhenReady(on: pump.queue) {
                    guard !pump.isFinished, !failure.shouldStop else { return }
                    pump.note("readiness callback: ready=\(input.isReadyForMoreMediaData)")
                    trace?.event("readiness", fields: ["queue": pump.queue.label,
                                                       "ready": input.isReadyForMoreMediaData])
                    while input.isReadyForMoreMediaData {
                        guard !failure.shouldStop else { return }
                        pump.note("reading sample")
                        trace?.event("read.enter", fields: ["queue": pump.queue.label])
                        if let sbuf = output.copyNextSampleBuffer() {
                            pump.noteRead(sbuf)
                            trace?.event("read.return", fields: WriterTrace.sampleFields(sbuf).merging(
                                ["queue": pump.queue.label, "hasSample": true]) { _, new in new })
                            guard !failure.shouldStop else { return }
                            pump.note("appending sample")
                            trace?.event("append.enter", fields: WriterTrace.sampleFields(sbuf).merging(
                                ["queue": pump.queue.label]) { _, new in new })
                            if !input.append(sbuf) {
                                trace?.event("append.return", fields: ["queue": pump.queue.label, "result": false,
                                                                     "writerStatus": writer.status.rawValue])
                                failure.fail(EngineError.cannotWrite(
                                    "sample append failed: \(writer.error?.localizedDescription ?? "?")"))
                                return
                            }
                            pump.note("sample appended", appendedPTS: CMSampleBufferGetPresentationTimeStamp(sbuf).seconds,
                                      appendedDTS: CMSampleBufferGetDecodeTimeStamp(sbuf).seconds)
                            trace?.event("append.return", fields: ["queue": pump.queue.label, "result": true,
                                                                 "writerStatus": writer.status.rawValue])
                            completion.noteProgress()
                        } else {
                            trace?.event("read.return", fields: ["queue": pump.queue.label, "hasSample": false,
                                                                "readerStatus": reader.status.rawValue])
                            if reader.status == .failed {
                                failure.fail(EngineError.cannotRead(reader.error?.localizedDescription ?? "read failed"))
                                return
                            }
                            pump.note("EOF")
                            trace?.event("EOF", fields: ["queue": pump.queue.label,
                                                         "readerStatus": reader.status.rawValue])
                            pump.finish {
                                if !failure.shouldStop, writer.status == .writing {
                                    pump.note("markAsFinished entered")
                                    trace?.event("markAsFinished.enter", fields: ["queue": pump.queue.label])
                                    input.markAsFinished()
                                    pump.note("markAsFinished returned")
                                    trace?.event("markAsFinished.return", fields: ["queue": pump.queue.label])
                                }
                            }
                            return
                        }
                    }
                    pump.note("not ready; waiting for next callback")
                    trace?.event("readiness.wait", fields: ["queue": pump.queue.label,
                                                           "ready": input.isReadyForMoreMediaData])
                }
            }

            failure.activate(pumps: pumps) { error in
                // All input queues have drained; no copy, append or normal EOF
                // marker can overlap native cancellation or output cleanup.
                trace?.event("failure.drained", fields: ["error": error.localizedDescription,
                    "readerStatus": reader.status.rawValue, "writerStatus": writer.status.rawValue])
                trace?.preserveFailure(error.localizedDescription)
                if reader.status == .reading {
                    trace?.event("cancelReading.enter", phase: "cancelling reader")
                    reader.cancelReading()
                    trace?.event("cancelReading.return", fields: ["readerStatus": reader.status.rawValue])
                }
                if writer.status == .writing {
                    trace?.event("cancelWriting.enter", phase: "cancelling writer")
                    writer.cancelWriting()
                    trace?.event("cancelWriting.return", fields: ["writerStatus": writer.status.rawValue])
                }
                trace?.event("completion.failure", phase: "failed")
                completion.finish(.failure(error))
            }
            group.notify(queue: finishQueue) {
                trace?.event("group.notify", fields: ["readerStatus": reader.status.rawValue,
                                                      "writerStatus": writer.status.rawValue,
                                                      "shouldStop": failure.shouldStop])
                guard !failure.shouldStop else { return }
                if reader.status == .failed {
                    failure.fail(EngineError.cannotRead(reader.error?.localizedDescription ?? "read failed"))
                    return
                }
                if writer.status == .failed {
                    failure.fail(EngineError.cannotWrite(writer.error?.localizedDescription ?? "writing failed"))
                    return
                }
                trace?.event("finishWriting.enter", phase: "finishing writer")
                writer.finishWriting {
                    trace?.event("finishWriting.callback", fields: ["writerStatus": writer.status.rawValue,
                                                                    "shouldStop": failure.shouldStop])
                    guard !failure.shouldStop else { return }
                    if writer.status != .completed {
                        failure.fail(EngineError.cannotWrite(writer.error?.localizedDescription ?? "writing did not complete"))
                        return
                    }
                    failure.finishSuccessfully {
                        trace?.event("completion.success", phase: "completed")
                        completion.finish(.success(()))
                    }
                }
                trace?.event("finishWriting.return")
            }
          }
        } onCancel: {
            trace?.event("task.cancel", phase: "draining")
            failure.fail(EngineError.cancelled)
        }
        return videoCopied
    }
}
