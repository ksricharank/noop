import Foundation
import StrandAnalytics

/// The four target derivations with THAT DAY's actual inputs filled in (260901, maintainer's ask,
/// iterated twice same-day). Final format contract: FOUR blocks (Effort, Cal, Steps, Sleep — the
/// session ladder lives inside Effort), and EVERY line refers to a number and reads plainly to a
/// new person — no notch/zone/TRIMP/Karvonen/Keytel/RMR/clamp vocabulary, and "readiness" is
/// unpacked into the "body check": the signals' actual values against their 30-day baselines.
///
/// Pure and static so the wording is pinned by tests. Every block header carries the same number
/// the strip displays (the caller passes the values straight off the freshly built `LiveTargets`),
/// and the rungs re-derive through the SAME public `DailyTargets` constants/functions the pricing
/// used, so the derivation can never drift from the targets.
enum TargetsExplainer {

    private static func hm(_ minutes: Int) -> String {
        "\(minutes / 60)h\(String(format: "%02d", minutes % 60))"
    }

    /// The charge rung: today's Charge against the two published thresholds, naming the band in
    /// plain words. `pick` renders the value the band selected.
    private static func chargeRung(_ charge: Int?, low: String, mid: String, high: String) -> String {
        guard let charge else { return "Charge not scored yet → \(mid)" }
        if charge >= DailyTargets.pushChargeFloor {
            return "Charge \(charge) is high (≥\(DailyTargets.pushChargeFloor)) → \(high)"
        }
        if charge <= DailyTargets.recoverChargeCeiling {
            return "Charge \(charge) is low (≤\(DailyTargets.recoverChargeCeiling)) → \(low)"
        }
        return "Charge \(charge) is mid-range (\(DailyTargets.recoverChargeCeiling + 1)–"
             + "\(DailyTargets.pushChargeFloor - 1)) → \(mid)"
    }

    /// The "body check": the readiness signals' actual numbers vs their baselines, then the
    /// verdict in plain words — never the internal level name. Compact (no units) for the short
    /// form used by Steps/Sleep; full (with units) inside Effort.
    static func bodyCheck(_ read: ReadinessEngine.Readiness, compact: Bool) -> String {
        var parts: [String] = []
        for (key, label) in [("hrv", "HRV"), ("rhr", "resting HR")] {
            guard let sig = read.signals.first(where: { $0.key == key }),
                  case let .metric(value, baseline, unit, _)? = sig.evidenceData else { continue }
            let v = Int(value.rounded()), b = Int(baseline.rounded())
            let u = compact ? "" : unit
            switch sig.flag {
            case .good, .neutral:
                parts.append("\(label) \(v)\(u) ≈ your usual \(b)\(u)")
            case .watch, .bad:
                let dir = value > baseline ? "above" : "below"
                parts.append("\(label) \(v)\(u) \(dir) your usual \(b)\(u)")
            }
        }
        let verdict: String
        switch read.level {
        case .primed: verdict = "all strong"
        case .balanced: verdict = "all normal"
        case .strained: verdict = "one signal down"
        case .rundown: verdict = "several signals down"
        case .insufficient: verdict = "not enough history yet"
        }
        guard !parts.isEmpty else { return "body check: \(verdict)" }
        return "body check: \(parts.joined(separator: ", ")) → \(verdict)"
    }

    /// Minutes for a rung of the session ladder — the SAME arithmetic `sessionPrescription` uses
    /// (half the band's minutes / the band's / a third more, rounded to 5), or nil for "no workout".
    private static func ladderMinutes(base: Int, notch: Int) -> Int? {
        func rounded5(_ m: Double) -> Int { Int((m / 5).rounded() * 5) }
        switch notch {
        case 0: return nil
        case 1: return rounded5(Double(base) * 0.5)
        case 2: return base
        default: return rounded5(Double(base) * 4.0 / 3.0)
        }
    }

    /// A rung's consequence: what the workout now is, in minutes — or that there is none.
    private static func workoutText(_ minutes: Int?, changedFrom prior: Int?) -> String {
        guard let minutes else { return "no workout today" }
        guard let prior else { return "back on for \(minutes) min" }
        if minutes == prior { return "keep \(minutes) min" }
        return minutes < prior ? "shorten to \(minutes) min" : "step up to \(minutes) min"
    }

