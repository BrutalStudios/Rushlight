import SwiftUI

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Videos or Folder…") {
                model.showOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Import LUTs…") {
                model.showImportLUTPanel()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            Button("Export Clip with LUT…") {
                model.exportCurrentClip()
            }
            .keyboardShortcut("e", modifiers: .command)

            Button("Export All Clips with LUT…") {
                model.exportAllClips()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Button("Save Current Frame…") {
                model.saveCurrentFrame()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])

            Divider()

            Button("Clear Playlist") {
                model.playlist.removeAll()
            }
        }

        CommandMenu("Playback") {
            Button("Play / Pause") {
                model.player.togglePlayPause()
            }
            .keyboardShortcut("p", modifiers: .command)

            Divider()

            Button("Next Clip") {
                model.player.next()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)

            Button("Previous Clip") {
                model.player.previous()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)

            Divider()

            Button("Toggle LUT") {
                model.lutLibrary.toggleEnabled()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}
