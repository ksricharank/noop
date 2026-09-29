import Foundation

// MARK: - HorizonPlanner
//
// The synthesis card answers "how am I today". This answers the question that immediately follows it:
// "so what should I do in the next hour, the next three, the rest of the day?"
//
// Rule-based on purpose. The synthesis it sits under is rule-based too (banded thresholds → whole
// localized phrases), and matching that keeps the card speaking in one voice, costs nothing, works
// offline, and needs no API key. An LLM lane would also mean network calls on a view refresh.
//
// SCOPE — training and recovery only. The app measures recovery, load, sleep and the clock; it does not
// know when you last ate, drank, or had coffee. Lines about those would be time-of-day boilerplate
// dressed as personalisation, so they are deliberately absent: everything here is derived from a signal
// the app actually holds.
//
// HONESTY — a horizon with no real basis returns nil rather than filler. Mid-calibration the planner
// says so once and stops, instead of issuing three confident instructions off a baseline it does not
// have yet. Callers render only the horizons that came back.
//
// WORDING — must not collide with the synthesis one-liner or the ReadinessEngine verdict words
// (#1405: two halves of one card must not read as if they disagree). The verdict uses Push / Maintain /
// Rest and the synthesis leads with "You're primed…" / "Signals are down…", so this file avoids those
// openers and speaks in imperatives about a specific window of time.
//
// Pure + value-typed, no dependencies beyond Foundation: `HorizonPlannerTests` covers the banding with
// no app, no strap and no database.
public struct HorizonPlanner {

    // MARK: Output

    /// Which slice of the day a line addresses. Raw values are stable identifiers (a future Kotlin twin
    /// and any persisted layout must agree with them), never display text.
    public enum Horizon: String, Sendable, Equatable, CaseIterable {
        case hour = "1h"
        case threeHours = "3h"
        case sixHours = "6h"

        /// Hours ahead this horizon looks — the arithmetic behind "is bedtime inside this window".
        public var hoursAhead: Int {
            switch self {
            case .hour: return 1
            case .threeHours: return 3
            case .sixHours: return 6
            }
        }
    }

    /// One rendered horizon. `text` is plain English, matching `ReadinessEngine`'s convention for this
    /// package: the pure analytics layer returns locale-free copy and the app localizes at the display
    /// boundary. (The package declares no resource bundle, so `String(localized:)` here would find no
    /// catalog and silently return the key anyway.)
    public struct Plan: Sendable, Equatable, Identifiable {
        public let horizon: Horizon
        public let text: String
        public var id: String { horizon.rawValue }

        public init(horizon: Horizon, text: String) {
            self.horizon = horizon
            self.text = text
        }
    }

    /// Everything the planner reads, gathered by the caller so this stays free of Repository/GRDB.
    public struct Input: Sendable, Equatable {
        /// The readiness verdict already computed for the synthesis card — reused, never recomputed.
        public let level: ReadinessEngine.Level
        /// Effort/strain accrued so far today on NOOP's 0–21 axis, nil when today has no scored strain.
        public let strainSoFar: Double?
        /// Last night's sleep in minutes, nil when unknown.
        public let sleepMinutes: Int?
        /// Local hour of day, 0–23.
        public let hour: Int
        /// The user's target bedtime as an hour 0–23 (their wind-down setting), used to decide whether
        /// lights-out falls inside a horizon.
        public let bedtimeHour: Int

        public init(level: ReadinessEngine.Level, strainSoFar: Double?, sleepMinutes: Int?,
                    hour: Int, bedtimeHour: Int) {
            self.level = level
            self.strainSoFar = strainSoFar
            self.sleepMinutes = sleepMinutes
            self.hour = hour
            self.bedtimeHour = bedtimeHour
        }
    }

    // MARK: Tunables (named so the thresholds are auditable, like ReadinessEngine's)

    /// Effort at/above which today already counts as a trained day, so the planner stops suggesting a
    /// session and starts protecting the recovery from it. NOOP's Effort axis runs 0–21; 10 is the
    /// conventional "solid aerobic day" mark the strain scorer's own bands sit around.
    static let trainedTodayEffort: Double = 10
    /// Sleep below this (minutes) is treated as a short night regardless of what the recovery score did
    /// — 6 hours. Kept independent of the score because a single good-HRV night on 5 hours still argues
    /// against stacking hard work on top of it.
    static let shortSleepMinutes = 6 * 60
    /// Hour after which no horizon suggests starting a hard session, whatever the readiness: a late
    /// session eats the night this app exists to protect.
    static let lateTrainingCutoffHour = 20
    /// How close to bedtime (hours) the wind-down line takes over a horizon.
    static let windDownLeadHours = 2

    // MARK: Entry point

