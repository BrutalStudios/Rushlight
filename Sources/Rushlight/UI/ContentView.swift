import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playlist: Playlist
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var lut: LUTLibrary
    @EnvironmentObject private var classifications: ClassificationStore
    @EnvironmentObject private var exporter: ExportManager

    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            detailPane
        }
        .navigationTitle(windowTitle)
        .toolbar { toolbarContent }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .sheet(
            isPresented: Binding(
                get: { exporter.config != nil },
                set: { if !$0 { exporter.cancelConfiguration() } }
            )
        ) {
            ExportSheet()
        }
        .alert(
            "LUT Error",
            isPresented: Binding(
                get: { lut.lastError != nil },
                set: { if !$0 { lut.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lut.lastError ?? "")
        }
        .alert(
            "Export Error",
            isPresented: Binding(
                get: { exporter.lastError != nil },
                set: { if !$0 { exporter.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exporter.lastError ?? "")
        }
    }

    private var windowTitle: String {
        guard let item = playlist.currentItem else { return "Rushlight" }
        if let index = playlist.currentIndex {
            return "\(item.name)  (\(index + 1)/\(playlist.items.count))"
        }
        return item.name
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                PlayerLayerView(player: player.player)
                if playlist.items.isEmpty {
                    dropHint
                }
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                        .padding(10)
                        .background(Color.accentColor.opacity(0.08))
                }
                if let notice = lutSkipNotice {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(notice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(.black.opacity(0.55)))
                                .padding(12)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ExportStatusStrip()
            TransportBar()
        }
        .background(Color.black)
    }

    /// Explains why the current clip plays ungraded, so an enabled LUT that
    /// "does nothing" is never a mystery.
    private var lutSkipNotice: String? {
        guard lut.isEnabled, let url = player.currentURL else { return nil }
        if classifications.override(for: url) == false {
            return "LUT off for this clip (manual)"
        }
        guard classifications.override(for: url) == nil, lut.autoDetectLog else { return nil }
        switch classifications.kind(for: url) {
        case .sdr: return "Normal video — LUT skipped"
        case .hdr: return "HDR video — LUT skipped"
        default: return nil
        }
    }

    private var dropHint: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop video files or a folder here")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("or press ⌘O to browse — Space plays, ↑/↓ switch clips, L toggles the LUT")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.showOpenPanel()
            } label: {
                Label("Open", systemImage: "folder.badge.plus")
            }
            .help("Add videos or folders (⌘O)")

            Button {
                model.exportCurrentClip()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(player.currentURL == nil || exporter.isExporting)
            .help("Export this clip with the LUT baked in (E)")

            lutMenu

            Toggle(isOn: $lut.isEnabled) {
                Text("LUT")
                    .font(.callout.weight(.semibold))
            }
            .toggleStyle(.button)
            .help("Toggle LUT (L)")

            Slider(value: $lut.intensity, in: 0...1) {
                Text("Intensity")
            }
            .frame(width: 110)
            .disabled(!lut.isEnabled)
            .help("LUT intensity: \(Int(lut.intensity * 100))%")
        }
    }

    private var lutMenu: some View {
        Menu {
            ForEach(lut.entries) { entry in
                Button {
                    lut.selectedID = entry.id
                } label: {
                    if entry.id == lut.selectedID {
                        Label(entry.name, systemImage: "checkmark")
                    } else {
                        Text(entry.name)
                    }
                }
            }

            Divider()

            Button("Import LUTs… (⌘⇧L)") {
                model.showImportLUTPanel()
            }

            Divider()

            Button {
                lut.autoDetectLog.toggle()
            } label: {
                if lut.autoDetectLog {
                    Label("Only Grade Log Footage (Auto-Detect)", systemImage: "checkmark")
                } else {
                    Text("Only Grade Log Footage (Auto-Detect)")
                }
            }

            Menu("LUT Input Color Space") {
                ForEach(LUTColorSpaceOption.allCases) { option in
                    Button {
                        lut.colorSpaceOption = option
                    } label: {
                        if option == lut.colorSpaceOption {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            }
        } label: {
            Label(lut.selectedEntry?.name ?? "LUT", systemImage: "camera.filters")
        }
        .help("Choose the LUT applied during playback")
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            AppModel.shared.open(urls: urls)
        }
        return !providers.isEmpty
    }
}
