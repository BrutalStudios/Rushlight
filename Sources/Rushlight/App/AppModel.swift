import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let playlist: Playlist
    let lutLibrary: LUTLibrary
    let player: PlayerController

    private init() {
        playlist = Playlist()
        lutLibrary = LUTLibrary()
        player = PlayerController(playlist: playlist)
        KeyboardShortcuts.install()
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
