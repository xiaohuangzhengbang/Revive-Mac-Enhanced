import SwiftUI

/// A film-strip style scrubber: the full clip as a track, a draggable brand-
/// tinted band for the [start, end] selection, and a round key-photo handle
/// inside it. This is the "focused editor" centrepiece.
struct TimelineTrimmer: View {
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    @Binding var frameTime: Double     // relative to trimStart
    var thumbnails: [NSImage] = []
    var onScrub: (Double) -> Void      // absolute time to preview

    private let handleW: CGFloat = 12
    private let trackH: CGFloat = 56

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(t / duration) * w
    }
    private func t(_ x: CGFloat, _ w: CGFloat) -> Double {
        guard w > 0 else { return 0 }
        return max(0, min(duration, Double(x / w) * duration))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let startX = x(trimStart, w)
            let endX = x(trimEnd, w)
            let keyX = x(trimStart + frameTime, w)

            ZStack(alignment: .leading) {
                // filmstrip base
                HStack(spacing: 0) {
                    if thumbnails.isEmpty {
                        Rectangle().fill(Color.secondary.opacity(0.12))
                    } else {
                        ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, img in
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity).clipped()
                        }
                    }
                }
                .frame(height: trackH)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // dim the trimmed-away regions
                Rectangle().fill(.black.opacity(0.5))
                    .frame(width: max(0, startX), height: trackH)
                Rectangle().fill(.black.opacity(0.5))
                    .frame(width: max(0, w - endX), height: trackH)
                    .offset(x: endX)

                // selection band outline
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.brand, lineWidth: 3)
                    .frame(width: max(0, endX - startX), height: trackH)
                    .offset(x: startX)

                // key-photo marker
                keyHandle
                    .position(x: min(max(keyX, 8), w - 8), y: trackH / 2)
                    .gesture(DragGesture().onChanged { g in
                        let abs = t(g.location.x, w)
                        frameTime = min(max(0, abs - trimStart), trimEnd - trimStart)
                        onScrub(trimStart + frameTime)
                    })

                edgeHandle(leading: true)
                    .position(x: startX + handleW / 2 - 1, y: trackH / 2)
                    .gesture(DragGesture().onChanged { g in
                        trimStart = min(t(g.location.x, w), trimEnd - 0.3)
                        frameTime = min(max(0, frameTime), trimEnd - trimStart)
                        onScrub(trimStart)
                    })
                edgeHandle(leading: false)
                    .position(x: endX - handleW / 2 + 1, y: trackH / 2)
                    .gesture(DragGesture().onChanged { g in
                        trimEnd = max(t(g.location.x, w), trimStart + 0.3)
                        frameTime = min(max(0, frameTime), trimEnd - trimStart)
                        onScrub(trimEnd)
                    })
            }
            .frame(height: trackH)
        }
        .frame(height: trackH)
    }

    private func edgeHandle(leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.brand)
            .frame(width: handleW, height: trackH + 6)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white.opacity(0.9))
                    .frame(width: 2, height: trackH * 0.34)
            )
    }

    private var keyHandle: some View {
        Circle()
            .fill(.white)
            .frame(width: 26, height: 26)
            .overlay(Circle().strokeBorder(Color.brand, lineWidth: 3))
            .overlay(Image(systemName: "photo").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.brand))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}
