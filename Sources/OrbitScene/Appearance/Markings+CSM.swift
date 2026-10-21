import Foundation
import OrbitCore

// The spacecraft's markings (csm.csv): CSM-101, CSM-103 and CSM-107 with
// their SLA, BPC, LES and Apollo 8's LTA-B. Rows are in Apollo stations (Xa)
// and apply to their own element's shapes.

extension Markings {
    /// The spacecraft's outer radius (in) at STA `station` on `element`:
    /// the SM's 154 in cylinder (77 in), the SLA's cone from the IU's 130 in
    /// at Xa 502 to the SM's 77 in at Xa 838 (VD3 §12); the other elements
    /// carry no decals and take the SM's.
    public static func spacecraftRadius(_ element: PaintElement, station: Double) -> Double {
        let sm = 77.0
        guard element == .sla else { return sm }
        let xa = station - MarkingRow.apolloStationOffset, bottom = 502.0, top = 838.0
        let t = max(0, min(1, (xa - bottom) / (top - bottom)))
        return 130 + (sm - 130) * t
    }

    /// A spacecraft decal row's content:
    /// - `flag`: an EO 10834 flag, `union=upper hoist`, the hoist on the
    ///   side `hoist` names;
    /// - `panel=...`: the box in the row's paint (the SM's white field);
    /// - `text`: its `lines` (`/` between them; the text alone when none)
    ///   read left to right, `letter_h` tall, each line `width_in` wide
    ///   (CSM-101's 30 in is wider than its 26.2 in box and is kept), in
    ///   the row's paint.
    static func spacecraftDecalContent(_ row: MarkingRow) -> Decal.Content {
        let p = row.params, colour = PaintColour(row.paint)
        if row.paint == .flag { return .flag(hoistAtLowAzimuth: p["hoist"] != "high azimuth") }
        if p["panel"] == nil, let text = p["text"] {
            let lines = (p["lines"] ?? text).split(separator: "/").map(String.init)
            let height = row.vehicleStations.upperBound - row.vehicleStations.lowerBound
            return .lines(lines, letterHeight: row.number("letter_h") ?? height / Double(max(lines.count, 1)),
                          lineWidth: row.number("width_in"), ink: colour, background: nil)
        }
        return .panel(colour)
    }
}

extension PaintElement {
    /// The Saturn V's parts, by the M1.5 contract's names.
    public static let launchVehicleParts: Set<String> = [
        "S-IC", "S-IC/S-II interstage", "S-II", "S-II/S-IVB interstage", "S-IVB", "S-IVB ullage rockets", "IU",
    ]

    /// Materials that take no paint: the engines' bells and nozzles, the
    /// LM's foil, the parachutes' canvas.
    public static let unpaintedMaterials: Set<MaterialKey> = [
        .apolloEngineBell, .apolloSPSNozzle, .apolloLMFoil, .apolloCanvas,
    ]

    /// The tower's base, Xa 1083.476 (csm.csv's LES rows): the BPC's shell
    /// starts below it, the tower's shapes at or above it.
    static let towerBase = 1_083.476

    /// The element whose rows paint `shape` of the part named `part` on
    /// `variant`, nil when no table row applies (an unpainted material, the
    /// LM, the parachutes):
    /// - the Saturn V's parts: the launch vehicle, by station;
    /// - "SLA", "SLA ring", "SLA panel 1"-"4": the SLA;
    /// - "LM": LTA-B on Apollo 8, nothing otherwise (LM-5 is foil);
    /// - "SM"; "CM" and "Apex cover";
    /// - the stack's single "CSM" part: the CM for the CM's materials
    ///   (`apollo.cm.*`), the SM for the rest;
    /// - "LES": the BPC for a shape whose material names it ("bpc") or a
    ///   shell about the vehicle's axis that starts below the tower's base,
    ///   the LES for the rest (the truss, motors, canards and nose).
    public static func of(part: String, shape: VisualShape, variant: ApolloVariant) -> PaintElement? {
        guard !unpaintedMaterials.contains(shape.material) else { return nil }
        if launchVehicleParts.contains(part) { return variant.launchVehicle == nil ? nil : .launchVehicle }
        switch part {
        case "SLA", "SLA ring":
            return .sla
        case "LM":
            return variant.payload == .ltaB ? .ltaB : nil
        case "SM":
            return .sm
        case "CM", "Apex cover":
            return .cm
        case "CSM":
            return shape.material.rawValue.hasPrefix("apollo.cm.") ? .cm : .sm
        case "LES":
            return isBPC(shape) ? .bpc : .les
        default:
            return part.hasPrefix("SLA panel ") ? .sla : nil
        }
    }

    static func isBPC(_ shape: VisualShape) -> Bool {
        if shape.material.rawValue.lowercased().contains("bpc") { return true }
        guard case let .vehicle(o) = shape.surfaceFrame, abs(shape.axis.x) > 1 - 1e-9 else { return false }
        let base = shape.origin + o
        guard (base.y * base.y + base.z * base.z).squareRoot() < 1e-6 else { return false }
        return base.x / PaintCoordinates.inch - MarkingRow.apolloStationOffset < towerBase
    }
}
