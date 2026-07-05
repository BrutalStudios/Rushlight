import AppKit

/// Global single-key shortcuts, installed once. They are swallowed before
/// reaching other responders so review flow stays on the keyboard:
///
///   Space        play / pause
///   ← / →        seek 5s back / forward (⇧ for 1s)
///   ↑ / ↓        previous / next clip
///   , / .        step one frame back / forward (while paused)
///   L            toggle LUT on/off (instant A/B compare)
///   F            toggle fullscreen
///   E            export current clip with LUT
///   S            save current frame as PNG
///   [ / ]        playback speed down / up
@MainActor
enum KeyboardShortcuts {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                handle(event) ? nil : event
            }
        }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        // Leave text editing and menu-command chords alone.
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
            return false
        }
        if !event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            return false
        }

        let model = AppModel.shared
        let player = model.player
        let shift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 49: // space
            player.togglePlayPause()
            return true
        case 123: // left arrow
            player.seek(by: shift ? -1 : -5)
            return true
        case 124: // right arrow
            player.seek(by: shift ? 1 : 5)
            return true
        case 126: // up arrow
            player.previous()
            return true
        case 125: // down arrow
            player.next()
            return true
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "l":
            model.lutLibrary.toggleEnabled()
            return true
        case "f":
            player.toggleFullscreen()
            return true
        case "e":
            model.exportCurrentClip()
            return true
        case "s":
            model.saveCurrentFrame()
            return true
        case ",":
            player.stepFrames(-1)
            return true
        case ".":
            player.stepFrames(1)
            return true
        case "[":
            player.cycleSpeed(forward: false)
            return true
        case "]":
            player.cycleSpeed(forward: true)
            return true
        default:
            return false
        }
    }
}
