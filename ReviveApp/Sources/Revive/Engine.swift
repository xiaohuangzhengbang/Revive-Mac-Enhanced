import AVFoundation
import AudioToolbox
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

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
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw EngineError.noVideoTrack
        }

        let trimStart = max(0, min(settings.trimStart, duration))
        let trimEnd = settings.trimEnd > 0 ? min(settings.trimEnd, duration) : duration
        let requestedDuration = max(0.1, trimEnd - trimStart)
        let frameRel = min(settings.frameTime ?? requestedDuration / 2, requestedDuration)
        let stillTimeAbs = trimStart + frameRel

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let imageURL = outputDir.appendingPathComponent("\(baseName).\(settings.useHEIC ? "HEIC" : "JPG")")
        let movURL = outputDir.appendingPathComponent("\(baseName).MOV")
        try? FileManager.default.removeItem(at: imageURL)
        try? FileManager.default.removeItem(at: movURL)

        let assetID = UUID().uuidString.uppercased()

        // still first (from the source, frame-accurate, full resolution)
        // progress emits string KEYS; the UI localizes them (see Localizer)
        progress?("prog_still")
        try await extractStill(asset: asset, at: stillTimeAbs, to: imageURL,
                               heic: settings.useHEIC, assetID: assetID)

        let videoWasCopied: Bool
        if settings.exactTrim {
            progress?("prog_exact")
            let tmp = outputDir.appendingPathComponent(".\(baseName).exact.mov")
            try? FileManager.default.removeItem(at: tmp)
            try await exactTrimExport(asset: asset, start: trimStart, end: trimEnd, to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let trimmed = AVURLAsset(url: tmp)
            try await passthroughWrite(asset: trimmed, to: movURL, assetID: assetID,
                                       timeRange: nil, stillTimeAbs: frameRel,
                                       dropAudio: settings.dropAudio)
            videoWasCopied = false
        } else {
            // Only the video track drives keyframe snapping: passthrough can
            // start only at a sync frame, but a re-encoded track cuts precisely.
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
            videoWasCopied = try await passthroughWrite(
                asset: asset, to: movURL, assetID: assetID,
                timeRange: range, stillTimeAbs: stillTimeAbs,
                dropAudio: settings.dropAudio)
        }

        let outDuration = try await AVURLAsset(url: movURL).load(.duration).seconds
        return ConversionResult(
            imageURL: imageURL, movURL: movURL, assetID: assetID, baseName: baseName,
            clipDuration: outDuration, videoWasCopied: videoWasCopied
        )
    }

    // MARK: still extraction

    private static func extractStill(
        asset: AVAsset, at time: Double, to url: URL, heic: Bool, assetID: String
    ) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        let cgImage: CGImage
        do {
            (cgImage, _) = try await generator.image(at: cmTime)
        } catch {
            throw EngineError.stillExtractionFailed(error.localizedDescription)
        }

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
        await session.export()
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
        timeRange: CMTimeRange?, stillTimeAbs: Double, dropAudio: Bool = false
    ) async throws -> Bool {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw EngineError.cannotRead(error.localizedDescription) }
        if let timeRange { reader.timeRange = timeRange }

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mov) }
        catch { throw EngineError.cannotWrite(error.localizedDescription) }
        writer.metadata = topLevelMetadata(assetID: assetID)

        var videoCopied = true
        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        let tracks = try await asset.load(.tracks)
        for track in tracks where track.mediaType == .video || (track.mediaType == .audio && !dropAudio) {
            guard let formatDesc = try await track.load(.formatDescriptions).first else { continue }
            let compatible = isPassthroughCompatible(formatDesc, mediaType: track.mediaType)

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
            }
            guard writer.canAdd(input) else { throw EngineError.cannotWrite("can't write \(track.mediaType.rawValue) track") }
            writer.add(input)
            pairs.append((output, input))
        }
        guard !pairs.isEmpty else { throw EngineError.noVideoTrack }

        let metaInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                           sourceFormatHint: try stillImageTimeFormatDescription())
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metaInput)
        guard writer.canAdd(metaInput) else { throw EngineError.cannotWrite("can't add still-image-time metadata track") }
        writer.add(metaInput)

        guard reader.startReading() else {
            throw EngineError.cannotRead(reader.error?.localizedDescription ?? "startReading failed")
        }
        guard writer.startWriting() else {
            throw EngineError.cannotWrite(writer.error?.localizedDescription ?? "startWriting failed")
        }
        let sessionStart = timeRange?.start ?? .zero
        writer.startSession(atSourceTime: sessionStart)

        let stillGroup = AVTimedMetadataGroup(
            items: [item(keyStillImageTime, NSNumber(value: 0), "com.apple.metadata.datatype.int8")],
            timeRange: CMTimeRange(
                start: CMTime(seconds: stillTimeAbs, preferredTimescale: 6000),
                duration: CMTime(value: 200, timescale: 3000)
            )
        )

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            let errorLock = NSLock()
            var firstError: Error?
            func recordError(_ e: Error) {
                errorLock.lock(); if firstError == nil { firstError = e }; errorLock.unlock()
            }

            group.enter()
            let metaQueue = DispatchQueue(label: "revive.meta")
            var metaDone = false
            metaInput.requestMediaDataWhenReady(on: metaQueue) {
                guard !metaDone, metaInput.isReadyForMoreMediaData else { return }
                metaDone = true
                if !adaptor.append(stillGroup) {
                    recordError(EngineError.cannotWrite(
                        "still-image-time append failed: \(writer.error?.localizedDescription ?? "?")"))
                }
                metaInput.markAsFinished()
                group.leave()
            }

            for (index, (output, input)) in pairs.enumerated() {
                group.enter()
                let queue = DispatchQueue(label: "revive.pump.\(index)")
                var done = false
                input.requestMediaDataWhenReady(on: queue) {
                    guard !done else { return }
                    while input.isReadyForMoreMediaData {
                        if let sbuf = output.copyNextSampleBuffer() {
                            if !input.append(sbuf) {
                                recordError(EngineError.cannotWrite(
                                    "sample append failed: \(writer.error?.localizedDescription ?? "?")"))
                                done = true; input.markAsFinished(); group.leave(); return
                            }
                        } else {
                            done = true; input.markAsFinished(); group.leave(); return
                        }
                    }
                }
            }

            group.notify(queue: DispatchQueue(label: "revive.finish")) {
                if reader.status == .failed {
                    recordError(EngineError.cannotRead(reader.error?.localizedDescription ?? "read failed"))
                }
                writer.finishWriting {
                    if writer.status != .completed {
                        recordError(EngineError.cannotWrite(writer.error?.localizedDescription ?? "writing did not complete"))
                    }
                    if let e = firstError { cont.resume(throwing: e) } else { cont.resume() }
                }
            }
        }
        return videoCopied
    }
}
