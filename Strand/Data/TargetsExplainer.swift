import Foundation
import StrandAnalytics

/// The four target derivations with THAT DAY's actual inputs filled in (260901, maintainer's ask:
/// "the precise formula that was used", shown right after the four numbers and before the LLM
/// narrative — optional, so it collapses out of the way). Iterated same-day on maintainer review:
/// code-shaped, not narrative — each block is `input comparison → consequence` lines, the taken
/// branch of the real if/else spelled with its real thresholds, ending in the displayed number.
///
/// Pure and static so the wording is pinned by tests. Every block header carries the same number
/// the strip displays (the caller passes the values straight off the freshly built `LiveTargets`),
/// and the components are re-derived through the SAME public `DailyTargets` constants/functions
/// the pricing used, so the derivation can never drift from the targets.
enum TargetsExplainer {

    private static func hm(_ minutes: Int) -> String {
        "\(minutes / 60)h\(String(format: "%02d", minutes % 60))"
    }

    /// The taken branch of the charge→band comparison, with the real thresholds.
    /// `push` names the value the band selected (session minutes or step base).
    private static func chargeLine(_ charge: Int?, push: Int, maintain: Int, recover: Int,
                                   unit: String) -> String {
        guard let charge else { return "charge — (none) → base \(maintain)\(unit) (maintain)" }
        if charge >= DailyTargets.pushChargeFloor {
            return "charge \(charge) ≥ \(DailyTargets.pushChargeFloor) → base \(push)\(unit) (push)"
        }
        if charge <= DailyTargets.recoverChargeCeiling {
            return "charge \(charge) ≤ \(DailyTargets.recoverChargeCeiling) → base \(recover)\(unit) (recover)"
        }
        return "charge \(charge) in \(DailyTargets.recoverChargeCeiling + 1)–\(DailyTargets.pushChargeFloor - 1)"
             + " → base \(maintain)\(unit) (maintain)"
    }

