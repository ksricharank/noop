import Foundation
import StrandAnalytics

/// The four target derivations, one line each, with THAT DAY's actual inputs filled in (260901,
/// maintainer's ask: "the precise formula that was used", shown right after the four numbers and
/// before the LLM narrative — optional, so it collapses out of the way).
///
/// Pure and static so the wording is pinned by tests. Every line ENDS in the same number the strip
/// displays (the caller passes the values straight off the freshly built `LiveTargets`), so the
/// explanation can never drift from the targets: the components are re-derived through the SAME
/// public `DailyTargets` constants/functions the pricing used, and the tests assert the stated
/// arithmetic reproduces the passed-in target.
enum TargetsExplainer {

    /// Band name for a charge value, mirroring `DailyTargets`' two public thresholds.
    private static func chargeBand(_ charge: Int?) -> String {
        guard let charge else { return "no charge → maintain band" }
        if charge >= DailyTargets.pushChargeFloor { return "charge \(charge) → push band" }
        if charge <= DailyTargets.recoverChargeCeiling { return "charge \(charge) → recover band" }
        return "charge \(charge) → maintain band"
    }

    private static func readinessWord(_ readiness: ReadinessEngine.Level) -> String {
        String(describing: readiness)
    }

    private static func hm(_ minutes: Int) -> String {
        "\(minutes / 60)h\(String(format: "%02d", minutes % 60))"
    }

    /// The five lines: the shared session prescription first (effort and calories are both priced
    /// off it), then one line per target. `nil` targets simply omit their line — the section shows
    /// exactly what the strip shows.
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

        // ── The session both Effort and Cal price from ──────────────────────────────────────
        let restWord: String
        if let rest = restScore {
            if rest < DailyTargets.poorRestScore { restWord = "Rest \(rest) → notch down" }
            else if rest >= DailyTargets.greatRestScore { restWord = "Rest \(rest) → notch up" }
            else { restWord = "Rest \(rest) → no shift" }
        } else { restWord = "no Rest score → no shift" }
        if let session {
            let hrText = sessionHrBpm.map { " @ ~\($0) bpm (Karvonen: RHR + \(Int(session.hrrFraction * 100))% of HR reserve)" } ?? ""
            out.append("Session: \(chargeBand(charge)); readiness \(readinessWord(readiness)); "
                       + "\(restWord) ⇒ \(session.minutes) min\(hrText)")
        } else {
            out.append("Session: \(chargeBand(charge)); readiness \(readinessWord(readiness)); "
                       + "\(restWord) ⇒ rest day, no session")
        }

        // ── Effort: the frozen target is the session alone through the strain curve ─────────
        if let effortTarget {
            if let session {
                let trimp = session.edwardsZoneWeight * Double(session.minutes)
                out.append("Effort \(effortTarget)/100 stored: \(session.minutes) min × zone weight "
                           + "\(String(format: "%.1f", session.edwardsZoneWeight)) = "
                           + "\(Int(trimp)) TRIMP → strain curve (frozen: today's accrual not added)")
            } else {
                out.append("Effort 0: rest day — hold, don't add; anything you do shows as x/0")
            }
        }

        // ── Calories: a full resting day + the session through Keytel ───────────────────────
        // The resting part is stated as target − session (exact arithmetic on the displayed
        // numbers), not re-derived from the RMR model — so the line can never disagree with the
        // strip even across rounding.
        if let kcalTarget {
            if let session {
                let sessionKcal = DailyTargets.sessionKcal(session: session, profile: profile,
                                                           restingHr: restingHr)
                out.append("Cal \(kcalTarget): resting day ~\(kcalTarget - sessionKcal) kcal "
                           + "(RMR × 24 h) + session \(sessionKcal) kcal (Keytel at the session HR), "
                           + "rounded to \(Int(DailyTargets.calorieRoundKcal))")
            } else {
                out.append("Cal \(kcalTarget): the resting day alone (RMR × 24 h, rounded to "
                           + "\(Int(DailyTargets.calorieRoundKcal))) — rest asks nothing extra")
            }
        }

        // ── Steps: charge band base, readiness trim, clamped ────────────────────────────────
        if let stepsTarget {
            let trim: String
            switch readiness {
            case .rundown: trim = "readiness rundown → \(DailyTargets.stepsRundownAdj)"
            case .strained: trim = "readiness strained → \(DailyTargets.stepsStrainedAdj)"
            default: trim = "readiness \(readinessWord(readiness)) → no trim"
            }
            out.append("Steps \(stepsTarget): \(chargeBand(charge)) base "
                       + "(6k recover / 8k maintain / 10k push); \(trim); "
                       + "clamped \(DailyTargets.stepsFloorPerDay / 1000)k–\(DailyTargets.stepsCapPerDay / 1000)k")
        }

        // ── Sleep: population base ± charge/Rest/readiness, + capped debt share ─────────────
        if let sleepNeedMin {
            let baseMin = Int(AnalyticsEngine.Rest.populationNeedFloorHours(age: age) * 60.0)
            var adjs: [String] = []
            if let charge {
                if charge <= DailyTargets.recoverChargeCeiling {
                    adjs.append("+\(Int(DailyTargets.sleepChargeAdjRecoverMin))m charge")
                } else if charge < DailyTargets.pushChargeFloor {
                    adjs.append("+\(Int(DailyTargets.sleepChargeAdjMaintainMin))m charge")
                }
            }
            if let rest = restScore {
                if rest < DailyTargets.poorRestScore {
                    adjs.append("+\(Int(DailyTargets.sleepRestAdjPoorMin))m Rest")
                } else if rest >= DailyTargets.greatRestScore {
                    adjs.append("\(Int(DailyTargets.sleepRestAdjGreatMin))m Rest")
                }
            }
            switch readiness {
            case .rundown: adjs.append("+\(Int(DailyTargets.sleepReadinessAdjRundownMin))m readiness")
            case .strained: adjs.append("+\(Int(DailyTargets.sleepReadinessAdjStrainedMin))m readiness")
            case .primed: adjs.append("\(Int(DailyTargets.sleepReadinessAdjPrimedMin))m readiness")
            case .balanced, .insufficient: break
            }
            let debt = max(0, -debtBalanceMin)
            if debt > DailyTargets.debtDeadbandMin {
                let term = min(DailyTargets.sleepDebtCapMin, debt * DailyTargets.sleepDebtShare)
                adjs.append("+\(Int(term.rounded()))m debt (25% of \(Int(debt))m owed, cap "
                            + "\(Int(DailyTargets.sleepDebtCapMin))m)")
            }
            let adjText = adjs.isEmpty ? "no adjustments" : adjs.joined(separator: ", ")
            out.append("Sleep \(hm(sleepNeedMin)): \(hm(baseMin)) base (age-population need); "
                       + "\(adjText); clamped "
                       + "\(Int(DailyTargets.sleepFloorMin / 60))–\(Int(DailyTargets.sleepCapMin / 60))h")
        }

        return out
    }
}
