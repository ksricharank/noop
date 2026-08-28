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

        public init(bpm: Int?, recovery: Int?, bonded: Bool, effort: Int? = nil, rest: Int? = nil) {
            self.bpm = bpm
            self.recovery = recovery
            self.bonded = bonded
            self.effort = effort
            self.rest = rest
        }
    }

    /// Static title shown for the session.
    public var title: String

    public init(title: String = "HR") {
        self.title = title
    }
}
#endif
