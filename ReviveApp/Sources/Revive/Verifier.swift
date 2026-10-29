import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import Foundation
import Darwin

struct Check: Identifiable, Codable {
    enum Status: String, Codable { case pass, fail, warn }
    let id: UUID
    let status: Status
    let label: String
    let detail: String
    let code: String

    init(status: Status, label: String, detail: String, code: String = "", id: UUID = UUID()) {
        self.id = id
        self.status = status
        self.label = label
        self.detail = detail
        self.code = code
    }
}

/// Reads actual image pixels and every media sample without writing the pair.
/// A warning is never a passing check.
enum Verifier {
    private static let stillIdentifier = "mdta/\(LivePhotoEngine.keyStillImageTime)"
    private static let int8Type = "com.apple.metadata.datatype.int8"

    static func imageAssetID(_ url: URL) -> String? {
        guard snapshot(url) != nil,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any],
              let identifier = maker[LivePhotoEngine.makerAppleAssetIDKey] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return identifier
    }

    static func videoAssetID(_ url: URL) async -> String? {
        guard snapshot(url) != nil else { return nil }
        return try? await assetID(AVURLAsset(url: url))
    }

    /// Checks the timed marker itself, rather than only its track description.
    static func hasStillImageTimeTrack(_ url: URL) async -> Bool {
        guard snapshot(url) != nil else { return false }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            let tolerance = await frameTolerance(try await asset.loadTracks(withMediaType: .video))
            let check = await inspectStill(asset, duration: duration, expectedTime: nil, tolerance: tolerance)
            return check.status == .pass
        } catch { return false }
    }

    static func verify(imageURL: URL, movURL: URL, expectedDuration: Double? = nil,
                       expectedStillTime: Double? = nil, expectedAudio: Bool? = nil) async -> [Check] {
        let localizer = Localizer.shared
        let imageBefore = snapshot(imageURL)
        let movieBefore = snapshot(movURL)
        let imageID = imageBefore == nil ? nil : imageAssetID(imageURL)
        let asset = AVURLAsset(url: movURL)
        let movieID = movieBefore == nil ? nil : (try? await assetID(asset))
        let identifiersMatch = imageID != nil && imageID == movieID
        var duration = Double.nan
        var videoTracks: [AVAssetTrack] = []
        var audioTracks: [AVAssetTrack] = []
        var loadError: String?
        if movieBefore != nil {
            do {
                duration = try await asset.load(.duration).seconds
                videoTracks = try await asset.loadTracks(withMediaType: .video)
                audioTracks = try await asset.loadTracks(withMediaType: .audio)
            } catch { loadError = error.localizedDescription }
        } else { loadError = "视频不是非空普通文件，或为符号链接。" }
        let tolerance = await frameTolerance(videoTracks)
        let still: Check
        if loadError == nil {
            still = await inspectStill(asset, duration: duration, expectedTime: expectedStillTime, tolerance: tolerance)
        } else {
            still = Check(status: .fail, label: localizer.t("v_still"), detail: loadError ?? "无法读取视频。",
                          code: "video.stillImageTime")
        }

        // Existing consumers rely on the original five checks and their order.
        var checks = [
            Check(status: imageID == nil ? .fail : .pass, label: localizer.t("v_img_id"),
                  detail: imageID ?? localizer.t("v_img_id_miss"), code: "image.assetID"),
            Check(status: movieID == nil ? .fail : .pass, label: localizer.t("v_vid_id"),
                  detail: movieID ?? localizer.t("v_vid_id_miss"), code: "video.assetID"),
            Check(status: identifiersMatch ? .pass : .fail, label: localizer.t("v_match"),
                  detail: identifiersMatch ? localizer.t("v_match_ok") : localizer.t("v_match_fail", imageID ?? "—", movieID ?? "—"),
                  code: "pair.assetID"),
            still,
            Check(status: imageURL.deletingPathExtension().lastPathComponent == movURL.deletingPathExtension().lastPathComponent ? .pass : .fail,
                  label: localizer.t("v_names"), detail: "\(imageURL.lastPathComponent) / \(movURL.lastPathComponent)", code: "pair.names"),
            Check(status: imageBefore == nil ? .fail : .pass, label: "照片文件安全检查",
                  detail: imageBefore == nil ? "照片不是非空普通文件，或为符号链接。" : "普通文件；未跟随符号链接。", code: "image.file"),
            Check(status: movieBefore == nil ? .fail : .pass, label: "视频文件安全检查",
                  detail: movieBefore == nil ? "视频不是非空普通文件，或为符号链接。" : "普通文件；未跟随符号链接。", code: "video.file")
        ]
        checks.append(imageBefore == nil
            ? Check(status: .fail, label: "JPEG 完整解码", detail: "照片文件安全检查失败。", code: "image.decode")
            : inspectImage(imageURL))
        checks.append(Check(status: movieBefore != nil && isQuickTimeMovie(movURL) ? .pass : .fail,
                            label: "MOV 容器", detail: "要求 .MOV 扩展名及 QuickTime ftyp/qt 容器标识。", code: "video.container"))
        let durationValid = duration.isFinite && duration > 0 && !videoTracks.isEmpty
        let expectedValid = expectedDuration.map { $0.isFinite && $0 > 0 && abs(duration - $0) <= tolerance } ?? true
        let expectedText = expectedDuration.map { String($0) } ?? "未指定"
        checks.append(Check(status: durationValid && expectedValid ? .pass : .fail, label: "视频时长",
                            detail: "实际 \(duration)s；预期 \(expectedText)s；帧容差 \(tolerance)s。\(loadError ?? "")", code: "video.duration"))
        checks.append(await decode(asset, tracks: videoTracks, mediaType: .video, loadError: loadError))
        if let expectedAudio {
            checks.append(Check(status: expectedAudio == !audioTracks.isEmpty && loadError == nil ? .pass : .fail,
                                label: "音轨保留设置", detail: "预期有音轨：\(expectedAudio)；实际音轨数：\(audioTracks.count)。",
                                code: "audio.presence"))
        }
        // Do not manufacture an optional audio check as a pass. Every existing
        // audio track must decode; an explicit expectation is checked separately.
        if !audioTracks.isEmpty {
            checks.append(await decode(asset, tracks: audioTracks, mediaType: .audio, loadError: loadError))
        }
        checks.append(Check(status: unchanged(imageBefore, at: imageURL) ? .pass : .fail, label: "照片保持不变",
                            detail: "校验前后文件身份、大小及修改时间必须一致。", code: "image.unchanged"))
        checks.append(Check(status: unchanged(movieBefore, at: movURL) ? .pass : .fail, label: "视频保持不变",
                            detail: "校验前后文件身份、大小及修改时间必须一致。", code: "video.unchanged"))
        return checks
    }

    private static func assetID(_ asset: AVAsset) async throws -> String? {
        let metadata = try await asset.load(.metadata)
        let matching = metadata.filter {
            $0.identifier?.rawValue == "mdta/\(LivePhotoEngine.keyContentID)" ||
                ($0.keySpace == .quickTimeMetadata && ($0.key as? String) == LivePhotoEngine.keyContentID)
        }
        guard matching.count == 1, let item = matching.first,
              item.dataType == "com.apple.metadata.datatype.UTF-8",
              let value = try await item.load(.stringValue),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func inspectImage(_ url: URL) -> Check {
        func result(_ status: Check.Status, _ detail: String) -> Check {
            Check(status: status, label: "JPEG 完整解码", detail: detail, code: "image.decode")
        }
        guard ["jpg", "jpeg"].contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width > 0, image.height > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return result(.fail, "须为完整且可解码的 JPEG，扩展名不能替代实际格式。")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard context.makeImage() != nil else { return result(.fail, "JPEG 像素解码失败。") }
        return result(.pass, "JPEG \(image.width) × \(image.height)，完整像素已解码。")
    }

    private static func inspectStill(_ asset: AVAsset, duration: Double, expectedTime: Double?, tolerance: Double) async -> Check {
        func result(_ status: Check.Status, _ detail: String) -> Check {
            Check(status: status, label: Localizer.shared.t("v_still"), detail: detail, code: "video.stillImageTime")
        }
        do {
            let tracks = try await asset.loadTracks(withMediaType: .metadata)
            var matching: [AVAssetTrack] = []
            for track in tracks {
                for description in try await track.load(.formatDescriptions) {
                    let identifiers = CMMetadataFormatDescriptionGetIdentifiers(description) as? [String] ?? []
                    if identifiers.contains(stillIdentifier) { matching.append(track); break }
                }
            }
            guard matching.count == 1, let track = matching.first else {
                return result(.fail, "要求且仅允许一条 still-image-time metadata 轨道；实际 \(matching.count)。")
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { return result(.fail, "无法添加 metadata 读取输出。") }
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else { return result(.fail, reader.error?.localizedDescription ?? "无法开始读取 metadata。") }
            var samples: [(value: NSNumber?, type: String?, start: Double, length: Double)] = []
            while let group = adaptor.nextTimedMetadataGroup() {
                if Task.isCancelled { reader.cancelReading(); return result(.fail, "metadata 校验已取消。") }
                for item in group.items where item.identifier?.rawValue == stillIdentifier ||
                    (item.keySpace == .quickTimeMetadata && (item.key as? String) == LivePhotoEngine.keyStillImageTime) {
                    samples.append((try await item.load(.numberValue), item.dataType,
                                    group.timeRange.start.seconds, group.timeRange.duration.seconds))
                }
            }
            guard reader.status == .completed else {
                return result(.fail, reader.error?.localizedDescription ?? "metadata 读取未完整完成（\(reader.status.rawValue)）。")
            }
            guard samples.count == 1, let sample = samples.first,
                  sample.type == int8Type, let value = sample.value,
                  value.doubleValue == 0, sample.start.isFinite, sample.start >= 0,
                  sample.length.isFinite, sample.length > 0, duration.isFinite, duration > 0,
                  sample.start < duration, sample.start + sample.length <= duration + tolerance else {
                return result(.fail, "须有一个 int8=0 的真实定时样本，且时间范围位于视频内；实际样本数 \(samples.count)。")
            }
            if let expectedTime {
                guard expectedTime.isFinite, expectedTime >= 0, expectedTime < duration,
                      abs(sample.start - expectedTime) <= tolerance else {
                    return result(.fail, "实际封面时间 \(sample.start)s，预期 \(expectedTime)s，帧容差 \(tolerance)s。")
                }
            }
            return result(.pass, "完整读取一个 int8=0 样本：\(sample.start)s，持续 \(sample.length)s；帧容差 \(tolerance)s。")
        } catch { return result(.fail, error.localizedDescription) }
    }

    private static func decode(_ asset: AVAsset, tracks: [AVAssetTrack], mediaType: AVMediaType, loadError: String?) async -> Check {
        let video = mediaType == .video
        func result(_ status: Check.Status, _ detail: String) -> Check {
            Check(status: status, label: video ? "视频完整解码" : "音频完整解码", detail: detail,
                  code: video ? "video.decode" : "audio.decode")
        }
        guard loadError == nil, !tracks.isEmpty else { return result(.fail, loadError ?? "缺少可解码轨道。") }
        do {
            var total = 0
            for track in tracks {
                let reader = try AVAssetReader(asset: asset)
                let settings: [String: Any] = video
                    ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    : [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                       AVLinearPCMIsNonInterleaved: false]
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { return result(.fail, "无法添加解码输出。") }
                reader.add(output)
                guard reader.startReading() else { return result(.fail, reader.error?.localizedDescription ?? "无法开始解码。") }
                var count = 0
                var valid = true
                var previous = -Double.infinity
                while let sample = output.copyNextSampleBuffer() {
                    if Task.isCancelled { reader.cancelReading(); return result(.fail, "完整解码已取消。") }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) > 0,
                          pts.isFinite, pts >= previous else { valid = false; break }
                    previous = pts
                    if video {
                        guard let pixels = CMSampleBufferGetImageBuffer(sample),
                              CVPixelBufferGetWidth(pixels) > 0, CVPixelBufferGetHeight(pixels) > 0 else { valid = false; break }
                    } else {
                        guard let data = CMSampleBufferGetDataBuffer(sample), CMBlockBufferGetDataLength(data) > 0 else { valid = false; break }
                    }
                    count += 1
                }
                guard valid, count > 0, reader.status == .completed else {
                    let status = reader.status.rawValue
                    reader.cancelReading()
                    return result(.fail, reader.error?.localizedDescription ?? "解码未完整完成：样本 \(count)，reader.status=\(status)。")
                }
                total += count
            }
            return result(.pass, "\(tracks.count) 条轨道，\(total) 个解码样本；全部 reader.status=completed。")
        } catch { return result(.fail, error.localizedDescription) }
    }

    private static func frameTolerance(_ tracks: [AVAssetTrack]) async -> Double {
        var intervals: [Double] = []
        for track in tracks {
            if let minimum = try? await track.load(.minFrameDuration).seconds, minimum.isFinite, minimum > 0 {
                intervals.append(minimum)
            } else if let fps = try? await track.load(.nominalFrameRate), fps.isFinite, fps > 0 {
                intervals.append(1 / Double(fps))
            }
        }
        return (intervals.max() ?? 1.0 / 30.0) + 0.001
    }

    private static func isQuickTimeMovie(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "mov", let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 16), bytes.count >= 12 else { return false }
        return String(data: bytes[4..<8], encoding: .ascii) == "ftyp" &&
            String(data: bytes[8..<12], encoding: .ascii) == "qt  "
    }

    private static func snapshot(_ url: URL) -> stat? {
        guard url.isFileURL else { return nil }
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { return nil }
        return info
    }

    private static func unchanged(_ before: stat?, at url: URL) -> Bool {
        guard let before, let after = snapshot(url) else { return false }
        return before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_size == after.st_size &&
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }
}