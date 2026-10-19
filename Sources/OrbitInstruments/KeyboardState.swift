import Foundation

/// The multi-function display a key pressed with Shift goes to: left Shift
/// drives the left one and right Shift the right one, as in Orbiter.
public enum MFDSide: Hashable, Sendable {
    case left, right
}

/// Modifier keys held, with the side of Shift.
public struct ModifierKeys: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let leftShift = ModifierKeys(rawValue: 1 << 0)
    public static let rightShift = ModifierKeys(rawValue: 1 << 1)
    public static let control = ModifierKeys(rawValue: 1 << 2)
    public static let option = ModifierKeys(rawValue: 1 << 3)
    public static let command = ModifierKeys(rawValue: 1 << 4)

    /// From a macOS event's modifier flags (`NSEvent.modifierFlags.rawValue`):
    /// Control, Option and Command from their device-independent bits, and
    /// the side of Shift from the device-dependent bits 0x2 (left) and 0x4
    /// (right). A keyboard that reports Shift without its side counts as left
    /// Shift. Caps Lock is not Shift.
    public init(eventFlags flags: UInt) {
        var m: ModifierKeys = []
        if flags & 0x2 != 0 { m.insert(.leftShift) }
        if flags & 0x4 != 0 { m.insert(.rightShift) }
        if flags & (1 << 17) != 0, m.isDisjoint(with: [.leftShift, .rightShift]) { m.insert(.leftShift) }
        if flags & (1 << 18) != 0 { m.insert(.control) }
        if flags & (1 << 19) != 0 { m.insert(.option) }
        if flags & (1 << 20) != 0 { m.insert(.command) }
        self = m
    }

    /// The MFD a key pressed with these modifiers goes to: nil without
    /// Shift, the left one with both.
    public var mfdSide: MFDSide? {
        contains(.leftShift) ? .left : contains(.rightShift) ? .right : nil
    }
}

/// The keyboard as the flight controls and the MFDs see it, by physical key.
/// A key pressed without Shift is held until it goes up (so its key-up
/// always matches its key-down) and queued for `takePressed`. A key pressed
/// with Shift goes only to the MFD of that side (`takeMFDKeys`): it is never
/// held and never reaches the flight controls, so releasing Shift first
/// leaves nothing held. Auto-repeats reach no queue.
public struct KeyboardState {
    /// Keys held, pressed without Shift.
    public private(set) var held = Set<PhysicalKey>()
    /// The modifiers at the last key or modifier event.
    public private(set) var modifiers: ModifierKeys = []
    private var pressed: [PhysicalKey] = []
    private var mfdKeys: [(side: MFDSide, key: PhysicalKey)] = []
    /// Longest MFD queue kept: while nothing takes the keys, the oldest go.
    public static let mfdQueueLimit = 32

    public init() {}

    public func isHeld(_ key: PhysicalKey) -> Bool { held.contains(key) }

    public mutating func keyDown(_ key: PhysicalKey, modifiers: ModifierKeys, isRepeat: Bool) {
        self.modifiers = modifiers
        if let side = modifiers.mfdSide {
            guard !isRepeat else { return }
            mfdKeys.append((side, key))
            if mfdKeys.count > Self.mfdQueueLimit { mfdKeys.removeFirst(mfdKeys.count - Self.mfdQueueLimit) }
            return
        }
        if !isRepeat { pressed.append(key) }
        held.insert(key)
    }

    public mutating func keyUp(_ key: PhysicalKey) {
        held.remove(key)
    }

    public mutating func modifiersChanged(_ modifiers: ModifierKeys) {
        self.modifiers = modifiers
    }

    /// Keys pressed without Shift since the last call, in order.
    public mutating func takePressed() -> [PhysicalKey] {
        defer { pressed.removeAll() }
        return pressed
    }

    /// Keys pressed with Shift since the last call, in order, with the MFD
    /// each goes to.
    public mutating func takeMFDKeys() -> [(side: MFDSide, key: PhysicalKey)] {
        defer { mfdKeys.removeAll() }
        return mfdKeys
    }

    /// Forget the held keys and modifiers, whose releases may never arrive
    /// (the window lost focus, or Cmd was down).
    public mutating func releaseAll() {
        held.removeAll()
        modifiers = []
    }
}
