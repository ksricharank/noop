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

    /// The daily cap on BACKGROUND reload requests — RETIRED 260907, kept only as a sanity ceiling.
    ///
    /// ## The 16.16 theory, and its falsification
    ///
    /// 16.16 set this to 48 on the theory that the 169 s `reqToBuild` deferral was WidgetKit throttling
    /// us for spending 66 background reloads against a ~40–70/day budget. The prediction was explicit:
    /// spend less, get served faster.
    ///
    /// The 260907 log falsified it. Spend fell to 42 and the deferral got WORSE:
    ///
    ///     before (66 spent): reqToBuild=169s avg /  946s max
    ///     after  (42 spent): reqToBuild=186s avg / 2044s max
    ///
    /// So WidgetKit was never punishing us for 66. The deferral is iOS scheduling on its own terms —
    /// system load, thermal state, its own heuristics — and promptness cannot be bought with restraint.
    /// Holding a tight cap cost freshness and bought nothing measurable.
    ///
    /// ## Why a ceiling still exists at all
    ///
    /// Not as a budget. The COALESCER is the real limit now: the strap produces ~58 distinct sync
    /// moments a day, so replaying any cap above ~70 yields the same ~62 reloads — there is simply
    /// nothing left to spend on. This number is therefore a guard against a FUTURE change that starts
    /// publishing far more often (a new high-frequency hook, a regressed dedup), not a rationing of
    /// today's traffic. 200 is far above anything the current publish paths can generate, so it never
    /// binds in normal operation while still bounding a runaway.
    ///
    /// If it ever DOES bind, that is a signal worth reading rather than a limit worth raising: the
    /// `capped=` counter appearing in a log means something upstream started publishing unexpectedly.
    public static let dailyCap = 200

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
        let required = change.isUrgent ? urgentMinSpacing : minSpacing
        // 260907: the pace backstop is GONE with the tight cap it existed to ration.
        //
        // It was there so a busy morning could not exhaust 48 by 19:00 and leave the evening stale.
        // With the cap retired to a runaway guard (see `dailyCap`) there is no scarce allowance to
        // spread, and keeping the term would throttle a normal day for no benefit — it would be the
        // same mistake as the tight cap itself, one layer down. The coalescer alone now sets the rate,
        // which is what the evidence supports: the deferral is iOS's, not ours to buy off.
        //
        // `isAheadOfPace` / `paceSpacing` are retained (and still tested) because they are the right
        // shape if a real budget ever has to come back — but nothing consults them.
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
        // 260907: keyed on ABSOLUTE spend, not on headroom under the cap. The old form was
        // `dailyCap - usedToday`, which with the cap retired to 200 would have reported "plenty left"
        // every hour of every day and never reached the longer intervals at all — a threshold silently
        // detuned by a change somewhere else. Absolute counts cannot drift that way.
        //
        // The 260907 log served 212 timelines against 58 requested, so these self-builds — which are
        // NOT charged against anything — are what actually keeps the face current. 10 minutes while
        // the day is active is the useful cadence; it stretches only once the day has produced enough
        // reloads that little is still moving.
        if usedToday < 60 { return 10 * 60 }
        if usedToday < 100 { return 15 * 60 }
        return 30 * 60
    }
}
