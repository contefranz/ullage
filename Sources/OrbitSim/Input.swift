import AppKit
import MetalKit
import OrbitInstruments

/// Keyboard and mouse state collected by `GameView`, consumed once per frame.
/// Keys are physical (`PhysicalKey`, from the event's key code), so every
/// binding sits in the same place on any layout; keys pressed with Shift go
/// to the MFDs only (`KeyboardState`).
@MainActor
final class InputState {
    private var keyboard = KeyboardState()
    var mouseDelta = CGPoint.zero
    var scrollDelta = 0.0

    /// Modifier keys held, with the side of Shift.
    var modifiers: ModifierKeys { keyboard.modifiers }

    func isHeld(_ key: PhysicalKey) -> Bool { keyboard.isHeld(key) }

    /// Keys pressed without Shift since the last frame (no auto-repeat).
    func takePressed() -> [PhysicalKey] { keyboard.takePressed() }

    /// Keys pressed with Shift since the last call, with the MFD each goes to.
    func takeMFDKeys() -> [(side: MFDSide, key: PhysicalKey)] { keyboard.takeMFDKeys() }

    func takeMouse() -> (dx: Double, dy: Double, scroll: Double) {
        defer { mouseDelta = .zero; scrollDelta = 0 }
        return (Double(mouseDelta.x), Double(mouseDelta.y), scrollDelta)
    }

    static func key(for event: NSEvent) -> PhysicalKey? { PhysicalKey(keyCode: event.keyCode) }

    static func modifiers(of event: NSEvent) -> ModifierKeys {
        ModifierKeys(eventFlags: event.modifierFlags.rawValue)
    }

    func keyDown(_ event: NSEvent) {
        guard let k = Self.key(for: event) else { return }
        keyboard.keyDown(k, modifiers: Self.modifiers(of: event), isRepeat: event.isARepeat)
    }

    func keyUp(_ event: NSEvent) {
        guard let k = Self.key(for: event) else { return }
        keyboard.keyUp(k)
    }

    func flagsChanged(_ event: NSEvent) {
        keyboard.modifiersChanged(Self.modifiers(of: event))
    }

    func releaseAll() { keyboard.releaseAll() }
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
        input?.flagsChanged(event)
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
