import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var playlist: Playlist
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var classifications: ClassificationStore
    @EnvironmentObject private var exporter: ExportManager

    var body: some View {
        VStack(spacing: 0) {
            if playlist.items.isEmpty {
                emptyState
            } else {
                clipList
            }
            Divider()
            footer
        }
        .navigationSplitViewColumnWidth(min: 250, ideal: 320)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No clips yet")
                .foregroundStyle(.secondary)
            Text("Press ⌘O or drop files here")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var clipList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(playlist.items.enumerated()), id: \.element.id) { index, item in
                    ClipRow(
                        item: item,
                        meta: playlist.meta[item.url],
                        position: index + 1,
                        isCurrent: playlist.currentIndex == index,
                        isPlaying: player.isPlaying && playlist.currentIndex == index,
                        kind: classifications.kind(for: item.url),
                        lutOverride: classifications.override(for: item.url)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        player.play(at: index)
                    }
                    .contextMenu {
                        Button("Play") { player.play(at: index) }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        }
                        Menu("Apply LUT") {
                            overrideButton("Automatic (detect log)", value: nil, url: item.url)
                            overrideButton("Always", value: true, url: item.url)
                            overrideButton("Never", value: false, url: item.url)
                        }
                        Button("Export with LUT…") {
                            exporter.beginConfiguration(urls: [item.url])
                        }
                        .disabled(exporter.isExporting)
                        Divider()
                        Button("Remove from Playlist", role: .destructive) {
                            playlist.remove(at: IndexSet(integer: index))
                        }
                    }
                    .id(item.url)
                }
            }
            .listStyle(.sidebar)
            .onChange(of: playlist.currentIndex) { _, newIndex in
                guard let newIndex, playlist.items.indices.contains(newIndex) else { return }
                withAnimation {
                    proxy.scrollTo(playlist.items[newIndex].url, anchor: .center)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Menu {
                Picker("Sort By", selection: $playlist.sortOrder) {
                    ForEach(PlaylistSortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort playlist")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footerText: String {
        guard !playlist.items.isEmpty else { return "Rushlight" }
        let count = playlist.items.count
        let size = Format.fileSize(playlist.totalSizeBytes)
        return "\(count) clip\(count == 1 ? "" : "s") · \(size)"
    }

    @ViewBuilder
    private func overrideButton(_ title: String, value: Bool?, url: URL) -> some View {
        Button {
            classifications.setOverride(value, for: url)
        } label: {
            if classifications.override(for: url) == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

private struct ClipRow: View {
    let item: VideoItem
    let meta: VideoMeta?
    let position: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let kind: ContentKind?
    let lutOverride: Bool?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if isPlaying {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                } else if isCurrent {
                    Image(systemName: "pause.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("\(position)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 26, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    if let badge = kind?.badge {
                        Text(badge)
                            .font(.system(size: 8.5, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(
                                    kind == .log
                                        ? Color.orange.opacity(0.25)
                                        : Color.purple.opacity(0.25)
                                )
                            )
                            .foregroundStyle(kind == .log ? Color.orange : Color.purple)
                    }
                    if let lutOverride {
                        Image(systemName: "camera.filters")
                            .font(.system(size: 9))
                            .foregroundStyle(lutOverride ? Color.orange : Color.secondary)
                            .opacity(lutOverride ? 1 : 0.5)
                            .overlay {
                                if !lutOverride {
                                    Image(systemName: "line.diagonal")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.secondary)
                                }
                            }
                            .help(lutOverride ? "LUT forced on" : "LUT forced off")
                    }
                    Text(Format.clipDetails(meta, sizeBytes: item.sizeBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .listRowBackground(
            isCurrent
                ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.14))
                : nil
        )
    }
}
