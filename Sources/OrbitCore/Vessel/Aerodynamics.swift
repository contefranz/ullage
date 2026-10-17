import Foundation

/// A piecewise-linear table y(x), held constant beyond its ends.
public struct LinearTable: Equatable {
    public var points: [(x: Double, y: Double)]

    public init(_ points: [(Double, Double)]) {
        self.points = points.map { (x: $0.0, y: $0.1) }
    }

    public func callAsFunction(_ x: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].x <= x { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        return a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
    }

    public static func == (a: LinearTable, b: LinearTable) -> Bool {
        a.points.count == b.points.count && zip(a.points, b.points).allSatisfy { $0.x == $1.x && $0.y == $1.y }
    }
}

/// Static aerodynamics of one vessel configuration (a launch stack), in the
/// body axes: an axial force along -x, a normal force across it in the plane
/// of the angle of attack, and the normal force's moment about the centre of
/// mass. Coefficients are on a reference area S and diameter D.
///
/// - Axial: a forebody coefficient C_Af(M) on q S, plus a base force. With
///   the base engines running the base force comes from the base pressure
///   differential P_b - P∞, which depends on altitude rather than Mach:
///   F_Ab = -k (P_b - P∞) S (the Saturn V's flight-evaluation form, Boeing
///   D5-15796-1); with them off, from a base coefficient C_Ab(M) on q S.
/// - Normal: C_N = C_Nα(M) sin α |cos α|, acting at the centre of pressure
///   X_cp(M) calibers forward of a reference station, plus a viscous
///   crossflow term for large angles (slender-body theory), acting at the
///   planform centroid of the vessel's parts.
///
/// Roll is symmetric, the centre of mass is on the axis, and there is no
/// damping derivative.
public struct AerodynamicModel {
    public var name: String
    /// The model applies while all these parts are aboard.
    public var requiredParts: [String]
    /// Reference area S (m^2) and diameter D (m, the caliber).
    public var referenceArea: Double
    public var referenceDiameter: Double
    /// Construction x (m) of the station the centre of pressure is measured from.
    public var referenceStation: Double
    /// Forebody axial-force coefficient against Mach.
    public var forebodyAxial: LinearTable
    public var base: BaseFlow?
    /// Normal-force-coefficient slope (per rad) and centre of pressure
    /// (calibers forward of `referenceStation`) against Mach.
    public var normalForceSlope: LinearTable
    public var centerOfPressure: LinearTable
    /// Crossflow drag coefficient times its proportionality factor (η C_dc),
    /// applied beyond `linearAngle` on the vessel's planform area.
    public var crossflow: (coefficient: Double, linearAngle: Double)
    /// A drag coefficient along the relative wind instead (`forebodyAxial`
    /// on S): no lift and no moment, as for a body in free-molecular flow.
    public var dragAlongWind: Bool

    public struct BaseFlow {
        /// Effective base area as a fraction of S.
        public var areaFactor: Double
        /// P_b - P∞ (Pa) against altitude (m), with the engines of
        /// `enginesPart` delivering thrust.
        public var poweredDifferential: LinearTable
        public var enginesPart: String
        /// Base axial-force coefficient against Mach with those engines off.
        public var unpoweredCoefficient: LinearTable

        public init(areaFactor: Double, poweredDifferential: LinearTable, enginesPart: String,
                    unpoweredCoefficient: LinearTable) {
            self.areaFactor = areaFactor
            self.poweredDifferential = poweredDifferential
            self.enginesPart = enginesPart
            self.unpoweredCoefficient = unpoweredCoefficient
        }
    }

    public init(name: String, requiredParts: [String], referenceArea: Double, referenceDiameter: Double,
                referenceStation: Double, forebodyAxial: LinearTable, base: BaseFlow? = nil,
                normalForceSlope: LinearTable = LinearTable([(0, 0)]), centerOfPressure: LinearTable = LinearTable([(0, 0)]),
                crossflow: (coefficient: Double, linearAngle: Double) = (0, 0), dragAlongWind: Bool = false) {
        self.name = name
        self.requiredParts = requiredParts
        self.referenceArea = referenceArea
        self.referenceDiameter = referenceDiameter
        self.referenceStation = referenceStation
        self.forebodyAxial = forebodyAxial
        self.base = base
        self.normalForceSlope = normalForceSlope
        self.centerOfPressure = centerOfPressure
        self.crossflow = crossflow
        self.dragAlongWind = dragAlongWind
    }

