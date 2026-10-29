import AVFoundation
import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Local still-image camera motion. This does not synthesize subject movement.
/// Frames are converted to SDR sRGB; alpha is composited over opaque white.
enum StillMotion {
    struct GIFSummary: Sendable {
        let frameCount: Int
        let duration: Double
        let width: Int
        let height: Int
    }

    enum MotionError: LocalizedError {
        case invalid(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let detail): return "无法生成图片运镜：\(detail)"
            case .failed(let detail): return "图片运镜处理失败：\(detail)"
            }
        }
    }

    /// A silent 30fps H.264 movie, with a gentle, loopable zoom and pan.
    /// The final leaf must not exist; publication uses an exclusive hard link.
    static func generate(source: URL, to movieURL: URL, duration: Double = 3) async throws {
        try Task.checkCancellation()
        guard duration.isFinite, (0.5...10).contains(duration) else {
            throw MotionError.invalid("时长必须在 0.5 到 10 秒之间")
        }
        let bytes = try readStill(source)
        let sourceHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard try SafeExport.sha256(source) == sourceHash else { throw MotionError.invalid("读取期间原图发生改变") }
        guard let imageSource = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(imageSource) == 1 else {
            throw MotionError.invalid("请选择可解码的单帧 JPEG、PNG、HEIC 或其他静态图片")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
        guard let originalWidth = (properties?[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
              let originalHeight = (properties?[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue,
              originalWidth > 0, originalHeight > 0, originalWidth <= 32_768, originalHeight <= 32_768,
              originalWidth * originalHeight <= 80_000_000 else {
            throw MotionError.invalid("图片尺寸无效或超过 8000 万像素")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1920,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw MotionError.invalid("图片无法完整解码")
        }
        guard image.width >= 16, image.height >= 16 else {
            throw MotionError.invalid("缩放后的图片宽高至少需要 16 像素，请避免过小或极端长宽比的图片")
        }
        let width = max(2, image.width / 2 * 2)
        let height = max(2, image.height / 2 * 2)
        let frames = Int((duration * 30).rounded())
        let renderedDuration = Double(frames) / 30
        let output = try OutputTransaction(destination: movieURL, payloadExtension: "mp4")
        let writer = try AVAssetWriter(outputURL: output.payloadURL, fileType: .mp4)
        output.rememberPayloadIfPresent()
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(800_000, width * height * 4),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = 60_000
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ])
        guard writer.canAdd(input) else { throw MotionError.failed("当前系统无法编码 H.264") }
        writer.add(input)
        defer {
            if writer.status == .writing { writer.cancelWriting() }
            output.rememberPayloadIfPresent()
        }
        try output.requireBound()
        let started = writer.startWriting()
        output.rememberPayloadIfPresent()
        guard started else { throw writer.error ?? MotionError.failed("无法开始写入视频") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            try Task.checkCancellation()
            try await waitUntilReady(input, writer: writer)
            let buffer = try autoreleasepool {
                try render(image, width: width, height: height,
                           phase: Double(index) / Double(frames), pool: adaptor.pixelBufferPool)
            }
            // Rendering must not turn a previously-ready observation into an
            // unconditional append. Check the actual input again before append.
            try await waitUntilReady(input, writer: writer)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                throw writer.error ?? MotionError.failed("无法追加运镜帧")
            }
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 30))
        input.markAsFinished()
        try await finish(writer)
        try Task.checkCancellation()
        try await verifyMovie(output.payloadURL, frameCount: frames, duration: renderedDuration)
        guard try SafeExport.sha256(source) == sourceHash else { throw MotionError.invalid("生成期间原图发生改变") }
        try Task.checkCancellation()
        try output.publish()
    }

    /// Exports the actual rendered movie to a GIF, preserving the clip duration
    /// through distributed centisecond delays instead of rounding every frame.
    @discardableResult
    static func exportGIF(movieURL: URL, to destination: URL) async throws -> GIFSummary {
        try Task.checkCancellation()
        let originalHash = try SafeExport.sha256(movieURL)
        let asset = AVURLAsset(url: movieURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 0.1, duration <= 10,
              !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw MotionError.invalid("GIF 需要 0.1 到 10 秒的有效视频片段")
        }
        let frameCount = max(2, Int((duration * 15).rounded()))
        let totalCentiseconds = max(frameCount * 2, Int((duration * 100).rounded()))
        let output = try OutputTransaction(destination: destination, payloadExtension: "gif")
        guard let target = CGImageDestinationCreateWithURL(output.payloadURL as CFURL,
                UTType.gif.identifier as CFString, frameCount, nil) else {
            throw MotionError.failed("无法创建 GIF")
        }
        output.rememberPayloadIfPresent()
        defer { output.rememberPayloadIfPresent() }
        CGImageDestinationSetProperties(target, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var dimensions: CGSize?
        for index in 0..<frameCount {
            try Task.checkCancellation()
            let time = CMTime(seconds: Double(index) * duration / Double(frameCount), preferredTimescale: 60_000)
            let image: CGImage
            do {
                (image, _) = try await withTaskCancellationHandler {
                    try await generator.image(at: time)
                } onCancel: { generator.cancelAllCGImageGeneration() }
            } catch {
                try Task.checkCancellation()
                throw error
            }
            let size = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
            if let dimensions, dimensions != size { throw MotionError.failed("GIF 帧尺寸不一致") }
            dimensions = size
            let start = (Double(index) * Double(totalCentiseconds) / Double(frameCount)).rounded()
            let end = (Double(index + 1) * Double(totalCentiseconds) / Double(frameCount)).rounded()
            let delay = (end - start) / 100
            CGImageDestinationAddImage(target, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                               kCGImagePropertyGIFUnclampedDelayTime: delay]
            ] as CFDictionary)
        }
        try Task.checkCancellation()
        let finalized = CGImageDestinationFinalize(target)
        output.rememberPayloadIfPresent()
        guard finalized else { throw MotionError.failed("GIF 编码未完成") }
        let summary = try verifyGIF(output.payloadURL, expectedFrames: frameCount,
                                    expectedDuration: Double(totalCentiseconds) / 100)
        guard try SafeExport.sha256(movieURL) == originalHash else { throw MotionError.invalid("导出期间视频发生改变") }
        try Task.checkCancellation()
        try output.publish()
        return summary
    }

    private static func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? MotionError.failed("视频写入已停止") }
            guard ProcessInfo.processInfo.systemUptime - started < 30 else {
                throw MotionError.failed("视频编码 30 秒没有可写进展")
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try Task.checkCancellation()
    }

    private static func render(_ image: CGImage, width: Int, height: Int, phase: Double,
                               pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status: CVReturn
        if let pool { status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &result) }
        else {
            status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferCGImageCompatibilityKey: true,
                 kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &result)
        }
        guard status == kCVReturnSuccess, let buffer = result else { throw MotionError.failed("无法分配视频帧") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw MotionError.failed("无法绘制图片帧") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.interpolationQuality = .high
        let angle = 2 * Double.pi * phase
        let zoom = 1.02 + 0.04 * (1 - cos(angle)) / 2
        let scale = max(Double(width) / Double(image.width), Double(height) / Double(image.height)) * zoom
        let drawnWidth = Double(image.width) * scale, drawnHeight = Double(image.height) * scale
        let dx = (Double(width) - drawnWidth) / 2 + (drawnWidth - Double(width)) * 0.18 * sin(angle)
        let dy = (Double(height) - drawnHeight) / 2 + (drawnHeight - Double(height)) * 0.12 * sin(angle)
        context.draw(image, in: CGRect(x: CGFloat(dx), y: CGFloat(dy),
                                       width: CGFloat(drawnWidth), height: CGFloat(drawnHeight)))
        return buffer
    }

    private static func verifyMovie(_ url: URL, frameCount: Int, duration: Double) async throws {
        let asset = AVURLAsset(url: url)
        let actualDuration = try await asset.load(.duration).seconds
        guard actualDuration.isFinite, abs(actualDuration - duration) <= 1.0 / 30 + 0.001,
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MotionError.failed("运镜视频时长或轨道检查失败")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(output) else { throw MotionError.failed("无法检查运镜视频") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MotionError.failed("无法开始视频检查") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var decoded = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetImageBuffer(sample) != nil else {
                throw MotionError.failed("运镜视频存在无法解码的帧")
            }
            decoded += CMSampleBufferGetNumSamples(sample)
        }
        guard reader.status == .completed, decoded == frameCount else {
            throw reader.error ?? MotionError.failed("运镜视频帧数检查失败")
        }
    }

    private static func verifyGIF(_ url: URL, expectedFrames: Int, expectedDuration: Double) throws -> GIFSummary {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == expectedFrames else { throw MotionError.failed("GIF 帧数检查失败") }
        let global = CGImageSourceCopyProperties(source, nil) as? [String: Any]
        let animation = global?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        guard (animation?[kCGImagePropertyGIFLoopCount as String] as? NSNumber)?.intValue == 0 else {
            throw MotionError.failed("GIF 循环标记检查失败")
        }
        var duration = 0.0, width = 0, height = 0
        for index in 0..<expectedFrames {
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                  let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any],
                  let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime as String] ?? gif[kCGImagePropertyGIFDelayTime as String]) as? NSNumber,
                  delay.doubleValue >= 0.02 else { throw MotionError.failed("GIF 帧解码或延时检查失败") }
            if index == 0 { width = image.width; height = image.height }
            guard image.width == width, image.height == height else { throw MotionError.failed("GIF 帧尺寸检查失败") }
            duration += delay.doubleValue
        }
        guard abs(duration - expectedDuration) <= 0.011 else { throw MotionError.failed("GIF 总时长检查失败") }
        return GIFSummary(frameCount: expectedFrames, duration: duration, width: width, height: height)
    }

    private static func readStill(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw MotionError.invalid("原图必须是本地文件") }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var before = stat()
        guard Darwin.fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= 256 * 1024 * 1024 else {
            throw MotionError.invalid("原图必须是非空普通文件，且不超过 256MB")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard data.count + count <= Int(before.st_size) else { throw MotionError.invalid("读取期间原图大小改变") }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard Darwin.fstat(fd, &after) == 0, data.count == Int(before.st_size),
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw MotionError.invalid("读取期间原图发生改变")
        }
        return data
    }

    /// All append calls are finished before this cancellation bridge starts.
    /// Native finish/cancel therefore cannot race an in-progress append.
    private static func finish(_ writer: AVAssetWriter) async throws {
        let waiter = Finalization(writer: writer)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in waiter.start(continuation) }
        } onCancel: { waiter.cancel() }
    }

    private final class Finalization: @unchecked Sendable {
        private let writer: AVAssetWriter
        private let queue = DispatchQueue(label: "revive.still-motion.finish")
        private var continuation: CheckedContinuation<Void, Error>?
        private var outcome: Result<Void, Error>?
        private var timeout: DispatchWorkItem?
        init(writer: AVAssetWriter) { self.writer = writer }
        func start(_ continuation: CheckedContinuation<Void, Error>) {
            queue.async { [self] in
                if let outcome { continuation.resume(with: outcome); return }
                self.continuation = continuation
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.outcome == nil else { return }
                    if self.writer.status == .writing { self.writer.cancelWriting() }
                    self.resolve(.failure(MotionError.failed("视频收尾超过 30 秒")))
                }
                self.timeout = timeout
                queue.asyncAfter(deadline: .now() + 30, execute: timeout)
                writer.finishWriting { [self] in
                    queue.async { [self] in
                        if writer.status == .completed { resolve(.success(())) }
                        else { resolve(.failure(writer.error ?? MotionError.failed("视频未完成写入"))) }
                    }
                }
            }
        }
        func cancel() {
            queue.async { [self] in
                guard outcome == nil else { return }
                if writer.status == .writing { writer.cancelWriting() }
                resolve(.failure(CancellationError()))
            }
        }
        private func resolve(_ result: Result<Void, Error>) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard outcome == nil else { return }
            outcome = result
            let waiting = continuation
            self.continuation = nil
            let pendingTimeout = timeout
            self.timeout = nil
            pendingTimeout?.cancel()
            waiting?.resume(with: result)
        }
    }

    /// A private sibling staging directory and O_EXCL-equivalent publication.
    /// Parent and staging directory identities are checked before publication;
    /// cleanup only removes inodes created by this transaction.
    private final class OutputTransaction {
        let payloadURL: URL
        private let parent: URL
        private let name: String
        private let parentFD: Int32
        private let parentIdentity: stat
        private let stageName: String
        private let stageFD: Int32
        private let stageIdentity: stat
        private let payloadName: String
        private var payloadIdentity: stat?
        private var published = false
        init(destination: URL, payloadExtension: String) throws {
            guard destination.isFileURL, !destination.lastPathComponent.isEmpty,
                  destination.lastPathComponent != ".", destination.lastPathComponent != "..",
                  !destination.lastPathComponent.contains("\\"), !destination.path.contains("\0") else {
                throw MotionError.invalid("输出文件名或目录无效")
            }
            parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
            name = destination.lastPathComponent
            parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parentFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var parentStat = stat()
            guard Darwin.fstat(parentFD, &parentStat) == 0 else {
                Darwin.close(parentFD); throw POSIXError(.EIO)
            }
            parentIdentity = parentStat
            var existing = stat()
            if Darwin.fstatat(parentFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                Darwin.close(parentFD); throw POSIXError(.EEXIST)
            }
            guard errno == ENOENT else { Darwin.close(parentFD); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            stageName = ".revive-motion-\(UUID().uuidString)"
            guard Darwin.mkdirat(parentFD, stageName, mode_t(0o700)) == 0 else {
                Darwin.close(parentFD); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            stageFD = Darwin.openat(parentFD, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard stageFD >= 0 else {
                Darwin.unlinkat(parentFD, stageName, AT_REMOVEDIR); Darwin.close(parentFD)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var stageStat = stat()
            guard Darwin.fstat(stageFD, &stageStat) == 0 else {
                Darwin.close(stageFD); Darwin.unlinkat(parentFD, stageName, AT_REMOVEDIR); Darwin.close(parentFD)
                throw POSIXError(.EIO)
            }
            stageIdentity = stageStat
            payloadName = "render.\(payloadExtension)"
            payloadURL = parent.appendingPathComponent(stageName, isDirectory: true).appendingPathComponent(payloadName)
        }
        func requireBound() throws {
            var liveParent = stat(), liveStage = stat()
            guard Darwin.lstat(parent.path, &liveParent) == 0, same(liveParent, parentIdentity),
                  Darwin.fstatat(parentFD, stageName, &liveStage, AT_SYMLINK_NOFOLLOW) == 0,
                  same(liveStage, stageIdentity), liveStage.st_mode & S_IFMT == S_IFDIR else {
                throw MotionError.invalid("输出目录在处理中发生改变")
            }
        }
        func rememberPayloadIfPresent() {
            guard payloadIdentity == nil else { return }
            var info = stat()
            if Darwin.fstatat(stageFD, payloadName, &info, AT_SYMLINK_NOFOLLOW) == 0,
               info.st_mode & S_IFMT == S_IFREG { payloadIdentity = info }
        }
        func publish() throws {
            try requireBound()
            rememberPayloadIfPresent()
            var current = stat()
            guard let payloadIdentity, payloadIdentity.st_mode & S_IFMT == S_IFREG,
                  Darwin.fstatat(stageFD, payloadName, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_mode & S_IFMT == S_IFREG, current.st_size > 0,
                  same(current, payloadIdentity) else {
                throw MotionError.failed("缺少已验证的输出文件")
            }
            guard Darwin.linkat(stageFD, payloadName, parentFD, name, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            do {
                try requireBound()
                var final = stat()
                guard Darwin.fstatat(parentFD, name, &final, AT_SYMLINK_NOFOLLOW) == 0,
                      same(final, payloadIdentity), final.st_mode & S_IFMT == S_IFREG else {
                    throw MotionError.invalid("输出文件身份发生改变")
                }
            }
            catch {
                remove(name, identity: payloadIdentity, directoryFD: parentFD)
                throw error
            }
            published = true
        }
        deinit {
            if let payloadIdentity {
                if !published { remove(name, identity: payloadIdentity, directoryFD: parentFD) }
                remove(payloadName, identity: payloadIdentity, directoryFD: stageFD)
            }
            var current = stat()
            if Darwin.fstatat(parentFD, stageName, &current, AT_SYMLINK_NOFOLLOW) == 0,
               same(current, stageIdentity) { Darwin.unlinkat(parentFD, stageName, AT_REMOVEDIR) }
            Darwin.close(stageFD)
            Darwin.close(parentFD)
        }
        private func same(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
        private func remove(_ name: String, identity: stat, directoryFD: Int32) {
            var current = stat()
            if Darwin.fstatat(directoryFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
               same(current, identity) { Darwin.unlinkat(directoryFD, name, 0) }
        }
    }
}
