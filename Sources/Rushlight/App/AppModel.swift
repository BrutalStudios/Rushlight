import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let playlist: Playlist
    let lutLibrary: LUTLibrary
    let player: PlayerController
    let classifications: ClassificationStore
    let exporter: ExportManager

    private var cancellables = Set<AnyCancellable>()

    private init() {
        playlist = Playlist()
        classifications = ClassificationStore()
        lutLibrary = LUTLibrary()
        player = PlayerController(playlist: playlist, classifications: classifications)
        exporter = ExportManager(classifications: classifications)
        KeyboardShortcuts.install()

        // Classify clips in the background as they enter the playlist so the
        // sidebar badges and LUT skipping are ready before they're played.
        playlist.$items
            .sink { [weak self] items in
                self?.classifications.classifyMissing(items.map(\.url))
            }
            .store(in: &cancellables)
    }

    /// Adds files/folders to the playlist; starts playing the first new clip
    /// if nothing is playing yet.
    func open(urls: [URL]) {
        let firstNewIndex = playlist.add(urls: urls)
        if player.currentURL == nil, let index = firstNewIndex ?? (playlist.items.isEmpty ? nil : 0) {
            player.play(at: index)
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose video files or folders — folders are scanned for clips"
        panel.prompt = "Add to Rushlight"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in self?.open(urls: urls) }
        }
    }

    func exportCurrentClip() {
        guard let url = player.currentURL else { return }
        exporter.beginConfiguration(urls: [url])
    }

    func exportAllClips() {
        exporter.beginConfiguration(urls: playlist.items.map(\.url))
    }

    func saveCurrentFrame() {
        guard let url = player.currentURL else { return }
        player.player.pause()
        exporter.saveFrame(of: url, at: player.currentTime)
    }

    func showImportLUTPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if let cubeType = UTType(filenameExtension: "cube") {
            panel.allowedContentTypes = [cubeType]
        }
        panel.message = "Choose .cube LUT files to import"
        panel.prompt = "Import LUTs"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in self?.lutLibrary.importLUTs(from: urls) }
        }
    }
}