    /// What the flow does to the vessel: force and torque in the body axes.
    public struct Loads {
        public var force = Vec3.zero
        public var torque = Vec3.zero
        /// Total angle of attack (rad, 0...π) and Mach number.
        public var angleOfAttack = 0.0
        public var mach = 0.0
    }

    /// The loads for the vessel moving at `air` (body axes, m/s) relative to
    /// the air in `atmosphere` at `altitude`. `centerOfPressureX` maps a
    /// centre of pressure in calibers to the vessel-frame x of its station;
    /// `planform` is the vessel's side area and its centroid's x.
    public func loads(air u: Vec3, atmosphere: AtmosphereState, altitude: Double, powered: Bool,
                      centerOfPressureX: (Double) -> Double, planform: (area: Double, x: Double)) -> Loads {
        var out = Loads()
        let speed = u.length
        guard speed > 1e-6, atmosphere.density > 0 else { return out }
        let q = 0.5 * atmosphere.density * speed * speed
        let mach = atmosphere.speedOfSound > 0 ? speed / atmosphere.speedOfSound : 0
        let cross = (u.y * u.y + u.z * u.z).squareRoot()
        let cosA = u.x / speed, sinA = cross / speed
        out.angleOfAttack = atan2(sinA, cosA)
        out.mach = mach
        let s = referenceArea
        if dragAlongWind {
            out.force = u * (-forebodyAxial(mach) * q * s / speed)
            return out
        }
        // Axial, positive aft when the air comes from ahead.
        var axial = forebodyAxial(mach) * q * s * cosA
        if let b = base {
            axial += powered ? -b.areaFactor * b.poweredDifferential(altitude) * s
                : b.unpoweredCoefficient(mach) * q * s * cosA
        }
        out.force.x = -axial
        // Normal, against the crossflow.
        guard cross > 1e-9 else { return out }
        let away = Vec3(0, -u.y / cross, -u.z / cross)
        let linear = normalForceSlope(mach) * sinA * abs(cosA) * q * s
        let s0 = sin(crossflow.linearAngle)
        let viscous = crossflow.coefficient * planform.area * max(0, sinA * sinA - s0 * s0) * q
        let fLinear = away * linear, fViscous = away * viscous
        out.force += fLinear + fViscous
        let xcp = centerOfPressureX(centerOfPressure(mach))
        out.torque = Vec3(0, -xcp * fLinear.z, xcp * fLinear.y)
            + Vec3(0, -planform.x * fViscous.z, planform.x * fViscous.y)
        return out
    }
}

extension Vessel {
    /// The first of `aerodynamics` whose parts are all aboard; nil flies the
    /// generic drag of `dragArea`.
    public var activeAerodynamics: AerodynamicModel? {
        let names = Set(parts.map(\.name))
        return aerodynamics.first { $0.requiredParts.allSatisfy(names.contains) }
    }

    /// Side area of the parts' bounding cylinders (m^2) and its centroid's
    /// vessel-frame x.
    var planform: (area: Double, x: Double) {
        var area = 0.0, moment = 0.0
        for p in parts {
            let a = 2 * p.radius * p.length
            area += a
            moment += a * p.offset.x
        }
        return (area, area > 0 ? moment / area : 0)
    }

    /// The vessel-frame x of a station `calibers` forward of the model's
    /// reference station.
    func centerOfPressureX(_ model: AerodynamicModel) -> (Double) -> Double {
        let origin = structureOrigin.x, station = model.referenceStation, d = model.referenceDiameter
        return { origin + station + $0 * d }
    }

    /// Whether the base engines of the model are delivering thrust.
    func basePowered(_ model: AerodynamicModel) -> Bool {
        guard let b = model.base else { return false }
        return parts.first { $0.name == b.enginesPart }?.thrusters
            .contains { $0.groups.contains(.main) && $0.isDelivering } ?? false
    }
}
