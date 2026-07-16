import Photos
import Foundation

enum PhotoLibraryError: LocalizedError {
    case notAuthorized
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return Localizer.shared.t("err_photos_auth")
        case .saveFailed(let d):
            return "\(Localizer.shared.t("err_save_failed")): \(d)"
        }
    }
}

/// Adds the pair to the Photos library via PHAssetCreationRequest
/// (photo + pairedVideo) — the same API intoLive uses. Photos validates the
/// pairing at insert time, so success here GUARANTEES a real Live Photo.
/// With iCloud Photos on, it syncs to the iPad automatically.
enum PhotoLibrarySaver {
    static func save(imageURL: URL, movURL: URL) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.notAuthorized
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: imageURL, options: nil)
                request.addResource(with: .pairedVideo, fileURL: movURL, options: nil)
            }
        } catch {
            throw PhotoLibraryError.saveFailed(error.localizedDescription)
        }
    }
}
