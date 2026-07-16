import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// App signature colour — metallic steel blue. Change this one value to
    /// re-skin every accented control (selection band, handles, toggles).
    static let brand = Color(hex: 0x5E8FB8)
    static let brandSoft = Color(hex: 0x5E8FB8).opacity(0.16)

    // primary-button metallic sheen (light top → dark bottom)
    static let brandMetalTop = Color(hex: 0x7BA6C9)
    static let brandMetalBottom = Color(hex: 0x4A78A2)
}

/// Brushed-metal primary button: a top-light/bottom-dark gradient with a
/// bright top edge, so the main call-to-action reads like a polished metal key.
struct MetallicButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MetallicButtonBody(configuration: configuration)
    }

    struct MetallicButtonBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(
                            colors: [.brandMetalTop, .brandMetalBottom],
                            startPoint: .top, endPoint: .bottom))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(LinearGradient(
                            colors: [.white.opacity(0.55), .white.opacity(0.04)],
                            startPoint: .top, endPoint: .bottom), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .brightness(configuration.isPressed ? -0.05 : 0)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}
