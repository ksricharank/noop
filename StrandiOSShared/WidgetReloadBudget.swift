import Foundation

/// How a BACKGROUND WidgetKit reload request is paced so the faces stay as fresh as the daily budget
/// allows — and no fresher, because past the budget iOS answers by throttling everything.
///
/// ## What the 260906-2052 log established
///
/// A full day (`window=00:03:20-20:47:58`) measured, for the first time, what WidgetKit does with our
/// requests:
///
///     Widget background: publishes=235 reloads=66 dedup=169 unseen=0
///     Widget timelines:  requested=108 served=224 reqToBuild=169s avg / 946s max over 43
///
/// `reqToBuild` is the finding. When the app asks for a reload, the extension is not asked to build
/// for **169 s on average and up to 946 s** — so a glanced widget trails by ~3 min at best and ~16
/// min at worst, even though the app published immediately. That deferral is the budget pushing back:
/// **66 background reloads is at or over the ~40–70/day ceiling**, and an app over budget is not
/// refused, it is slowed down. Spending more would make the lag worse, not better.
///
/// (An earlier hour-old log read 18 background reloads and was quoted as headroom. It covered a
/// PARTIAL day; the full day is 66. The headroom was an artefact of reading a day-keyed counter
/// before the day had happened.)
///
/// ## Why coalescing is the lever, not a shorter interval
///
/// The strap syncs in tight bursts — the same log has **172 offloads that collapse into 58 genuinely
/// distinct moments** once bursts within two minutes are treated as one (mean burst 3.0, max 9), with
/// a median 9.8 min between bursts. Each sync in a burst lands rows, each genuinely moves a rendered
/// value, and each therefore spent its own budget reload. The dedup cannot help: those changes are
/// real, just redundant — the second, third and ninth sync of a burst are all superseded seconds
/// later.
///
/// Coalescing a burst into ONE reload of its FINAL state cuts spend by about two thirds AND improves
/// what lands on the face, because the reload that happens carries the newest values rather than the
/// first of nine. That is the rare case where the cheaper option is also the fresher one.
///
/// ## The policy
///
/// A background reload is admitted when either
///   * `minSpacing` has passed since the last one (the burst coalescer), or
///   * the change is URGENT — a value the wearer acts on moved enough to be worth a reload now.
///
/// and always subject to `dailyCap`, below the OS ceiling so we stay inside the range where requests
/// are honoured promptly rather than deferred.
///
/// Foreground reloads are NOT gated here at all: they are budget-exempt, so while the app is open the
/// widget should track it exactly.
///
/// Pure and `Sendable`-free by construction (static functions over injected state) so the whole policy
/// is unit-testable with no clock, no UserDefaults and no WidgetKit.
public enum WidgetReloadBudget {

    /// The daily cap on BACKGROUND reload requests.
    ///
    /// 48, not 70. The OS figure is a documented-nowhere range (~40–70) that varies with how the user
    /// interacts with the widget, and the 66 we spent bought us a 169 s average deferral. Sitting
    /// deliberately below the bottom of the range keeps requests in the promptly-served regime; the
    /// coalescer is what makes 48 enough, since 58 bursts × 1 reload each already fits far better than
    /// 172 syncs × 1 each.
    public static let dailyCap = 48

    /// Minimum spacing between background reloads — the burst coalescer.
    ///
    /// 120 s matches the burst structure the log actually shows (172 syncs → 58 clusters at a 2-minute
    /// window). Shorter re-admits the same burst; much longer would start merging genuinely separate
    /// moments, whose median gap is 9.8 min.
    public static let minSpacing: TimeInterval = 120

    /// Spacing for a change the wearer acts on, which may pre-empt the coalescer.
    ///
    /// Still spaced, so an urgent-flagged storm cannot bypass the budget entirely — it just gets to
    /// the front of the queue sooner than the 2-minute floor.
    public static let urgentMinSpacing: TimeInterval = 30

    /// What the caller knows about the change it is publishing.
    public struct Change: Equatable {
        /// The step count moved by at least this much — enough that the ring visibly turns.
        public var stepsDelta: Int = 0
        /// A cup of water was logged. Always urgent: it is a deliberate act, and the wearer looks at
        /// the widget to confirm it landed (the whole point of the strap double-tap).
        public var waterLogged: Bool = false
        /// A score (charge / effort / rest) changed. These move rarely and matter when they do.
        public var scoreChanged: Bool = false

        public init(stepsDelta: Int = 0, waterLogged: Bool = false, scoreChanged: Bool = false) {
            self.stepsDelta = stepsDelta
            self.waterLogged = waterLogged
            self.scoreChanged = scoreChanged
        }

        /// Whether this change deserves to pre-empt the coalescer.
        ///
        /// Deliberately narrow. Calories and effort drift continuously and re-render a barely-changed
        /// ring; steps only qualify past a threshold that is visible on a progress ring at widget size.
        public var isUrgent: Bool {
            waterLogged || scoreChanged || stepsDelta >= urgentStepsDelta
        }
    }

    /// The step move worth pre-empting for: ~2.5 % of a typical 8–10k target, about the smallest
    /// change that shifts a progress ring by a visible amount at widget size.
    public static let urgentStepsDelta = 250

    /// The verdict, so the log can say WHY a reload was or was not requested — a silent skip is the
    /// thing that made the original frozen-widget report unanswerable.
    public enum Decision: Equatable {
        case allow(urgent: Bool)
        /// Inside `minSpacing` and not urgent: the burst is being coalesced. The snapshot is still
        /// SAVED, so the next admitted reload (or the extension's own next build) carries it.
        case coalesced(secondsUntilNext: Int)
        /// The daily cap is spent. Deliberately NOT an error: the extension's own timeline policy
        /// keeps the face moving, and asking anyway would only deepen the throttle.
        case capped(usedToday: Int)
    }

