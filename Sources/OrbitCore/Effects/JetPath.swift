import Foundation

/// A round turbulent jet issuing into a moving stream: an integral (top-hat)
/// entrainment model, Morton, Taylor and Turner's (1956) hypothesis as Hoult,
/// Fay and Forney (1969) and Lee and Cheung (1990) apply it to jets in a
/// current. Along the path the jet takes in the stream's fluid by two
/// mechanisms: shear entrainment, α1 times the difference between the
/// jet's speed and the stream's along it (Lee and Cheung's |u − U cos θ|),
/// per unit of its perimeter; and forced entrainment, α2 times the stream's
/// speed across it, through its projected width. The fluid taken in brings
/// the stream's momentum, so the jet turns into the stream and slows
/// towards it, and dilutes.
///
/// It draws plumes and feeds no physics. Lengths in m, speeds in m/s, in the
/// source's frame (the vehicle's, where the stream is the relative wind).
/// The source is the jet's momentum-equivalent one: a diameter d at speed u
/// in the stream's own density (for a rocket jet, Thring and Newby's
/// d = Dj √(ρj/ρa) on the fully expanded jet).
///
/// Validity:
/// - Transverse: the path follows Pratte and Baines's (1967) correlation,
///   z/(rd) = 2.05 (x/(rd))^0.28, within about 25 % over x/(rd) 0.5 to 4,
///   for velocity ratios r 5 to 20 (`JetPathTests`). Experiments spread A
///   over 1.2 to 2.6 and B over 0.28 to 0.34 (Margason 1993). Their data
///   reach r 4 to about 8.
/// - Coflow: far from the source the excess speed falls as s^(-2/3) and the
///   width grows as s^(1/3), the weak jet's (Tennekes and Lumley 1972),
///   where near it they go as s^(-1) and s.
/// - Counterflow: the jet penetrates the opposing stream by a distance
///   linear in the velocity ratio, as measured (Lam and Chan 1997), about
///   2 r d here for r 5 to 20 (`JetPathTests`; the measured coefficient is
///   not checked), and is then swept back.
/// - A rocket's jet in flight runs nearly with the stream (an angle of attack
///   of a few degrees), at velocity ratios of 2 to 10, at the edge of the
///   transverse data and outside them.
public enum JetPath {
    /// One point of the path.
    public struct Station: Equatable {
        /// Distance along the path from the source, m.
        public var distance: Double
        /// Position from the source, m.
        public var position: Vec3
        /// The jet fluid's velocity, m/s.
        public var velocity: Vec3
        /// The top-hat half-width, m.
        public var halfWidth: Double
        /// The source's volume flux over the flux now: the jet fluid's
        /// share (the top-hat mixture fraction).
        public var dilution: Double
    }

    /// α1, shear entrainment of a top-hat jet: the Gaussian jet's 0.0535
    /// (Fischer et al. 1979) times √2.
    public static let shearEntrainment = 0.0757
    /// α2, forced entrainment by the stream across the jet: 0.6 (Hoult, Fay
    /// and Forney 1969's order; fitted here to Pratte and Baines).
    public static let forcedEntrainment = 0.6

