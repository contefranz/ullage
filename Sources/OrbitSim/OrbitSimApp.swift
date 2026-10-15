import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running the SwiftPM executable directly (no app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct OrbitSimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("OrbitSim") {
            ContentView(model: model)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandMenu("Scenario") {
                ForEach(Scenario.all) { s in
                    Button(s.name) { model.load(s) }
                }
            }
        }
    }
}
