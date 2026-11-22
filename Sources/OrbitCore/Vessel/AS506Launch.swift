import Foundation

/// AS-506's terminal count and launch sequence on LC-39A: the pad's events,
/// the S-IC's ignition and thrust buildup in the hold-down arms, and the
/// release (`TerminalCount.Plan.as506`). Range time, s from range zero.
extension AS506 {
    // MARK: Pad events

    /// The S-IC intertank arm's (arm 1's) retract command: it withdrew in
    /// 5.06 s and reached its safe angle 9.9 s after the command, 3.9 s
    /// before arm 2's command (FER-506 §3.6.2: 9.9 + 3.9 + 16.2 = 30.0 s),
    /// as the Apollo 8 press kit's "released at T-30 seconds" (LC39A
    /// datasheet §4.2).
    static let sICIntertankArmCommand = -30.0   // FER-506 §3.6.2, derived (H)
    /// The S-IC forward arm's (arm 2's) retract command, "SA No. 2 retract
    /// at -16.2 seconds" (FER-506 §3.6).
    static let sICForwardArmCommand = -16.2     // FER-506 §3.6 (H)
    /// The ignition command: the S-IC engine start sequence ("ignition
    /// sequence start" in the Apollo 11 commentary; SP-4206 Appendix B, the
    /// Saturn V launch sequence).
    static let ignitionCommand = -8.9           // SP-4029 Timeline; SP-4206 App. B; AFJ; FER-506 Table 2-2 (H)

    // MARK: The launch window (16 July 1969)

    /// The window opened at 13:32 UTC on 72° and closed at 17:54 UTC on
    /// 108°, "Based on 108° launch azimuth upper limit", the azimuth
    /// increasing "approximately 8° per hour" (Mission Operation Report
    /// M-932-69-11, Table 2 and p. 17, H; 72°-108° also in the TIS and the
    /// FER, 72°-106° in the press kit). AS-506's own azimuth polynomial in
    /// the time of launch (GE504 Table 4-I's form) was not found: the model
    /// takes the azimuth linear in time from Apollo 11's 72.058° at its
    /// on-time range zero (FER §4.1) at the window's mean rate, 36° in
    /// 4 h 22 min (8.24°/h, M), up to the 108° limit.
    static let windowAzimuthRate = 36.0 / (4 * 3600 + 22 * 60)   // deg/s, MOR (M)
    static let windowAzimuthLimit = 108.0                          // deg, MOR Table 2 (H)
    /// The IGM's target plane against the azimuth: GE504 Table 5-I's SA-504
    /// polynomials (i(op) = θ_N(op) = 1), i = Σ f_n x^n and θ_N = Σ g_n x^n
    /// with x = (A_Z − A_ZO) / A_ZS, degrees (H for SA-504). GE504 does not
    /// print A_ZO and A_ZS; 72° and 36° give AS-506's nominal plane at
    /// 72.058° within 0.003° and 0.018° (FER Table 4-5: 32.531°, 123.100°)
    /// and i = 28.44°, the pad's latitude, due east (M, inferred). SA-504's
    /// polynomials stand in for AS-506's (M as a proxy), anchored on its
    /// nominal plane (`SaturnIU.LaunchWindow`).
    static let windowInclination = [32.5597, -16.2615, 15.6919, -6.7370, 26.9593, -28.9526, 9.8794]
    static let windowDescendingNode = [123.2094, -56.5034, -21.6675, -14.5228, 47.5320, -22.5502, 1.8946]
    static let windowPolynomialZero = 72.0      // deg, A_ZO (M, inferred)
    static let windowPolynomialScale = 36.0     // deg, A_ZS (M, inferred)

    // MARK: The S-IC's start