    /// The four blocks, one multi-line string per target. `nil` targets simply omit their block —
    /// the section shows exactly what the strip shows.
    static func lines(charge: Int?,
                      readiness: ReadinessEngine.Readiness,
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
                      debtBalanceMin: Double,
                      waterTargetML: Int? = nil,
                      effortForWater: Double? = nil) -> [String] {
        var out: [String] = []

        // ── EFFORT: the session ladder, then the workout priced as the day's effort score ─────
        // The ladder is re-walked with the same arithmetic `sessionPrescription` used, so each
        // rung can state the workout length as it stood at that point.
        let base: Int
        if let charge {
            base = charge >= DailyTargets.pushChargeFloor ? DailyTargets.pushSessionMinutes
                 : (charge <= DailyTargets.recoverChargeCeiling ? DailyTargets.recoverSessionMinutes
                                                                : DailyTargets.maintainSessionMinutes)
        } else { base = DailyTargets.maintainSessionMinutes }
        let notchAfterReadiness: Int
        switch readiness.level {
        case .rundown: notchAfterReadiness = 0
        case .strained: notchAfterReadiness = 1
        case .balanced, .insufficient: notchAfterReadiness = 2
        case .primed: notchAfterReadiness = 3
        }
        var finalNotch = notchAfterReadiness
        if let rest = restScore {
            if rest < DailyTargets.poorRestScore { finalNotch = max(finalNotch - 1, 0) }
            else if rest >= DailyTargets.greatRestScore { finalNotch = min(finalNotch + 1, 3) }
        }
        if let effortTarget {
            var e: [String] = ["EFFORT TARGET → \(effortTarget)"]
            e.append(chargeRung(charge,
                                low: "plan a \(DailyTargets.recoverSessionMinutes) min workout",
                                mid: "plan a \(DailyTargets.maintainSessionMinutes) min workout",
                                high: "plan a \(DailyTargets.pushSessionMinutes) min workout"))
            e.append("   (Charge ≤\(DailyTargets.recoverChargeCeiling) → \(DailyTargets.recoverSessionMinutes) min"
                     + " · \(DailyTargets.recoverChargeCeiling + 1)–\(DailyTargets.pushChargeFloor - 1)"
                     + " → \(DailyTargets.maintainSessionMinutes) min"
                     + " · ≥\(DailyTargets.pushChargeFloor) → \(DailyTargets.pushSessionMinutes) min)")
            let afterReadiness = ladderMinutes(base: base, notch: notchAfterReadiness)
            e.append(bodyCheck(readiness, compact: false) + " → "
                     + workoutText(afterReadiness, changedFrom: base))
            let afterRest = ladderMinutes(base: base, notch: finalNotch)
            if let rest = restScore {
                let restRung: String
                if rest < DailyTargets.poorRestScore {
                    restRung = "last night's Rest \(rest) is poor (below \(DailyTargets.poorRestScore))"
                } else if rest >= DailyTargets.greatRestScore {
                    restRung = "last night's Rest \(rest) is great (\(DailyTargets.greatRestScore) or above)"
                } else {
                    restRung = "last night's Rest \(rest) is mid-range (\(DailyTargets.poorRestScore)–"
                             + "\(DailyTargets.greatRestScore - 1))"
                }
                e.append(restRung + " → " + workoutText(afterRest, changedFrom: afterReadiness))
            } else {
                e.append("no Rest score last night → " + workoutText(afterRest, changedFrom: afterReadiness))
            }
            e.append("   (Rest below \(DailyTargets.poorRestScore) → shorten it"
                     + " · \(DailyTargets.greatRestScore) or above → lengthen it)")
            if let session {
                if let hr = sessionHrBpm {
                    let rhr = restingHr ?? 60
                    let hrmax = Int(DailyTargets.hrMax(age: age.map(Double.init)).rounded())
                    e.append("workout pace: ~\(hr) bpm — about \(Int(session.hrrFraction * 100))% of the"
                             + " way up from your resting HR \(rhr) toward your max ~\(hrmax)")
                }
                e.append("effort is the app's 0–100 score for a day's exercise:"
                         + " \(session.minutes) min at that pace scores \(effortTarget)")
                e.append("target = \(effortTarget) — today's effort so far isn't added in;"
                         + " finish the workout and you land on it")
            } else {
                e.append("target = 0 — anything you do still counts and shows as x/0")
            }
            out.append(e.joined(separator: "\n"))
        }

        // ── CAL: the resting day, plus the workout when there is one ─────────────────────────
        // The resting part is stated as target − session (exact arithmetic on the displayed
        // numbers, so the block can never disagree with the strip across rounding).
        if let kcalTarget {
            let w = profile.weightKg > 0 ? Int(profile.weightKg) : 70
            let h = profile.heightCm > 0 ? Int(profile.heightCm) : 170
            let a = profile.age > 0 ? Int(profile.age) : 30
            let round = Int(DailyTargets.calorieRoundKcal)
            var c: [String] = ["CALORIE TARGET → \(kcalTarget)"]
            if let session {
                let sessionKcal = DailyTargets.sessionKcal(session: session, profile: profile,
                                                           restingHr: restingHr)
                c.append("your body at rest burns ≈ \(kcalTarget - sessionKcal) kcal per 24h"
                         + " (from weight \(w)kg, height \(h)cm, age \(a))")
                let hrText = sessionHrBpm.map { " at ~\($0) bpm" } ?? ""
                c.append("the \(session.minutes) min workout\(hrText) burns ≈ \(sessionKcal) kcal more")
                c.append("\(kcalTarget - sessionKcal) + \(sessionKcal) = \(kcalTarget)"
                         + " (rounded to the nearest \(round) so the number doesn't pretend to be exact)")
            } else {
                c.append("your body at rest burns ≈ \(kcalTarget) kcal per 24h"
                         + " (from weight \(w)kg, height \(h)cm, age \(a))")
                c.append("no workout today → nothing added")
                c.append("target = \(kcalTarget)"
                         + " (rounded to the nearest \(round) so the number doesn't pretend to be exact)")
            }
            out.append(c.joined(separator: "\n"))
        }

        // ── STEPS: charge band base, body-check reduction, bounds ────────────────────────────
        if let stepsTarget {
            var st: [String] = ["STEP TARGET → \(stepsTarget)"]
            st.append(chargeRung(charge,
                                 low: "base \(DailyTargets.stepsBaseRecoverPerDay) steps",
                                 mid: "base \(DailyTargets.stepsBaseMaintainPerDay) steps",
                                 high: "base \(DailyTargets.stepsBasePushPerDay) steps"))
            st.append("   (Charge ≤\(DailyTargets.recoverChargeCeiling) → \(DailyTargets.stepsBaseRecoverPerDay)"
                      + " · \(DailyTargets.recoverChargeCeiling + 1)–\(DailyTargets.pushChargeFloor - 1)"
                      + " → \(DailyTargets.stepsBaseMaintainPerDay)"
                      + " · ≥\(DailyTargets.pushChargeFloor) → \(DailyTargets.stepsBasePushPerDay))")
            switch readiness.level {
            case .rundown:
                st.append(bodyCheck(readiness, compact: true) + " → \(DailyTargets.stepsRundownAdj)")
            case .strained:
                st.append(bodyCheck(readiness, compact: true) + " → \(DailyTargets.stepsStrainedAdj)")
            default:
                st.append(bodyCheck(readiness, compact: true) + " → no reduction")
            }
            st.append("   (several signals down → \(DailyTargets.stepsRundownAdj)"
                      + " · one down → \(DailyTargets.stepsStrainedAdj))")
            st.append("never set below \(DailyTargets.stepsFloorPerDay) or above"
                      + " \(DailyTargets.stepsCapPerDay) → \(stepsTarget)")
            out.append(st.joined(separator: "\n"))
        }

        // ── SLEEP: standard need, then the day's asks, then the sleep-ledger payback ─────────
        if let sleepNeedMin {
            let baseMin = Int(AnalyticsEngine.Rest.populationNeedFloorHours(age: age) * 60.0)
            var sl: [String] = ["SLEEP TARGET → \(hm(sleepNeedMin))"]
            sl.append("standard need for a \(age.map(String.init) ?? "typical adult")"
                      + "\(age != nil ? "-year-old" : ""): \(hm(baseMin))")
            // `sleepNeedTonightMin` adds nothing when Charge is unscored, so the nil rung says so
            // itself rather than borrowing the mid band's "+20" from `chargeRung`.
            if charge == nil {
                sl.append("Charge not scored yet → +0 min")
            } else {
                sl.append(chargeRung(charge, low: "+\(Int(DailyTargets.sleepChargeAdjRecoverMin)) min",
                                     mid: "+\(Int(DailyTargets.sleepChargeAdjMaintainMin)) min",
                                     high: "+0 min"))
            }
            sl.append("   (Charge ≤\(DailyTargets.recoverChargeCeiling) → +\(Int(DailyTargets.sleepChargeAdjRecoverMin))"
                      + " · \(DailyTargets.recoverChargeCeiling + 1)–\(DailyTargets.pushChargeFloor - 1)"
                      + " → +\(Int(DailyTargets.sleepChargeAdjMaintainMin)))")
            if let rest = restScore {
                if rest < DailyTargets.poorRestScore {
                    sl.append("last night's Rest \(rest) is poor (below \(DailyTargets.poorRestScore))"
                              + " → +\(Int(DailyTargets.sleepRestAdjPoorMin)) min")
                } else if rest >= DailyTargets.greatRestScore {
                    sl.append("last night's Rest \(rest) is great (\(DailyTargets.greatRestScore)+)"
                              + " → \(Int(DailyTargets.sleepRestAdjGreatMin)) min")
                } else {
                    sl.append("last night's Rest \(rest) is mid-range (\(DailyTargets.poorRestScore)–"
                              + "\(DailyTargets.greatRestScore - 1)) → +0 min")
                }
            } else {
                sl.append("no Rest score last night → +0 min")
            }
            sl.append("   (Rest below \(DailyTargets.poorRestScore) → +\(Int(DailyTargets.sleepRestAdjPoorMin))"
                      + " · \(DailyTargets.greatRestScore)+ → \(Int(DailyTargets.sleepRestAdjGreatMin)))")
            switch readiness.level {
            case .rundown:
                sl.append(bodyCheck(readiness, compact: true)
                          + " → +\(Int(DailyTargets.sleepReadinessAdjRundownMin)) min")
            case .strained:
                sl.append(bodyCheck(readiness, compact: true)
                          + " → +\(Int(DailyTargets.sleepReadinessAdjStrainedMin)) min")
            case .primed:
                sl.append(bodyCheck(readiness, compact: true)
                          + " → \(Int(DailyTargets.sleepReadinessAdjPrimedMin)) min")
            case .balanced, .insufficient:
                sl.append(bodyCheck(readiness, compact: true) + " → +0 min")
            }
            sl.append("   (several signals down → +\(Int(DailyTargets.sleepReadinessAdjRundownMin))"
                      + " · one down → +\(Int(DailyTargets.sleepReadinessAdjStrainedMin))"
                      + " · all strong → \(Int(DailyTargets.sleepReadinessAdjPrimedMin)))")
            let debt = max(0, -debtBalanceMin)
            let deadband = Int(DailyTargets.debtDeadbandMin)
            if debt > DailyTargets.debtDeadbandMin {
                let term = Int(min(DailyTargets.sleepDebtCapMin, debt * DailyTargets.sleepDebtShare).rounded())
                sl.append("you're \(Int(debt)) min short on sleep lately → pay back a quarter tonight:"
                          + " +\(term) min (never more than +\(Int(DailyTargets.sleepDebtCapMin)))")
            } else {
                sl.append("your sleep ledger is even (within \(deadband) min) → +0 min")
            }
            sl.append("never set below \(Int(DailyTargets.sleepFloorMin / 60))h or above"
                      + " \(Int(DailyTargets.sleepCapMin / 60))h → \(hm(sleepNeedMin))")
            out.append(sl.joined(separator: "\n"))
        }

        // ── WATER: a body-size baseline, plus a bump for how hard the day has been ─────────
        if let waterTargetML {
            let goalCups = max(1, HydrationGoal.cups(fromML: Double(waterTargetML)))
            let baseline = HydrationGoal.baselineForSex(profile.sex)
            let bump = HydrationGoal.effortBump(effort: effortForWater)
            var w: [String] = ["WATER TARGET → \(goalCups) cups"]
            w.append("baseline for your body: \(baseline) ml"
                     + " (\(HydrationGoal.cups(fromML: Double(baseline))) cups)")
            if bump > 0 {
                w.append("today's effort \(Int((effortForWater ?? 0).rounded())) adds \(bump) ml"
                         + " — harder days need more")
            } else {
                w.append("no effort logged yet → +0 ml   (a hard day adds up to"
                         + " \(HydrationGoal.maxEffortBumpML) ml)")
            }
            w.append("\(baseline) + \(bump) = \(waterTargetML) ml, rounded to the nearest"
                     + " \(HydrationGoal.roundToML)")
            w.append("shown in cups at \(HydrationGoal.cupML) ml each → \(goalCups) cups")
            out.append(w.joined(separator: "\n"))
        }

        return out
    }
}
