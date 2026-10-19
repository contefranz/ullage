import Foundation

/// A key by its place on the keyboard, whatever character the layout gives
/// it: the macOS virtual key code, named after the US (ANSI) layout. The
/// raw value is the key's unshifted US character, or its name.
public enum PhysicalKey: String, CaseIterable, Hashable, Sendable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    case digit1 = "1", digit2 = "2", digit3 = "3", digit4 = "4", digit5 = "5"
    case digit6 = "6", digit7 = "7", digit8 = "8", digit9 = "9", digit0 = "0"
    /// The key left of 1 on ANSI keyboards (`).
    case grave = "`"
    case minus = "-", equal = "=", leftBracket = "[", rightBracket = "]", backslash = "\\"
    case semicolon = ";", quote = "'", comma = ",", period = ".", slash = "/"
    /// The key left of 1 on ISO keyboards (§), where `grave` is the extra
    /// key beside left Shift.
    case isoSection = "section"
    case space, escape, tab
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case left, right, down, up

    /// The macOS virtual key code (Carbon's kVK_ANSI_* and kVK_* constants).
    public var keyCode: UInt16 {
        switch self {
        case .a: 0x00
        case .s: 0x01
        case .d: 0x02
        case .f: 0x03
        case .h: 0x04
        case .g: 0x05
        case .z: 0x06
        case .x: 0x07
        case .c: 0x08
        case .v: 0x09
        case .isoSection: 0x0A
        case .b: 0x0B
        case .q: 0x0C
        case .w: 0x0D
        case .e: 0x0E
        case .r: 0x0F
        case .y: 0x10
        case .t: 0x11
        case .digit1: 0x12
        case .digit2: 0x13
        case .digit3: 0x14
        case .digit4: 0x15
        case .digit6: 0x16
        case .digit5: 0x17
        case .equal: 0x18
        case .digit9: 0x19
        case .digit7: 0x1A
        case .minus: 0x1B
        case .digit8: 0x1C
        case .digit0: 0x1D
        case .rightBracket: 0x1E
        case .o: 0x1F
        case .u: 0x20
        case .leftBracket: 0x21
        case .i: 0x22
        case .p: 0x23
        case .l: 0x25
        case .j: 0x26
        case .quote: 0x27
        case .k: 0x28
        case .semicolon: 0x29
        case .backslash: 0x2A
        case .comma: 0x2B
        case .slash: 0x2C
        case .n: 0x2D
        case .m: 0x2E
        case .period: 0x2F
        case .tab: 0x30
        case .space: 0x31
        case .grave: 0x32
        case .escape: 0x35
        case .f5: 0x60
        case .f6: 0x61
        case .f7: 0x62
        case .f3: 0x63
        case .f8: 0x64
        case .f9: 0x65
        case .f11: 0x67
        case .f10: 0x6D
        case .f12: 0x6F
        case .f4: 0x76
        case .f2: 0x78
        case .f1: 0x7A
        case .left: 0x7B
        case .right: 0x7C
        case .down: 0x7D
        case .up: 0x7E
        }
    }

    /// The key with macOS virtual key code `keyCode`; nil for keys that are
    /// not named (Return, Delete, the keypad, the modifiers...).
    public init?(keyCode: UInt16) {
        guard let key = Self.byKeyCode[keyCode] else { return nil }
        self = key
    }

    private static let byKeyCode = Dictionary(uniqueKeysWithValues: allCases.map { ($0.keyCode, $0) })

    /// The digit of a number-row key; nil for any other key.
    public var digit: Int? {
        switch self {
        case .digit0: 0
        case .digit1: 1
        case .digit2: 2
        case .digit3: 3
        case .digit4: 4
        case .digit5: 5
        case .digit6: 6
        case .digit7: 7
        case .digit8: 8
        case .digit9: 9
        default: nil
        }
    }
}