    /// The start commands of the 1-2-2 start, "planned and attained":
    /// engine 5, then 1 and 3, then 4 and 2 (FER-506 Table 2-2 and §5.2, H).
    static let engineStarts: [(engine: Int, command: Double)] = [(5, -6.4), (1, -6.1), (3, -6.1), (4, -6.0), (2, -5.9)]
    /// From a start command to the main chamber's ignition, where its thrust
    /// starts to rise, and that rise to full thrust: FER-506 Figure 5-2,
    /// read off (engine 5 rises from about −3.05 s, engines 1 and 3 from
    /// −2.75 s, each 3.35 s after its command, over 1.1 to 1.2 s; §5.2's
    /// chamber pressure spikes 3.45 s after the start solenoids), linear (L
    /// shape). Engine 2 then reaches 90 % at −1.5 s; FER Table 2-2: all
    /// engines thrust OK at −1.6 s.
    static let f1IgnitionDelay = 3.35           // s, FER-506 Figure 5-2 (M)
    static let f1ThrustRise = 1.15              // s, FER-506 Figure 5-2 (M; L shape)
    /// The propellant the S-IC burned from its ignition to first motion,
    /// "S-IC thrust buildup" in FER Table 20-9 (predicted 38,893 kg), and
    /// the vehicle's mass at ground ignition, Table 20-1 (6,477,875 lb,
    /// SP-4029's Ground Ignition Weights): `firstMotionMass` plus it. FER
    /// §5.2 gives 39,374 kg, its Table 5-2 LOX 30,885 kg and RP-1 8,489 kg
    /// (H): a LOX-rich start the model, burning at its mixture ratio, does
    /// not reproduce (its tanks match Table 5-2 at the release). What the
    /// engines' thrust does not burn (12.4 engine-seconds at the
    /// first-motion flow, 32,563 kg) flows from each start command to its
    /// ignition (the LOX lead and the turbopumps' spin-up on the gas
    /// generator): 15 % of full flow, so that the whole is Table 20-9's
    /// (derived, `TerminalCount.Plan.as506`).
    static let thrustBuildupPropellant = preReleaseMass   // 39,307 kg, FER Table 20-9 (H)
    /// Launch commit at T−0: the hold-down arms release once every engine
    /// runs at its thrust OK level then (the IU's `sICThrustOK`, MAN506 §3, M).
    static let launchCommit = 0.0
    /// The hold-down release: all four arms released at 0.3 s (FER-506
    /// §3.6.1), the vehicle's first motion (`firstMotion`).
    static let holdDownRelease = firstMotion
    /// The primary liftoff switches on the hold-down arms close at 3/4 in
    /// of rise (MSFC-MAN-503 p. 8-8; FER-503 §3.6: "1-inch liftoff"): the
    /// in-flight arms and the tail service masts start then (LC39A
    /// datasheet §4.2).
    static let liftoffSwitchRise = 0.75 * inch  // MSFC-MAN-503 p. 8-8 (H)
    /// The controlled release: "Eight mechanisms will be used for the
    /// SA-506 launch", each a tapered pin drawn through a die "as the
    /// vehicle rises through the first six inches", its force decreasing
    /// "linearly from maximum restraint at holddown release to zero"
    /// (MAN506 p. 8-8, H); the peak force per rod about 400,000 N in flight
    /// (FER-506 Table 11-1, H; predicted 415,000 N; the HDA paper's generic
    /// 330 kN). FER-506 Figure 9-1 has the rods' force at zero about 0.6 s
    /// after the release (M); the model's stroke takes 0.55 s
    /// (`TerminalCountTests.testTheControlledRelease`).
    static let controlledReleaseRods = 8.0                 // MAN506 p. 8-8 (H)
    static let controlledReleaseForce = 400_000.0          // N per rod, FER-506 Table 11-1 (H)
    static let controlledReleaseStroke = 6 * inch          // MAN506 p. 8-8 (H)
    static var controlledRelease: TerminalCount.ControlledRelease? {
        TerminalCount.ControlledRelease(force: controlledReleaseRods * controlledReleaseForce,
                                        stroke: controlledReleaseStroke)
    }
}
