import SwiftUI
import AVKit
import UniformTypeIdentifiers

func timeString(_ s: Double) -> String {
    String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var loc: Localizer

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let item = model.selection {
                EditorView(item: item)
                    .id(item.id)
            } else {
                dropHint
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .tint(.brand)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.openPanel()
                } label: {
                    Label(loc.t("add_video"), systemImage: "plus")
                }
                Menu {
                    ForEach(Destination.allCases) { dest in
                        Button(loc.t(dest == .photoLibrary ? "dest_photos" : "dest_folder")) {
                            Task { await model.convertAll(to: dest) }
                        }
                    }
                } label: {
                    Label(loc.t("convert_all"), systemImage: "square.stack.3d.forward.dottedline")
                }
                .disabled(model.items.isEmpty || model.isBatchRunning || model.activeOperations > 0 || model.isClosing)

                Menu {
                    Picker(loc.t("language"), selection: $loc.lang) {
                        ForEach(Lang.allCases) { l in
                            Text(l.displayName).tag(l)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(loc.t("language"), systemImage: "globe")
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                VStack(alignment: .leading, spacing: 0) {
                    ReviveWordmark(size: 32, color: .brand)
                    Text(model.items.isEmpty ? loc.t("sidebar_empty")
                         : loc.t("videos_count", model.items.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            Divider()

            List(selection: $model.selectionID) {
                ForEach(model.items) { item in
                    QueueRow(item: item)
                        .tag(item.id)
                        .contextMenu {
                            Button(loc.t("remove")) { model.remove(item) }
                        }
                }
            }
            .listStyle(.sidebar)

            if let message = model.lastMessage {
                Divider()
                Label(message, systemImage: model.lastMessageIsError ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(model.lastMessageIsError ? Color.red : Color.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var dropHint: some View {
        VStack(spacing: 14) {
            ReviveWordmark(size: 86, color: .brand)
            Text(loc.t("hero_tagline"))
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(loc.t("hero_hint"))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Button {
                model.openPanel()
            } label: {
                Label(loc.t("choose_video"), systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .tint(.brand)
            .controlSize(.large)
            .keyboardShortcut("o")
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    Task { @MainActor in model.add(urls: [url]) }
                }
            }
        }
        return true
    }
}

struct QueueRow: View {
    @ObservedObject var item: QueueItem
    @EnvironmentObject var loc: Localizer

    var body: some View {
        HStack(spacing: 11) {
            Group {
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: 62, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.08)))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    stateIcon
                    Text(stateText)
                        .font(.caption)
                        .foregroundStyle(stateColor)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var stateText: String {
        switch item.state {
        case .loading: return loc.t("state_loading")
        case .ready: return loc.t("state_ready", timeString(item.duration),
                                  String(format: "%.1f", item.clipDuration))
        case .converting(let message): return message
        case .done: return loc.t(item.savedToLibrary ? "state_done_saved" : "state_done")
        case .failed(let reason): return reason
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .failed: return .red
        case .done: return .green
        default: return .secondary
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch item.state {
        case .converting: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
        case .ready: Image(systemName: "livephoto").font(.caption).foregroundStyle(Color.brand)
        default: EmptyView()
        }
    }
}
