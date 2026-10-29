import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import AudioToolbox
import CoreGraphics
@testable import Revive

final class VerifierTests: XCTestCase {
    private var tmp: URL!
    private let identifier = "09A40A64-B836-4427-9790-03DDBA27D635"

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ReviveVerifierTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tmp)
    }

    func testRealJPEGAndFullyDecodableMoviePassStrictExpectations() async throws {
        let pair = try await fixture()
        let checks = await Verifier.verify(imageURL: pair.image, movURL: pair.mov,
                                            expectedDuration: 1, expectedStillTime: 0.4, expectedAudio: false)
        XCTAssertFalse(checks.isEmpty)
        for check in checks { XCTAssertEqual(check.status, .pass, "\(check.code): \(check.detail)") }
        XCTAssertEqual(checks.first { $0.code == "video.decode" }?.status, .pass)
    }

    func testDecodeIncludesRealAudioSamples() async throws {
        let pair = try await fixture(audio: true)
        let checks = await Verifier.verify(imageURL: pair.image, movURL: pair.mov,
                                            expectedDuration: 1, expectedStillTime: 0.4, expectedAudio: true)
        XCTAssertEqual(checks.first { $0.code == "audio.decode" }?.status, .pass)
        for check in checks { XCTAssertEqual(check.status, .pass, "\(check.code): \(check.detail)") }
    }

    func testRejectsWrongDurationOutsideFrameTolerance() async throws {
        let pair = try await fixture()
        let checks = await Verifier.verify(imageURL: pair.image, movURL: pair.mov, expectedDuration: 2)
        XCTAssertEqual(checks.first { $0.code == "video.duration" }?.status, .fail)
    }

    func testDurationAllowsOneFrameRounding() async throws {
        let pair = try await fixture()
        let checks = await Verifier.verify(imageURL: pair.image, movURL: pair.mov, expectedDuration: 1.02)
        XCTAssertEqual(checks.first { $0.code == "video.duration" }?.status, .pass)
    }

    func testRejectsStillSampleAtWrongTime() async throws {
        let pair = try await fixture(stillTime: 0.7)
        let checks = await Verifier.verify(imageURL: pair.image, movURL: pair.mov, expectedStillTime: 0.4)
        XCTAssertEqual(checks.first { $0.code == "video.stillImageTime" }?.status, .fail)
    }

    func testRejectsMetadataTrackWithNoStillSample() async throws {
        let pair = try await fixture(stillTime: nil)
        let checks = await Verifier.verify(imageURL: pair.image, movURL: pair.mov)
        XCTAssertEqual(checks.first { $0.code == "video.stillImageTime" }?.status, .fail)
    }

    func testRejectsNonzeroStillMarkerValue() async throws {
        let pair = try await fixture(stillValue: 1)
        let checks = await Verifier.verify(imageURL: pair.image, movURL: pair.mov)
        XCTAssertEqual(checks.first { $0.code == "video.stillImageTime" }?.status, .fail)
    }

    func testRejectsWrongStillMarkerDatatype() async throws {
        let pair = try await fixture(stillDataType: "com.apple.metadata.datatype.int32")
        let checks = await Verifier.verify(imageURL: pair.image, movURL: pair.mov)
        XCTAssertEqual(checks.first { $0.code == "video.stillImageTime" }?.status, .fail)
    }

    func testRejectsMissingExpectedAudio() async throws {
        let pair = try await fixture()
        let checks = await Verifier.verify(imageURL: pair.image, movURL: pair.mov, expectedAudio: true)
        XCTAssertEqual(checks.first { $0.code == "audio.presence" }?.status, .fail)
    }

    func testRejectsUnexpectedAudioWhenMutedWasRequested() async throws {
        let pair = try await fixture(audio: true)
        let checks = await Verifier.verify(imageURL: pair.image, movURL: pair.mov, expectedAudio: false)
        XCTAssertEqual(checks.first { $0.code == "audio.presence" }?.status, .fail)
    }

    func testRejectsNonfiniteExpectedTimes() async throws {
        let pair = try await fixture()
        let checks = await Verifier.verify(imageURL: pair.image, movURL: pair.mov,
                                            expectedDuration: .nan, expectedStillTime: .infinity)
        XCTAssertEqual(checks.first { $0.code == "video.duration" }?.status, .fail)
        XCTAssertEqual(checks.first { $0.code == "video.stillImageTime" }?.status, .fail)
    }

    func testRejectsUndecodableImageAndTruncatedMovie() async throws {
        let pair = try await fixture()
        try Data("invalid JPEG".utf8).write(to: pair.image)
        let movie = try Data(contentsOf: pair.mov)
        try movie.prefix(movie.count / 2).write(to: pair.mov)
        let checks = await Verifier.verify(imageURL: pair.image, movURL: pair.mov)
        XCTAssertEqual(checks.first { $0.code == "image.decode" }?.status, .fail)
        XCTAssertEqual(checks.first { $0.code == "video.decode" }?.status, .fail)
    }

    func testRejectsTruncatedMediaTailEvenWithReadableMovieMetadata() async throws {
        let pair = try await fixture()
        let bytes = try Data(contentsOf: pair.mov)
        let atoms = try topLevelAtoms(bytes)
        let header = try XCTUnwrap(atoms.first { $0.type == "moov" })
        let media = try XCTUnwrap(atoms.first { $0.type == "mdat" })
        XCTAssertLessThan(header.start, media.start, "The fixture must retain its complete movie header.")
        let cut = media.start + media.headerSize + (media.size - media.headerSize) * 3 / 4
        try Data(bytes.prefix(cut)).write(to: pair.mov)
        let asset = AVURLAsset(url: pair.mov)
        let readableDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(readableDuration, 1, accuracy: 0.04)
        let checks = await Verifier.verify(imageURL: pair.image, movURL: pair.mov, expectedDuration: 1)
        XCTAssertEqual(checks.first { $0.code == "video.duration" }?.status, .pass)
        XCTAssertEqual(checks.first { $0.code == "video.decode" }?.status, .fail)
    }

    func testRejectsNonJPEGFileWithJPGExtension() async throws {
        let pair = try await fixture()
        try writeImage(pair.image, type: UTType.png.identifier)
        let checks = await Verifier.verify(imageURL: pair.image, movURL: pair.mov)
        XCTAssertEqual(checks.first { $0.code == "image.decode" }?.status, .fail)
    }

    func testRejectedSymlinkIsReportedWithoutFollowingIt() async throws {
        let pair = try await fixture()
        let alias = tmp.appendingPathComponent("alias.JPG")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: pair.image)
        let checks = await Verifier.verify(imageURL: alias, movURL: pair.mov)
        XCTAssertEqual(checks.first { $0.code == "image.file" }?.status, .fail)
    }

    func testJSONPreservesFailAndWarnStatuses() throws {
        let checks = [Check(status: .fail, label: "bad", detail: "failed"),
                      Check(status: .warn, label: "pending", detail: "not verified")]
        let decoded = try JSONDecoder().decode([Check].self, from: JSONEncoder().encode(checks))
        XCTAssertEqual(decoded.map(\.status), [.fail, .warn])
        XCTAssertFalse(decoded.allSatisfy { $0.status == .pass })
    }

    private func fixture(stillTime: Double? = 0.4, stillValue: Int = 0,
                         stillDataType: String = "com.apple.metadata.datatype.int8",
                         audio: Bool = false) async throws -> (image: URL, mov: URL) {
        let image = tmp.appendingPathComponent("IMG_TEST.JPG")
        let mov = tmp.appendingPathComponent("IMG_TEST.MOV")
        try writeImage(image)
        try await writeMovie(mov, stillTime: stillTime, stillValue: stillValue,
                             stillDataType: stillDataType, audio: audio)
        return (image, mov)
    }

    private func writeImage(_ url: URL, type: String = UTType.jpeg.identifier) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                  [kCGImagePropertyMakerAppleDictionary: ["17": identifier]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func writeMovie(_ url: URL, stillTime: Double?, stillValue: Int,
                            stillDataType: String, audio: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = true
        let assetID = AVMutableMetadataItem()
        assetID.keySpace = .quickTimeMetadata
        assetID.key = LivePhotoEngine.keyContentID as NSString
        assetID.value = identifier as NSString
        assetID.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [assetID]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                                 AVVideoWidthKey: 32, AVVideoHeightKey: 24])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
                     sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        writer.add(video)
        var description: CMFormatDescription?
        let specification: [CFString: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: "mdta/\(LivePhotoEngine.keyStillImageTime)",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: stillDataType]
        XCTAssertEqual(CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &description), noErr)
        let metadata = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadata)
        writer.add(metadata)
        let sound: AVAssetWriterInput? = audio ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1]) : nil
        if let sound { writer.add(sound) }
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "VerifierFixture", code: 2) }
        writer.startSession(atSourceTime: .zero)
        if let stillTime {
            try waitUntilReady(metadata, writer: writer)
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = LivePhotoEngine.keyStillImageTime as NSString
            item.value = NSNumber(value: stillValue)
            item.dataType = stillDataType
            XCTAssertTrue(adaptor.append(AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(
                start: CMTime(seconds: stillTime, preferredTimescale: 600), duration: CMTime(value: 1, timescale: 30)))))
        }
        metadata.markAsFinished()
        if let sound {
            try waitUntilReady(sound, writer: writer)
            XCTAssertTrue(sound.append(try silenceSample()))
            sound.markAsFinished()
        }
        for index in 0..<30 {
            try waitUntilReady(video, writer: writer)
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 32, 24, kCVPixelFormatType_32ARGB, nil, &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            memset(base, Int32(index * 4), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(pixels.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        video.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    private func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) throws {
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, Date() < deadline else {
                throw writer.error ?? NSError(domain: "VerifierFixture", code: 1)
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private func topLevelAtoms(_ bytes: Data) throws -> [(type: String, start: Int, size: Int, headerSize: Int)] {
        var atoms: [(String, Int, Int, Int)] = []
        var offset = 0
        while offset + 8 <= bytes.count {
            var size = bytes[offset..<(offset + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            var headerSize = 8
            if size == 1 {
                guard offset + 16 <= bytes.count else { throw NSError(domain: "VerifierFixture", code: 3) }
                size = bytes[(offset + 8)..<(offset + 16)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                headerSize = 16
            } else if size == 0 { size = UInt64(bytes.count - offset) }
            guard size >= UInt64(headerSize), size <= UInt64(bytes.count - offset),
                  let type = String(data: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) else {
                throw NSError(domain: "VerifierFixture", code: 3)
            }
            atoms.append((type, offset, Int(size), headerSize))
            offset += Int(size)
        }
        return atoms
    }

    private func silenceSample() throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: 88200, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: 88200, flags: 0, blockBufferOut: &block), kCMBlockBufferNoErr)
        let bytes = try XCTUnwrap(block)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: bytes, offsetIntoDestination: 0,
                                                 dataLength: 88200), kCMBlockBufferNoErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 2
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bytes,
            formatDescription: description, sampleCount: 44100, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}
