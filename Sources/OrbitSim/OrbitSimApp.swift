import SwiftUI
import AppKit
import OrbitScene

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running the SwiftPM executable directly (no app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Activation is cooperative from macOS 14: launched from Xcode or a
        // terminal, the app may not be allowed to come forward, so bring the
        // window up regardless.
        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            NSApp.windows.first?.orderFrontRegardless()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct OrbitSimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // A single window: a second one would add a second renderer ticking the same simulation.
        Window("OrbitSim", id: "main") {
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