    /// Build the horizon lines for right now. Returns only the horizons that have something real to say,
    /// in `Horizon.allCases` order; an empty array is a legitimate answer and the caller should render
    /// nothing rather than a placeholder.
    public static func plan(_ input: Input) -> [Plan] {
        // Not enough history for a verdict means not enough for instructions off that verdict. Say it
        // once, at the nearest horizon, rather than three times or dressed up as advice.
        guard input.level != .insufficient else {
            return [Plan(horizon: .hour,
                         text: "Still building your baseline — hold off on plans from this card for now.")]
        }
        return Horizon.allCases.compactMap { horizon in
            line(for: horizon, input: input).map { Plan(horizon: horizon, text: $0) }
        }
    }

    // MARK: Per-horizon copy

    /// The line for one horizon, or nil when nothing about that window is worth asserting.
    ///
    /// Ordering inside each case is deliberate: the constraints that override everything (it is nearly
    /// bedtime; it is too late to train) are checked BEFORE the readiness-driven advice, so a primed
    /// evening never produces "great window for a hard session" at 22:00.
    static func line(for horizon: Horizon, input: Input) -> String? {
        let windowEnd = input.hour + horizon.hoursAhead
        let bedtimeInWindow = bedtimeFalls(within: windowEnd, bedtimeHour: input.bedtimeHour,
                                           leadHours: windDownLeadHours, fromHour: input.hour)
        let trainedAlready = (input.strainSoFar ?? 0) >= trainedTodayEffort
        let shortNight = (input.sleepMinutes ?? Int.max) < shortSleepMinutes
        let tooLateToTrain = input.hour >= lateTrainingCutoffHour

        switch horizon {
        case .hour:
            if bedtimeInWindow {
                return "Wind down now — screens off and lights out soon."
            }
            switch input.level {
            case .rundown:
                return "Stay off your feet where you can. No training this hour."
            case .strained:
                return "Keep it gentle — a walk is plenty for now."
            case .balanced, .primed:
                if trainedAlready {
                    return "You've done the work today. Refuel and let it settle."
                }
                if shortNight {
                    return "Short night behind you — ease into the day before anything hard."
                }
                return "Clear to move. Warm up properly if you're training soon."
            case .insufficient:
                return nil   // handled in `plan`; unreachable
            }

        case .threeHours:
            if bedtimeInWindow {
                return "Bedtime lands in this window — start slowing things down."
            }
            if tooLateToTrain {
                return "Too late for hard work — keep the evening easy."
            }
            switch input.level {
            case .rundown:
                return "Still a recovery window. Nothing that raises your heart rate much."
            case .strained:
                return "Low-intensity only if you do move — save the intensity for tomorrow."
            case .balanced:
                if trainedAlready {
                    return "Enough load banked today; anything more should be light."
                }
                return "A moderate session would sit well in here."
            case .primed:
                if trainedAlready {
                    return "Good work already logged — a second hard effort would cost you."
                }
                return "Your best window today for a hard session."
            case .insufficient:
                return nil
            }

        case .sixHours:
            // Six hours out, the useful thing to say is almost always about the night ahead — that is
            // where the next day's recovery is actually decided. Only say something else when bedtime is
            // still well outside the window.
            if bedtimeInWindow || windowEnd >= 21 {
                if shortNight {
                    return "Bank an earlier night than last night — that's the biggest lever you have."
                }
                if input.level == .rundown || input.level == .strained {
                    return "Protect tonight's sleep; it's what turns these signals around."
                }
                return "Aim for your usual lights-out to hold this state."
            }
            switch input.level {
            case .rundown, .strained:
                return "Reassess later — if signals lift, an easy session is the ceiling."
            case .balanced, .primed:
                return trainedAlready
                    ? "Rest of the day is for recovery, not more load."
                    : "Keep the evening free enough to train or wind down early."
            case .insufficient:
                return nil
            }
        }
    }

    // MARK: Time helpers

    /// Does bedtime (minus its wind-down lead) fall between now and `windowEnd`?
    ///
    /// `windowEnd` may exceed 23 — the caller adds hours to the current hour without wrapping — so this
    /// compares on that same un-wrapped scale, shifting a past-midnight bedtime forward by a day rather
    /// than wrapping the window back. Without that, an 18:00 read of a 23:00 bedtime and an 18:00 read
    /// of a 01:00 bedtime would look identical.
    ///
    /// The subtle case, and the one a test caught: being ALREADY INSIDE the wind-down run-up counts as
    /// true — it is not "today's bedtime has passed, wait for tomorrow's". At 21:00 with a 22:00 bedtime
    /// the wind-down began at 20:00, and the honest line for the next hour is "wind down", not the
    /// training advice that would otherwise fill the slot. Only once bedtime ITSELF is behind us does
    /// the next wind-down roll to tomorrow.
    static func bedtimeFalls(within windowEnd: Int, bedtimeHour: Int, leadHours: Int, fromHour: Int) -> Bool {
        var bed = bedtimeHour
        // A bedtime earlier in the clock than "now" is tomorrow's (23:00 now, 22:00 bedtime ⇒ tomorrow).
        if bed < fromHour { bed += 24 }
        let target = bed - leadHours
        // Already inside the run-up: the window is open right now, so it is trivially within reach.
        if target <= fromHour { return true }
        return target <= windowEnd
    }
}
