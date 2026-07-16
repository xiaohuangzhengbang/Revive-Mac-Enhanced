import AVFoundation
import ImageIO
import Foundation

struct Check: Identifiable {
    enum Status { case pass, fail, warn }
    let id = UUID()
    let status: Status
    let label: String
    let detail: String
}

/// Reads the pairing metadata back from both output files and produces a checklist.
enum Verifier {
    static func imageAssetID(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let maker = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        else { return nil }
        return maker[LivePhotoEngine.makerAppleAssetIDKey] as? String
    }

    static func videoAssetID(_ url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        for item in metadata where (item.key as? String) == LivePhotoEngine.keyContentID {
            return item.stringValue
        }
        return nil
    }

    static func hasStillImageTimeTrack(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .metadata) else { return false }
        for track in tracks {
            guard let descs = try? await track.load(.formatDescriptions) else { continue }
            for desc in descs {
                let identifiers = CMMetadataFormatDescriptionGetIdentifiers(desc) as? [String] ?? []
                if identifiers.contains(where: { $0.contains(LivePhotoEngine.keyStillImageTime) }) {
                    return true
                }
            }
        }
        return false
    }

    static func verify(imageURL: URL, movURL: URL) async -> [Check] {
        let L = Localizer.shared
        var checks: [Check] = []
        let imgID = imageAssetID(imageURL)
        let vidID = await videoAssetID(movURL)
        let hasStill = await hasStillImageTimeTrack(movURL)

        checks.append(Check(
            status: imgID != nil ? .pass : .fail,
            label: L.t("v_img_id"),
            detail: imgID ?? L.t("v_img_id_miss")))
        checks.append(Check(
            status: vidID != nil ? .pass : .fail,
            label: L.t("v_vid_id"),
            detail: vidID ?? L.t("v_vid_id_miss")))
        checks.append(Check(
            status: (imgID != nil && imgID == vidID) ? .pass : .fail,
            label: L.t("v_match"),
            detail: (imgID != nil && imgID == vidID) ? L.t("v_match_ok")
                : L.t("v_match_fail", imgID ?? "—", vidID ?? "—")))
        checks.append(Check(
            status: hasStill ? .pass : .fail,
            label: L.t("v_still"),
            detail: hasStill ? L.t("v_still_ok") : L.t("v_still_miss")))
        checks.append(Check(
            status: imageURL.deletingPathExtension().lastPathComponent
                == movURL.deletingPathExtension().lastPathComponent ? .pass : .fail,
            label: L.t("v_names"),
            detail: "\(imageURL.lastPathComponent) / \(movURL.lastPathComponent)"))
        return checks
    }
}
