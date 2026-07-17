import SwiftUI
import AVKit

/// Wraps AppKit's AVPlayerView instead of SwiftUI's `VideoPlayer`. On macOS,
/// SwiftUI's `VideoPlayer` crashes on realization in some system versions
/// (a class-metadata fault in _AVKit_SwiftUI); the AppKit view is rock-solid.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

@MainActor
final class PlayerModel: ObservableObject {
    let player: AVPlayer
    private var endObserver: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.isMuted = false
    }

    func seek(to seconds: Double) {
        player.pause()
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Play only the selected clip range once.
    func playClip(from start: Double, to end: Double) {
        if let endObserver { player.removeTimeObserver(endObserver); self.endObserver = nil }
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            self.player.play()
            let boundary = NSValue(time: CMTime(seconds: end, preferredTimescale: 600))
            self.endObserver = self.player.addBoundaryTimeObserver(
                forTimes: [boundary], queue: .main
            ) { [weak self] in
                self?.player.pause()
            }
        }
    }
}

struct EditorView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var loc: Localizer
    @ObservedObject var item: QueueItem
    @StateObject private var playerModel: PlayerModel
    @State private var showChecklistDetail = false
    @State private var sealPop = false

    init(item: QueueItem) {
        self.item = item
        _playerModel = StateObject(wrappedValue: PlayerModel(url: item.url))
    }

    private var isBusy: Bool {
        if case .converting = item.state { return true }
        return model.isBatchRunning
    }

    var body: some View {
        VStack(spacing: 0) {
            previewArea
            controls
                .padding(16)
                .background(.regularMaterial)
        }
        .navigationTitle(item.url.lastPathComponent)
        .onChange(of: item.state) { _, newState in
            // the moment it becomes a Live Photo, let it come alive once
            if case .done = newState {
                playerModel.playClip(from: item.trimStart, to: item.trimEnd)
            }
        }
    }

    private var previewArea: some View {
        PlayerView(player: playerModel.player)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.08)))
            .overlay(alignment: .topLeading) { liveBadge.padding(14) }
            .overlay(alignment: .bottomTrailing) { coverChip.padding(14) }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "livephoto")
            Text("LIVE").font(.caption2.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.black.opacity(0.42), in: Capsule())
    }

    @ViewBuilder private var coverChip: some View {
        if let img = coverThumbnail {
            VStack(spacing: 3) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 76, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.85), lineWidth: 2))
                Text(loc.t("cover_photo")).font(.caption2).foregroundStyle(.white)
            }
            .padding(6)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Nearest film-strip frame to the chosen key photo — a live cover preview.
    private var coverThumbnail: NSImage? {
        guard !item.filmstrip.isEmpty, item.duration > 0 else { return nil }
        let keyAbs = item.trimStart + item.frameTime
        let idx = min(max(0, Int(keyAbs / item.duration * Double(item.filmstrip.count))),
                      item.filmstrip.count - 1)
        return item.filmstrip[idx]
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCard(title: loc.t("card_trim"), systemImage: "scissors") {
                TimelineTrimmer(
                    duration: item.duration,
                    trimStart: $item.trimStart,
                    trimEnd: $item.trimEnd,
                    frameTime: $item.frameTime,
                    thumbnails: item.filmstrip,
                    onScrub: { playerModel.seek(to: $0) }
                )
                HStack(spacing: 10) {
                    Button { playerModel.playClip(from: item.trimStart, to: item.trimEnd) } label: {
                        Label(loc.t("play_clip"), systemImage: "play.fill")
                    }
                    Button(loc.t("whole")) {
                        item.trimStart = 0; item.trimEnd = item.duration; clampFrameTime()
                    }
                    Button(loc.t("middle3")) {
                        item.trimStart = max(0, (item.duration - 3) / 2)
                        item.trimEnd = min(item.trimStart + 3, item.duration)
                        item.frameTime = item.clipDuration / 2
                        playerModel.seek(to: item.trimStart + item.frameTime)
                    }
                    Spacer()
                    Label {
                        Text(loc.t("seconds", String(format: "%.1f", item.clipDuration))).monospacedDigit()
                    } icon: {
                        Image(systemName: item.clipDuration > 3.05 ? "exclamationmark.triangle.fill" : "timer")
                    }
                    .font(.callout)
                    .foregroundStyle(item.clipDuration > 3.05 ? .orange : .secondary)
                }
            }

            SectionCard(title: loc.t("card_options"), systemImage: "slider.horizontal.3") {
                HStack(spacing: 18) {
                    Toggle(loc.t("opt_heic"), isOn: $item.useHEIC)
                    Toggle(loc.t("opt_exact"), isOn: $item.exactTrim)
                    Toggle(loc.t("opt_mute"), isOn: $item.dropAudio)
                    Spacer()
                }
                .toggleStyle(.checkbox)
                .font(.callout)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await model.convertAndDeliver(item, to: .photoLibrary) }
                } label: {
                    if case .converting(let message) = item.state {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text(message)
                        }
                    } else {
                        Label(loc.t("convert_add_photos"), systemImage: "livephoto")
                    }
                }
                .buttonStyle(MetallicButtonStyle())
                .disabled(isBusy)

                Menu {
                    Button(loc.t("convert_export")) {
                        Task { await model.convertAndDeliver(item, to: .folder) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 40)
                .controlSize(.large)
                .disabled(isBusy)
            }

            if let result = item.result, !result.videoWasCopied, !item.exactTrim {
                Label(loc.t("reencode_note"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !item.checks.isEmpty {
                checklist
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: item.checks.count)
    }

    private var allChecksPass: Bool { item.checks.allSatisfy { $0.status == .pass } }

    @ViewBuilder private var checklist: some View {
        if allChecksPass {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(.white, .green)
                    .scaleEffect(sealPop ? 1 : 0.5)
                    .opacity(sealPop ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(loc.t("verified")).font(.callout.weight(.medium))
                    if item.savedToLibrary {
                        Text(loc.t("saved_icloud"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if item.savedToLibrary {
                    Button {
                        NSWorkspace.shared.open(URL(string: "photos://")!)
                    } label: {
                        Label(loc.t("show_in_photos"), systemImage: "photo.on.rectangle")
                    }
                    .controlSize(.small)
                }
                Button(loc.t(showChecklistDetail ? "hide_details" : "details")) {
                    showChecklistDetail.toggle()
                }
                .buttonStyle(.link).font(.caption)
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(.green.opacity(0.12)))
            .onAppear {
                sealPop = false
                withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { sealPop = true }
            }
            if showChecklistDetail { checkRows }
        } else {
            // 失敗時一律展開,直接指出缺哪個欄位
            checkRows
        }
    }

    private var checkRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(item.checks) { check in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: check.status == .pass ? "checkmark.circle.fill"
                          : check.status == .warn ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                        .foregroundStyle(check.status == .pass ? .green
                                         : check.status == .warn ? .orange : .red)
                        .font(.caption)
                    Text(check.label).font(.caption)
                    Text(check.detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private func clampFrameTime() {
        item.frameTime = min(max(0, item.frameTime), item.clipDuration)
    }
}