    /// The blocks: the shared session ladder first (effort and calories are both priced off it),
    /// then one block per target. `nil` targets simply omit their block — the section shows
    /// exactly what the strip shows. Each element is one multi-line block, rendered monospaced.
    static func lines(charge: Int?,
                      readiness: ReadinessEngine.Level,
                      restScore: Int?,
                      session: DailyTargets.SessionPrescription?,
                      sessionHrBpm: Int?,
                      effortTarget: Int?,
                      kcalTarget: Int?,
                      stepsTarget: Int?,
                      sleepNeedMin: Int?,
                      age: Int?,
                      restingHr: Int?,
                      profile: UserProfile,
                      debtBalanceMin: Double) -> [String] {
        var out: [String] = []
        let readinessWord = String(describing: readiness)

        // ── SESSION: the notch ladder both Effort and Cal price from ─────────────────────────
        var s: [String] = ["SESSION"]
        s.append(chargeLine(charge, push: DailyTargets.pushSessionMinutes,
                            maintain: DailyTargets.maintainSessionMinutes,
                            recover: DailyTargets.recoverSessionMinutes, unit: "m"))
        let baseNotch: Int
        switch readiness {
        case .rundown: baseNotch = 0
        case .strained: baseNotch = 1
        case .balanced, .insufficient: baseNotch = 2
        case .primed: baseNotch = 3
        }
        s.append("readiness \(readinessWord) → notch \(baseNotch)  (rest0 low1 ok2 primed3)")
        if let rest = restScore {
            if rest < DailyTargets.poorRestScore {
                s.append("rest \(rest) < \(DailyTargets.poorRestScore) → notch −1")
            } else if rest >= DailyTargets.greatRestScore {
                s.append("rest \(rest) ≥ \(DailyTargets.greatRestScore) → notch +1")
            } else {
                s.append("rest \(rest) in \(DailyTargets.poorRestScore)–\(DailyTargets.greatRestScore - 1) → notch +0")
            }
        } else {
            s.append("rest — (none) → notch +0")
        }
        // The final notch, re-walked through the SAME ladder the prescription used, so the
        // multiplier label is derived from the inputs — never inferred back from the minutes.
        var finalNotch = baseNotch
        if let rest = restScore {
            if rest < DailyTargets.poorRestScore { finalNotch = max(finalNotch - 1, 0) }
            else if rest >= DailyTargets.greatRestScore { finalNotch = min(finalNotch + 1, 3) }
        }
        if let session {
            let mult = finalNotch == 1 ? "×1/2, zone-2" : (finalNotch == 3 ? "×4/3, zone-3" : "×1, zone-2")
            s.append("⇒ notch \(finalNotch) → \(session.minutes)m (base\(mult), "
                     + "w \(String(format: "%.1f", session.edwardsZoneWeight)))")
            if let hr = sessionHrBpm {
                let rhr = restingHr ?? 60
                let hrmax = Int(DailyTargets.hrMax(age: (age).map(Double.init)).rounded())
                s.append("hr = \(rhr) + \(String(format: "%.2f", session.hrrFraction))×(\(hrmax)−\(rhr))"
                         + " = \(hr)bpm")
            }
        } else {
            s.append("⇒ notch 0 → REST DAY (no session)")
        }
        out.append(s.joined(separator: "\n"))

        // ── EFFORT: the frozen target is the session alone through the strain curve ─────────
        if let effortTarget {
            if let session {
                let trimp = session.edwardsZoneWeight * Double(session.minutes)
                out.append("""
                EFFORT → \(effortTarget)
                trimp = \(String(format: "%.1f", session.edwardsZoneWeight)) × \(session.minutes)m = \(Int(trimp))
                target = strain(\(Int(trimp))) = \(effortTarget)  (0–100)
                frozen: today's accrual excluded; n may pass t
                """)
            } else {
                out.append("""
                EFFORT → 0
                rest day → target = 0; x/0 shows any accrual
                """)
            }
        }

        // ── CAL: a full resting day + the session through Keytel ────────────────────────────
        // The resting part is stated as target − session (exact arithmetic on the displayed
        // numbers, so the block can never disagree with the strip across rounding).
        if let kcalTarget {
            let round = Int(DailyTargets.calorieRoundKcal)
            if let session {
                let sessionKcal = DailyTargets.sessionKcal(session: session, profile: profile,
                                                           restingHr: restingHr)
                let hrText = sessionHrBpm.map { "\($0)bpm × " } ?? ""
                out.append("""
                CAL → \(kcalTarget)
                resting = rmr × 24h ≈ \(kcalTarget - sessionKcal)
                session = keytel(\(hrText)\(session.minutes)m) = \(sessionKcal)
                target = round\(round)(\(kcalTarget - sessionKcal) + \(sessionKcal)) = \(kcalTarget)
                """)
            } else {
                out.append("""
                CAL → \(kcalTarget)
                rest day → session = 0
                target = round\(round)(rmr × 24h) = \(kcalTarget)
                """)
            }
        }

        // ── STEPS: charge band base, readiness trim, clamp ───────────────────────────────────
        if let stepsTarget {
            var st: [String] = ["STEPS → \(stepsTarget)"]
            st.append(chargeLine(charge, push: DailyTargets.stepsBasePushPerDay,
                                 maintain: DailyTargets.stepsBaseMaintainPerDay,
                                 recover: DailyTargets.stepsBaseRecoverPerDay, unit: ""))
            switch readiness {
            case .rundown: st.append("readiness rundown → \(DailyTargets.stepsRundownAdj)")
            case .strained: st.append("readiness strained → \(DailyTargets.stepsStrainedAdj)")
            default: st.append("readiness \(readinessWord) → −0")
            }
            st.append("clamp(\(DailyTargets.stepsFloorPerDay)…\(DailyTargets.stepsCapPerDay))"
                      + " → \(stepsTarget)")
            out.append(st.joined(separator: "\n"))
        }

        // ── SLEEP: population base ± charge/Rest/readiness, + capped debt share, clamp ──────
        if let sleepNeedMin {
            let baseMin = Int(AnalyticsEngine.Rest.populationNeedFloorHours(age: age) * 60.0)
            var sl: [String] = ["SLEEP → \(hm(sleepNeedMin))"]
            sl.append("base = need(age \(age.map(String.init) ?? "—")) = \(hm(baseMin))")
            if let charge {
                if charge <= DailyTargets.recoverChargeCeiling {
                    sl.append("charge \(charge) ≤ \(DailyTargets.recoverChargeCeiling)"
                              + " → +\(Int(DailyTargets.sleepChargeAdjRecoverMin))m")
                } else if charge < DailyTargets.pushChargeFloor {
                    sl.append("charge \(charge) < \(DailyTargets.pushChargeFloor)"
                              + " → +\(Int(DailyTargets.sleepChargeAdjMaintainMin))m")
                } else {
                    sl.append("charge \(charge) ≥ \(DailyTargets.pushChargeFloor) → +0m")
                }
            } else {
                sl.append("charge — (none) → +0m")
            }
            if let rest = restScore {
                if rest < DailyTargets.poorRestScore {
                    sl.append("rest \(rest) < \(DailyTargets.poorRestScore)"
                              + " → +\(Int(DailyTargets.sleepRestAdjPoorMin))m")
                } else if rest >= DailyTargets.greatRestScore {
                    sl.append("rest \(rest) ≥ \(DailyTargets.greatRestScore)"
                              + " → \(Int(DailyTargets.sleepRestAdjGreatMin))m")
                } else {
                    sl.append("rest \(rest) in \(DailyTargets.poorRestScore)–\(DailyTargets.greatRestScore - 1) → +0m")
                }
            } else {
                sl.append("rest — (none) → +0m")
            }
            switch readiness {
            case .rundown:
                sl.append("readiness rundown → +\(Int(DailyTargets.sleepReadinessAdjRundownMin))m")
            case .strained:
                sl.append("readiness strained → +\(Int(DailyTargets.sleepReadinessAdjStrainedMin))m")
            case .primed:
                sl.append("readiness primed → \(Int(DailyTargets.sleepReadinessAdjPrimedMin))m")
            case .balanced, .insufficient:
                sl.append("readiness \(readinessWord) → +0m")
            }
            let debt = max(0, -debtBalanceMin)
            let deadband = Int(DailyTargets.debtDeadbandMin)
            if debt > DailyTargets.debtDeadbandMin {
                let term = min(DailyTargets.sleepDebtCapMin, debt * DailyTargets.sleepDebtShare)
                sl.append("debt \(Int(debt))m > \(deadband)m → +min(\(Int(DailyTargets.sleepDebtCapMin)),"
                          + " \(String(format: "%.2f", DailyTargets.sleepDebtShare))×\(Int(debt))) = +\(Int(term.rounded()))m")
            } else {
                sl.append("debt \(Int(debt))m ≤ \(deadband)m → +0m")
            }
            sl.append("clamp(\(Int(DailyTargets.sleepFloorMin / 60))h…\(Int(DailyTargets.sleepCapMin / 60))h)"
                      + " → \(hm(sleepNeedMin))")
            out.append(sl.joined(separator: "\n"))
        }

        return out
    }
}
