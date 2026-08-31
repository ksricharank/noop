#if os(iOS)
import Foundation
import ActivityKit

/// Live Activity attributes for an active live-HR / workout session. Shared between the app (which
/// starts/updates the activity) and the widget extension (which renders it on the Lock Screen and in
/// the Dynamic Island).
public struct NOOPActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var bpm: Int?
        public var recovery: Int?
        public var bonded: Bool
        // Effort / strain on NOOP's 0–100 axis (#446) — one more stat in the Dynamic Island expanded
        // region. OPTIONAL with a nil default so an activity started by an older build still decodes.
        public var effort: Int?
        // The Rest SCORE (0–100, the day anchor's sleep-performance composite — the SAME metric the
        // app's Today "Rest" tile shows; it briefly carried resting HR, which could never match that
        // tile under the same label). Same nil-default decode-compatibility rule as `effort`.
        public var rest: Int?
        // Whether `bpm` is a LIVE beat (true) or a window average / frozen value. The widget marks
        // live values with a tilde ("~72", the wavering live reading) and leaves averages as the
        // plain settled number — chosen deliberately in that direction, so a card that freezes with
        // the phone (no pushes can reach it) is left holding the honest plain form, never the live
        // marker. Optional with a nil default (= no marker) so older builds' activities still decode.
        public var live: Bool?
        // The three-pillar targets (deterministic, `DailyTargets` — the same numbers the coach
        // synthesis cites). All optional with nil defaults for the same decode-compatibility reason
        // as `effort`: nil simply drops the denominator / column on the card.
        /// HISTORY: briefly the HR column's denominator (a calm ceiling). Retired 260830 — the
        /// maintainer replaced the threshold with the live autonomic read (`breathe`) — but the
        /// field stays declared so activities written by the 268/269 builds still decode.
        public var hrCeiling: Int?
        /// HISTORY: the breathe cue (true = non-metabolic HRV dip → red HR digits) lived one build
        /// (270–271) and was retired 260830 with the HR column itself — the cue moved to the stress
        /// check-in's strap buzz + screen notification. Declared so 270/271 activities still decode.
        public var breathe: Bool?
        /// Today's effort, PRE-FORMATTED on the user's chosen scale by the controller (the widget
        /// extension can't read the scale preference) — the Effort column's numerator, and the
        /// compact/minimal slots' whole payload.
        public var effortDisplay: String?
        /// Today's effort target, same pre-formatted scale — the Effort column's denominator.
        public var effortTargetDisplay: String?
        /// TOTAL calories so far today (resting metabolism included).
        public var kcal: Int?
        /// Today's TOTAL-calorie target (a full resting day + the prescribed session) — the Cal
        /// column's denominator.
        public var kcalTarget: Int?
        /// Minutes of sleep to target tonight — the Sleep column ("8h05").
        public var sleepNeedMin: Int?

        public init(bpm: Int?, recovery: Int?, bonded: Bool, effort: Int? = nil, rest: Int? = nil,
                    live: Bool? = nil, effortDisplay: String? = nil,
                    effortTargetDisplay: String? = nil, kcal: Int? = nil,
                    kcalTarget: Int? = nil, sleepNeedMin: Int? = nil) {
            self.bpm = bpm
            self.recovery = recovery
            self.bonded = bonded
            self.effort = effort
            self.rest = rest
            self.live = live
            self.hrCeiling = nil
            self.breathe = nil
            self.effortDisplay = effortDisplay
            self.effortTargetDisplay = effortTargetDisplay
            self.kcal = kcal
            self.kcalTarget = kcalTarget
            self.sleepNeedMin = sleepNeedMin
        }
    }

    /// Static title shown for the session.
    public var title: String

    public init(title: String = "HR") {
        self.title = title
    }
}
#endif
