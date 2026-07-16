import SwiftUI

/// A titled, softly-raised section card — the building block that gives the
/// control panel visual hierarchy instead of one flat slab.
struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.06))
        )
    }
}

/// The Revive wordmark — the Great Vibes script (SIL Open Font License). This
/// IS the brand logo: a plain-text wordmark in an OFL font bundled with the app,
/// so it's free of any system-iconography resemblance AND of commercial-font
/// licensing risk (safe for commercial/portfolio use). The font is registered
/// at launch (see ReviveApp.registerBundledFonts / ATSApplicationFontsPath).
struct ReviveWordmark: View {
    var size: CGFloat = 40
    var color: Color = .primary
    var body: some View {
        Text("Revive")
            .font(.custom("GreatVibes-Regular", size: size))
            .foregroundStyle(color)
            .fixedSize()
    }
}
