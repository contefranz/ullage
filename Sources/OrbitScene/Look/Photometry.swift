import Foundation

/// Photometric units for the HDR renderer (track R1 owns this file and pins
/// its values with tests).
public enum Photometry {
    /// The astronomical unit, m (IAU 2012).
    public static let astronomicalUnit = 149_597_870_700.0
    /// The Sun's illuminance at 1 AU above the atmosphere, lux: nominal, the
    /// middle of the published 128-134 klx, until R1 pins Darula, Kittler and
    /// Gueymard (2005).
    public static let solarIlluminanceAt1AU = 131_000.0

    /// The Sun's illuminance at `distance` (m) from it, lux.
    public static func solarIlluminance(distance: Double) -> Double {
        let au = distance / astronomicalUnit
        return solarIlluminanceAt1AU / max(au * au, 1e-12)
    }
}