    /// Decide whether to spend a background reload.
    ///
    /// - Parameters:
    ///   - change: what moved, for the urgency test.
    ///   - lastReloadAt: when a background reload was last requested (nil = none today).
    ///   - usedToday: background reloads already requested today.
    ///   - now: the clock.
    public static func decide(change: Change,
                       lastReloadAt: Date?,
                       usedToday: Int,
                       now: Date = Date()) -> Decision {
        // The cap comes first: past it, urgency is irrelevant — the request would be deferred anyway
        // and would deepen the throttle for everything after it.
        guard usedToday < dailyCap else { return .capped(usedToday: usedToday) }
        guard let last = lastReloadAt else { return .allow(urgent: change.isUrgent) }
        let elapsed = now.timeIntervalSince(last)
        // A clock that moved backwards (timezone, NTP) must not lock the gate shut for hours.
        guard elapsed >= 0 else { return .allow(urgent: change.isUrgent) }
        // The base rate is the burst coalescer. An URGENT change answers to that alone — a logged cup
        // must reach the face whatever the hour, and pacing an act the wearer just performed would be
        // the worst possible place to save a wake.
        var required = change.isUrgent ? urgentMinSpacing : minSpacing
        // Pacing is a BACKSTOP, not the primary rate: it engages only when the day's spend is running
        // AHEAD of the clock. Replaying the 260906 log against a flat 48 exhausted it at 19:00 and
        // left the evening stale — but making pace the primary rate over-corrects the other way (at
        // noon with a full budget, "remaining day ÷ remaining budget" is ~14 min, throttling harder
        // than the coalescer on a day that has spent nothing). A day has bursts and quiet stretches;
        // spending faster during a burst is correct, and only a RUN-RATE overshoot needs correcting.
        if !change.isUrgent, isAheadOfPace(usedToday: usedToday, now: now) {
            required = max(required, paceSpacing(usedToday: usedToday, now: now))
        }
        guard elapsed < required else { return .allow(urgent: change.isUrgent) }
        return .coalesced(secondsUntilNext: Int((required - elapsed).rounded(.up)))
    }

    /// Whether the day's spend is running AHEAD of an even burn across the waking day.
    ///
    /// The comparison is against how much SHOULD have been spent by now (`dayStartHour` →
    /// `dayEndHour` prorated). Behind or on pace ⇒ the coalescer alone applies, and an active morning
    /// is free to spend faster than average. Ahead ⇒ the pace term kicks in and slows the burn so the
    /// evening is not left with nothing.
    static func isAheadOfPace(usedToday: Int, now: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        guard hour < dayEndHour else { return false }   // past the day's end, spend freely
        guard hour >= dayStartHour else { return false } // small hours: nothing to protect yet
        let minute = calendar.component(.minute, from: now)
        let elapsedH = Double(hour - dayStartHour) + Double(minute) / 60.0
        let totalH = Double(dayEndHour - dayStartHour)
        let expected = Double(dailyCap) * (elapsedH / totalH)
        // A whole reload of slack, so a single early burst does not trip the backstop.
        return Double(usedToday) > expected + 1
    }

    /// Seconds that should separate reloads for the remaining allowance to cover the rest of the
    /// waking day — time left ÷ reloads left. Only consulted when `isAheadOfPace`.
    ///
    /// Past `dayEndHour` this is zero: a late-evening walk should still reach the face with whatever
    /// allowance is left, and reserving budget for the small hours would starve the hours that are
    /// actually glanced at.
    static func paceSpacing(usedToday: Int, now: Date, calendar: Calendar = .current) -> TimeInterval {
        let remaining = dailyCap - usedToday
        guard remaining > 0 else { return .infinity }
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        guard hour < dayEndHour else { return 0 }
        let secondsLeft = Double((dayEndHour - hour) * 3600 - minute * 60)
        return secondsLeft / Double(remaining)
    }

    /// When the widget starts being glanced at — the pace backstop's origin.
    public static let dayStartHour = 7

    /// When the widget stops being glanced at. 23:00 — late enough to cover an evening, early enough
    /// that the pace term does not reserve budget for the small hours.
    public static let dayEndHour = 23

    /// How long the extension should ask to be rebuilt in, given how much budget is left.
    ///
    /// The extension's own `.after` builds are NOT charged against the reload budget, but each is a
    /// process wake, and the log showed 224 served against 108 requested — roughly 116 self-scheduled
    /// builds a day. Stretching the interval once the app's own budget is spent is close to free: with
    /// no reloads left to request, a face that rebuilds itself every 10 minutes is the only thing
    /// keeping it current, and once even that is pointless (nothing is changing) a longer interval
    /// saves wakes.
    ///
    /// Kept SHORTER than the old flat 15 min while budget remains, so the self-scheduled builds fill
    /// the gaps between coalesced reloads — which is what actually makes the face feel live.
    public static func nextTimelineInterval(usedToday: Int, isDayComplete: Bool = false) -> TimeInterval {
        if isDayComplete { return 60 * 60 }        // the day is scored; nothing will move tonight
        let remaining = dailyCap - usedToday
        if remaining > 24 { return 10 * 60 }       // plenty left: rebuild often, cheaply
        if remaining > 0 { return 15 * 60 }        // getting thin: the old cadence
        return 30 * 60                             // budget spent: self-builds are all there is
    }
}
