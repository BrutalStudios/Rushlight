import AppKit
import SwiftUI

@main
struct RushlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.playlist)
                .environmentObject(model.lutLibrary)
                .environmentObject(model.player)
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 540)
        }
        .defaultSize(width: 1360, height: 820)
        .commands {
            AppCommands(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keeps the app frontmost and menu-equipped even when launched as a
        // bare binary via `swift run` during development.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AppModel.shared.open(urls: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