    /// The path of a jet of momentum-equivalent diameter `diameter` at
    /// `speed` along the unit `direction`, into a stream of velocity
    /// `stream`, out to `length` along the path (or until it has diluted to
    /// `dilution`): stations at steps of a fifth of the jet's half-width
    /// (second-order Runge-Kutta; within 0.1 % of a tenth's).
    public static func path(diameter d: Double, speed uj: Double, direction: Vec3, stream: Vec3,
                            length: Double, until dilution: Double = 0) -> [Station] {
        guard d > 0, uj > 0, length > 0 else { return [] }
        let b0 = 0.5 * d
        let q0 = Double.pi * b0 * b0 * uj
        // The state: volume flux, momentum flux (flux times velocity), position.
        var q = q0, p = direction.normalized * (q0 * uj), x = Vec3.zero, s = 0.0
        func rates(_ q: Double, _ p: Vec3) -> (dq: Double, dp: Vec3, dx: Vec3) {
            let u = p * (1 / q), speed = max(u.length, 1e-9), t = u * (1 / speed)
            let along = stream.dot(t), across = (stream - t * along).length
            let b = (q / (Double.pi * speed)).squareRoot()
            // On the speed's difference either way: a jet turned back into
            // the stream, or slower than its component along it, still
            // shears against it.
            let e = 2 * Double.pi * b * shearEntrainment * abs(speed - along) + 2 * b * forcedEntrainment * across
            return (e, stream * e, t)
        }
        func station() -> Station {
            let u = p * (1 / q), speed = max(u.length, 1e-9)
            return Station(distance: s, position: x, velocity: u, halfWidth: (q / (Double.pi * speed)).squareRoot(),
                           dilution: q0 / q)
        }
        var out = [station()]
        while s < length {
            let b = out[out.count - 1].halfWidth
            let k1 = rates(q, p)
            // A fifth of the width; and where a stream against the jet stops
            // it (the top-hat width diverging as its speed falls to nothing),
            // a fifth of its momentum's turning, at least a fiftieth of the
            // source's width.
            var ds = min(0.2 * b, length - s)
            let turning = k1.dp.length
            if turning > 0 { ds = min(ds, max(0.2 * p.length / turning, 0.02 * b0)) }
            let k2 = rates(q + 0.5 * ds * k1.dq, p + k1.dp * (0.5 * ds))
            q += ds * k2.dq
            p = p + k2.dp * ds
            x = x + k2.dx * ds
            s += ds
            out.append(station())
            if out.count > 20_000 || q0 / q <= dilution { break }
        }
        return out
    }

    /// How much a stream lengthens (or shortens) a jet flame: the distance
    /// along the path at which the jet has diluted as much as it has, in
    /// still air, at `stillLength` (a still-air flame's tip), over
    /// `stillLength`; or, if the stream turns the jet back first (its
    /// velocity no longer along its source's direction), the distance to
    /// where it does: what is swept back lies behind the flame's front.
    /// Entrainment on the speed's difference, so a coflow lengthens it (the
    /// weak jet dilutes as s^(-2/3), not s^(-1)); a crossflow's forced
    /// entrainment shortens it; a counterflow shortens it, to the jet's
    /// penetration into it. Continuous in the stream; 1 in still air; at
    /// most 20 (a coflow at nearly the jet's speed, which hardly mixes).
    public static func flameLengthening(stillLength l0: Double, diameter d: Double, speed uj: Double,
                                        streamAlong: Double, streamAcross: Double) -> Double {
        guard l0 > 0, d > 0, uj > 0 else { return 1 }
        if streamAlong == 0 && streamAcross == 0 { return 1 }
        let axis = Vec3(0, 0, 1)
        // In still air the top-hat jet's flux grows linearly, Q/Q0 = 1 +
        // 2 α1 s / b0: the dilution at the still flame's tip.
        let target = 1 / (1 + 2 * shearEntrainment * l0 / (0.5 * d))
        let moving = path(diameter: d, speed: uj, direction: axis, stream: Vec3(streamAcross, 0, streamAlong),
                          length: 20 * l0, until: target)
        for k in moving.indices.dropFirst() {
            let a = moving[k - 1], b = moving[k]
            let f: Double
            if b.dilution <= target {
                f = (a.dilution - target) / max(a.dilution - b.dilution, 1e-12)
            } else if b.velocity.dot(axis) <= 0 {
                let va = a.velocity.dot(axis), vb = b.velocity.dot(axis)
                f = va / max(va - vb, 1e-12)
            } else {
                continue
            }
            return (a.distance + (b.distance - a.distance) * min(max(f, 0), 1)) / l0
        }
        return 20
    }
}
