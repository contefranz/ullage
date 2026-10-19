import Foundation

extension Simulation {
    /// Sutton and Graves's stagnation-point constant for air (NASA TR R-376),
    /// kg^0.5 / m: q = k sqrt(ρ / R_n) V^3, W/m^2.
    static let suttonGravesAir = 1.7415e-4

    /// The entry telemetry of `v` at the end of a step (`Vessel.sensedAcceleration`
    /// ... `heatLoad`), from the state the step ended in and its thrust, air
    /// and altitude telemetry (`updateTelemetry` sets those first).
    ///
    /// - Sensed acceleration: the aerodynamic and thrust forces over mass,
    ///   as an accelerometer at the centre of mass reads them; on the
    ///   surface, the support that holds the vessel in the rotating frame
    ///   (1 g up at rest).
    /// - Bank angle, for a vessel flying a capsule model: the angle about the
    ///   velocity relative to the air from the local up (the ellipsoid
    ///   normal) to the side of the axis the centre of mass is on, where the
    ///   trim lift points; positive to the right looking along the velocity.
    ///   Nil without a capsule, or with the air velocity along the vertical.
    /// - Heat flux, for a capsule: Sutton-Graves convective heating at the
    ///   stagnation point of the capsule's `noseRadius`, at the air-relative
    ///   speed. Telemetry only: nothing ablates. The heat load integrates it
    ///   by the trapezoid rule from one update to the next
    ///   (`Vessel.entryTelemetryEpoch`).
    func updateEntryTelemetry(_ v: Vessel, snapshot s: SystemSnapshot) {
        defer { v.entryTelemetryEpoch = s.time }
        let body = v.reference, o = s.orientation(body)
        let atm = atmosphere(of: body)
        var air = v.surfaceVelocity(snapshot: s)
        if let atm, v.atmosphere.density > 0 {
            air = airVelocity(r: v.position, v: v.velocity, body: body, atmosphere: atm, altitude: v.altitude, snapshot: s)
        }
        let model = v.activeAerodynamics

        // Sensed acceleration, body axes.
        if v.landed != nil {
            let held = o.angularVelocity.cross(o.angularVelocity.cross(v.position))
            let g = system.acceleration(relativeTo: body, at: v.position, snapshot: s)
            v.sensedAcceleration = v.attitude.inverseRotate(held - g)
        } else {
            var force = v.thrustForceAndTorque(ambientPressure: v.atmosphere.pressure,
                                               seaLevelPressure: atm?.seaLevelPressure ?? 0).force
            if v.atmosphere.density > 0 {
                if let model {
                    force += model.loads(air: v.attitude.inverseRotate(air), atmosphere: v.atmosphere, altitude: v.altitude,
                                         powered: v.basePowered(model), centerOfPressureX: v.centerOfPressureX(model),
                                         planform: v.planform).force
                } else {
                    force += v.attitude.inverseRotate(air * (-0.5 * v.atmosphere.density * air.length * v.dragArea))
                }
            }
            v.sensedAcceleration = force / v.mass
        }
        v.loadFactor = v.sensedAcceleration.length / 9.80665

        // Bank angle and heating, for a capsule.
        var flux = 0.0
        if let capsule = model?.capsule {
            v.bankAngle = Self.bankAngle(of: v, air: air, up: body.vertical(at: v.position, orientation: o),
                                         liftSide: v.liftSide(capsule))
            let speed = air.length
            flux = Self.suttonGravesAir * (v.atmosphere.density / capsule.noseRadius).squareRoot() * speed * speed * speed
        } else {
            v.bankAngle = nil
        }
        if let last = v.entryTelemetryEpoch, s.time - last > 0 {
            v.heatLoad += 0.5 * (v.heatFlux + flux) * (s.time - last)
        }
        v.heatFlux = flux
    }

    /// The bank angle (rad, -π...π) of a vessel whose lift side is
    /// `liftSide` (body axes), flying at `air` (ICRF) relative to the air
    /// with `up` the local vertical: about the air velocity, from the up's
    /// projection across it to the lift side's, positive to the right
    /// looking along the velocity. Nil when either projection vanishes.
    static func bankAngle(of v: Vessel, air: Vec3, up: Vec3, liftSide: Vec3) -> Double? {
        let speed = air.length
        guard speed > 1e-3 else { return nil }
        let forward = air / speed
        let upAcross = up - forward * up.dot(forward)
        let side = v.attitude.rotate(liftSide), sideAcross = side - forward * side.dot(forward)
        guard upAcross.length > 1e-6, sideAcross.length > 1e-6 else { return nil }
        let u = upAcross.normalized, right = forward.cross(u)
        return atan2(sideAcross.dot(right), sideAcross.dot(u))
    }
}

extension Vessel {
    /// The side of the axis a capsule's lift is on at trim: from its axis
    /// (through the construction origin, along x) towards the centre of
    /// mass, body axes; the table's side if the centre of mass is on it.
    func liftSide(_ capsule: CapsuleAerodynamics) -> Vec3 {
        let offset = Vec3(0, -structureOrigin.y, -structureOrigin.z)
        return offset.length > 1e-9 ? offset.normalized : capsule.referenceSide
    }
}
