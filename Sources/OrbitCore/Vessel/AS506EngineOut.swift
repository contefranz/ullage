import Foundation

/// The IU's engine-out logic for AS-506 (datasheet §16). AS-506's own
/// engine-out presettings were not found: GE504's SA-504 values stand in, as
/// they do for the pitch program (§8.4), and MAN506 p 2-18 puts the S-IC's
/// chi freeze in AS-506's program.
extension AS506 {
    // MARK: Engine out

    /// The S-IC engine-out ("reduced-loads") chi freeze, GE504 Table 4-II
    /// and Figure 3-4 with Table 5-I's presettings (H for SA-504, M for
    /// AS-506): the pitch program holds for Δt_f s from the failure, or from
    /// t_2 for a failure up to t_2, then runs on Δt_f s behind; Δt_f is t_3
    /// for a failure up to t_2, B11 t + B12 to t_4, B21 t + B22 to t_5, and
    /// 0 after. The tilt arrest moves out by a quarter of the time from the
    /// failure to it.
    static let engineOutFreezeTimes = (t2: 25.0, t3: 36.0, t4: 45.0, t5: 81.0)   // s from T1; GE504 Table 5-I
    static let engineOutFreezeLines = (b11: -0.62, b12: 40.9, b21: -0.3611, b22: 29.25)   // -, s; GE504 Table 5-I
    /// The thrust OK pressure switches the IU's engine-out logic reads drop
    /// out below 90 % of rated thrust on an F-1 and 65 % on a J-2: MAN506 §3
    /// (EDS engine status lights; the auto-abort's "two or more S-IC engines
    /// drop below 90 % of rated thrust") and §2 (S-II, 65 %). M: the EDS
    /// lights' levels, taken for the LVDC's discrete.
    static let sICThrustOK = 0.90   // MAN506 §3 (M)
    static let sIIThrustOK = 0.65   // MAN506 §2, §3 (M)
    /// The IU senses an S-IC engine out from T1 + 6 s (planning study's
    /// reading of GE504; L until re-read), after the hold-down and
    /// tower-clearance transients.
    static let sICEngineOutSensingStart = 6.0   // s from T1 (L)
    /// The EDS two-engine-out automatic abort, armed from liftoff until the
    /// crew deactivates it at 2 min (MAN506 Figure 3-7 and the ascent
    /// checklist; the LV sequencer disables it before CECO in any case): the
    /// model only logs it.
    static let edsAutoAbortEnd = 120.0 - liftoff   // s from T1; MAN506 (H)
}
