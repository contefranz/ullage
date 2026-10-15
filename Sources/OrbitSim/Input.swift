import AppKit
import MetalKit

/// Keyboard and mouse state collected by `GameView`, consumed once per frame.
@MainActor
final class InputState {
    /// Keys currently held (lower-cased characters, plus "space").
    private(set) var held = Set<String>()
    /// Keys pressed since the last frame (no auto-repeat).
    private var pressedQueue: [String] = []
    var mouseDelta = CGPoint.zero
    var scrollDelta = 0.0

    func isHeld(_ key: String) -> Bool { held.contains(key) }

    func takePressed() -> [String] {
        defer { pressedQueue.removeAll() }
        return pressedQueue
    }

    func takeMouse() -> (dx: Double, dy: Double, scroll: Double) {
        defer { mouseDelta = .zero; scrollDelta = 0 }
        return (Double(mouseDelta.x), Double(mouseDelta.y), scrollDelta)
    }

    static func key(for event: NSEvent) -> String? {
        if event.keyCode == 49 { return "space" }
        if event.keyCode == 53 { return "escape" }
        guard let c = event.charactersIgnoringModifiers?.lowercased(), !c.isEmpty else { return nil }
        return c
    }

    func keyDown(_ event: NSEvent) {
        guard let k = Self.key(for: event) else { return }
        if !event.isARepeat { pressedQueue.append(k) }
        held.insert(k)
    }

    func keyUp(_ event: NSEvent) {
        guard let k = Self.key(for: event) else { return }
        held.remove(k)
    }

    func releaseAll() { held.removeAll() }
}

/// MTKView that forwards keyboard and mouse input.
final class GameView: MTKView {
    var input: InputState?

    override var acceptsFirstResponder: Bool { true }

    private var resignObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        // SwiftUI may claim first responder during its first layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let window {
            // Key-up events are lost when the window loses focus (Cmd-Tab), so drop held keys.
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.input?.releaseAll() }
                }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // AppKit does not deliver key-up for keys released while Cmd is down.
        if event.modifierFlags.contains(.command) { input?.releaseAll() }
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Let Cmd-shortcuts (quit, close...) reach the menu.
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        input?.keyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        input?.keyUp(event)
    }

    override func resignFirstResponder() -> Bool {
        input?.releaseAll()
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        input?.mouseDelta.x += event.deltaX
        input?.mouseDelta.y += event.deltaY
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseDragged(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let scale = event.hasPreciseScrollingDeltas ? 0.15 : 1.0
        input?.scrollDelta += Double(event.scrollingDeltaY) * scale
    }
}
