import Foundation
import OrbitCore

/// CMC: the onboard computer's DSKY on an MFD (docs/m2/design-flight-controls.md
/// §3), drawn from the focus vessel's computer's `DSKYDisplay`:
/// - the program, verb and noun, a `*` while they flash (the computer waits
///   for the crew), and its English prompt;
/// - R1-R3 with their labels and units (Apollo units: ft/s, n mi, GET);
/// - the load (TIG, the time to it, ΔVT, the burn time, ΔVC, N81), the EMS
///   counter and who holds the attitude (G&N AUTO or the SCS);
/// - the lamps, lit in brackets ([UPLK], [PROG], [OPR], [KREL]), the reason
///   for PROG or OPR ERR, and the digits keyed.
///
/// Its buttons are the DSKY's, the same in every program: PRG (V37), DSP,
/// V82, KEY REL, + and − down the left; PRO, ENT, CLR, RSET and NXT down the
/// right. Shift and a digit key it. The flight key Return is ENTR or PRO
/// with the page closed as well (the keying lives in the computer).
public final class CMCMFD: MFDMode {
    public init() {}

    public var id: MFDModeID { .cmc }

    public func buttons(_ c: MFDContext?) -> [MFDButton?] {
        let on = c?.vessel.guidanceComputer != nil
        return [
            MFDButton("PRG", .v, "V37: program, then RET", active: on),
            MFDButton("DSP", .d, "The step's next display", active: on),
            MFDButton("V82", .o, "Apsides and TFF", active: on),
            MFDButton("KRL", .k, "Key release", active: on),
            MFDButton("+", .equal, "Sign plus", active: on),
            MFDButton("-", .minus, "Sign minus", active: on),
            MFDButton("PRO", .p, "Proceed", active: on),
            MFDButton("ENT", .returnKey, "Enter the digits", active: on),
            MFDButton("CLR", .delete, "Clear the digits", active: on),
            MFDButton("RST", .r, "Reset the lamps", active: on),
            MFDButton("NXT", .n, "P40 or P41 for the load", active: on),
            nil,
        ]
    }

    /// Shift and a digit key it; the other keys are the buttons'.
    public func handle(_ key: PhysicalKey, _ c: MFDContext?) -> Bool {
        if let d = key.digit {
            guard let c, let computer = c.vessel.guidanceComputer else { return false }
            computer.press(.digit(d), at: c.time)
            return true
        }
        guard let b = buttons(c).compactMap({ $0 }).first(where: { $0.key == key }), b.active else { return false }
        return press(b, c)
    }

    public func press(_ b: MFDButton, _ c: MFDContext?) -> Bool {
        guard let c, let computer = c.vessel.guidanceComputer else { return false }
        let key: DSKYKey
        switch b.key {
        case .v: key = .program
        case .d: key = .display
        case .o: key = .orbitParameters
        case .k: key = .keyRelease
        case .equal: key = .plus
        case .minus: key = .minus
        case .p: key = .proceed
        case .returnKey: key = .enter
        case .delete: key = .clear
        case .r: key = .reset
        case .n: key = .next
        default: return false
        }
        computer.press(key, at: c.time)
        return true
    }

    static let ft = 0.3048

