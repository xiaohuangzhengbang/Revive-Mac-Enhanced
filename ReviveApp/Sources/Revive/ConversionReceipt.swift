import Foundation

struct ConversionReceipt: Encodable {
    let schemaVersion = 1
    let application = "Revive Mac Enhanced"
    let sourcePath: String
    let sourceSHA256Before: String
    let settings: PreviewSettings
    let assetIdentifier: String
    let actualStillTime: Double
    let actualDuration: Double
    let videoWasCopied: Bool
    let expectedAudio: Bool
    let coverHumanConfirmed = true
    let createdAt = Date()
    let automaticEyeDetection = false
    let previewedPairReused = true
    let applePhotosLivePlaybackVerified = false
    var status = "IN_PROGRESS"
    var sourceSHA256After: String?
    var inputUnchanged = false
    var imageSHA256: String?
    var movieSHA256: String?
    var checks: [Check] = []
    var error: String?

    init(source: URL, sourceSHA256: String, settings: PreviewSettings, result: ConversionResult, expectedAudio: Bool) {
        sourcePath = source.path
        sourceSHA256Before = sourceSHA256
        self.settings = settings
        assetIdentifier = result.assetID
        actualStillTime = result.stillTime
        actualDuration = result.clipDuration
        videoWasCopied = result.videoWasCopied
        self.expectedAudio = expectedAudio
    }

    mutating func complete(sourceSHA256After: String, checks: [Check], imageSHA256: String, movieSHA256: String) {
        self.sourceSHA256After = sourceSHA256After
        inputUnchanged = sourceSHA256Before == sourceSHA256After
        self.checks = checks
        self.imageSHA256 = imageSHA256
        self.movieSHA256 = movieSHA256
        status = inputUnchanged && !checks.isEmpty && checks.allSatisfy { $0.status == .pass } ? "FILES_VERIFIED" : "FAILED"
    }

    mutating func fail(_ message: String) {
        status = "FAILED"
        error = message
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