    public func page(_ c: MFDContext) -> MFDPage {
        guard let computer = c.vessel.guidanceComputer else {
            var page = MFDPage(title: "CMC")
            page.add(4, 2, "NO COMPUTER ABOARD", .referenceDim)
            return page
        }
        let d = computer.display
        var title = "CMC"
        if let p = d.program { title += String(format: " P%02d %@", p, d.title) }
        var page = MFDPage(title: String(title.prefix(22)))   // the GET starts at column 23
        page.add(35, 0, "GET " + Self.get(c.time, zero: c.missionClockZero), .referenceDim, alignment: .trailing)

        func two(_ n: Int?) -> String { n.map { String(format: "%02d", $0) } ?? "  " }
        let flash: MFDStyle = d.flashing ? .target : .own
        page.add(4, 2, "PROG", .reference)
        page.add(9, 2, d.program.map { String(format: "%02d", $0) } ?? "", .own)
        page.add(13, 2, "VERB", .reference)
        page.add(18, 2, two(d.verb), flash)
        page.add(22, 2, "NOUN", .reference)
        page.add(27, 2, two(d.noun), flash)
        if d.flashing { page.add(30, 2, "*", .target) }

        // R1-R3 beside the first buttons.
        for (i, r) in d.registers.prefix(3).enumerated() where !r.label.isEmpty {
            let row = 4 + i
            page.add(4, row, "R\(i + 1) " + r.label, .reference)
            page.add(24, row, r.value, .own, alignment: .trailing)
            page.add(26, row, r.unit, .referenceDim)
        }

        var row = 8
        func line(_ s: String, _ style: MFDStyle = .aux) {
            page.add(4, row, String(s.prefix(32)), style)
            row += 1
        }
        if let l = computer.load {
            let tig = Self.get(l.ignition, zero: c.missionClockZero, tenths: true)
            line("LOAD \(l.name) \(l.engine.rawValue)  \(l.source.rawValue)", .target)
            line("TIG \(tig)  TTG " + MFDFormat.duration(l.ignition - c.time))
            var dv = String(format: "DVT %.1f FT/S", l.deltaVMagnitude / Self.ft)
            if let bt = l.burnTime { dv += "  BT " + Self.burnTime(bt) }
            line(dv)
            line("DVC " + (l.deltaVCounter.map { String(format: "%.1f FT/S", $0 / Self.ft) } ?? "---"))
            let n = l.deltaVLocal / Self.ft
            line(String(format: "N81 %+.1f %+.1f %+.1f", n.x, n.y, n.z))
        } else {
            line("NO LOAD", .referenceDim)
        }
        row = 14
        if let counter = c.deltaVCounter {
            line("EMS " + (counter.deltaVRemaining.map { String(format: "%+.1f FT/S", $0 / Self.ft) } ?? "NOT SET"),
                 .reference)
        }
        line("ATT " + AttitudeOwner.describe(c.vessel), .reference)

        if let why = d.reason {
            for (i, l) in Self.wrap(why, width: 32).prefix(2).enumerated() { page.add(4, 16 + i, l, .warn) }
        }

        func lamp(_ name: String, _ on: Bool) -> String { on ? "[\(name)]" : "\(name) ." }
        let lamps = [lamp("UPLK", d.lamps.contains(.uplinkActivity)), lamp("PROG", d.lamps.contains(.programAlarm)),
                     lamp("OPR", d.lamps.contains(.operatorError)), lamp("KREL", d.lamps.contains(.keyRelease))]
        page.add(4, 18, lamps.joined(separator: "  "),
                 d.lamps.isDisjoint(with: [.programAlarm, .operatorError]) ? .reference : .warn)
        page.add(4, 19, "KEY  " + (d.keyBuffer.isEmpty ? "__" : d.keyBuffer + "_"), .own)

        // The prompt, wrapped onto the last rows.
        for (i, l) in Self.wrap(d.prompt, width: 32).prefix(3).enumerated() {
            page.add(4, 21 + i, l, d.flashing ? .target : .reference)
        }
        return page
    }

    /// A burn time: "11.9 S", or minutes and seconds from a minute on
    /// ("4:06.9").
    static func burnTime(_ t: Double) -> String {
        let r = (t * 10).rounded() / 10   // rounded first, so 59.97 s reads 1:00.0
        guard r >= 60 else { return String(format: "%.1f S", r) }
        let m = Int(r / 60)
        return String(format: "%d:%04.1f", m, r - Double(m * 60))
    }

    /// Ground elapsed time as the PADs give it, "259:39:16" ("259:39:16.3"
    /// with `tenths`), from `zero` (or J2000 without one).
    static func get(_ t: Epoch, zero: Epoch?, tenths: Bool = false) -> String {
        let s = t - (zero ?? Epoch(tdbSecondsPastJ2000: 0))
        let a = tenths ? (abs(s) * 10).rounded() / 10 : abs(s).rounded(.down)
        let h = Int(a / 3_600), m = Int(a / 60) % 60, sec = a - Double(h * 3_600 + m * 60)
        let ss = tenths ? String(format: "%04.1f", sec) : String(format: "%02d", Int(sec))
        return String(format: "%@%03d:%02d:%@", s < 0 ? "-" : "", h, m, ss)
    }

    /// `s` in lines of at most `width` characters, broken at spaces.
    static func wrap(_ s: String, width: Int) -> [String] {
        var lines: [String] = [], current = ""
        for word in s.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.map { String($0.prefix(width)) }
    }
}
