import Foundation

/// 260906: what the re-score path actually cost today — the attribution the per-pass lines cannot give.
///
/// The 260906 log showed the shape of the problem but not its cause: NINE full 21-night passes in one
/// day, two of them ~3 minutes (`175072 ms`, `168947 ms`), 25 light passes, and 41 lines reading
/// "deferred to a background task — a re-score is already outstanding from an earlier trigger". Against
/// `MetricKit … bg=151m` that makes re-scoring the leading candidate for the day's background CPU, but
/// the per-pass lines cannot settle it: each names its own trigger, and the 41 deferrals name none at
/// all, so "which trigger keeps starting work we then throw away" is exactly what is missing.
///
/// This counts the whole day per trigger — started, completed, deferred, and the milliseconds actually
/// burned, split by the app state the pass ran in. Foreground time is the user waiting; background time
/// is battery and a suspension risk (#1005), and the two call for opposite fixes, so they are never
/// summed into one number here.
///
/// It measures and attributes; it changes no scheduling decision. That is deliberate — the doctrine is
/// to ship cheap measurement on a path already running and let the NEXT log choose the fix, rather than
/// guess at a coalescing rule and find out in a week whether it helped. Every counter below is a
/// UserDefaults integer bumped on a path that was already logging a line.
///
/// DAY-KEYED AND PERSISTED, for the same reason `WidgetPublishStats` is: iOS kills and restores this app
/// many times a day, so a process-lifetime counter would only ever describe the last half hour — and a
/// re-score storm is precisely a whole-day phenomenon. Counters reset when the local day key changes.
/// Counts and durations only, no health data — the same privacy class as the rest of the log header.
@MainActor
enum RescoreStats {

    private enum K {
        static let day = "rss.day"
        /// Passes that got past every gate and began real work, keyed by trigger.
        static let startedPrefix = "rss.started."
        /// Passes that reached the end and wrote their watermark, keyed by trigger.
        static let donePrefix = "rss.done."
        /// Triggers that were DROPPED before doing anything — the "already outstanding" and
        /// "over the 20s a background wake can be relied on for" cases. This is the number that
        /// says how much of the churn is self-inflicted: a deferral is work we asked for and threw
        /// away, and 41 of them in a day is a scheduling problem, not a cost of scoring.
        static let deferredPrefix = "rss.deferred."
        /// Milliseconds spent in COMPLETED passes, split by where they ran. Background milliseconds
        /// are the battery bill; foreground milliseconds are latency the user felt.
        static let msFg = "rss.msFg"
        static let msBg = "rss.msBg"
        /// The single longest completed pass of the day, and its trigger — the 175 s outlier is what
        /// makes a background wake unreliable, and an average would hide it.
        static let maxMs = "rss.maxMs"
        static let maxTrigger = "rss.maxTrigger"
        /// #1681 debt non-settlements: a pass finished but a newer mark had already landed, so the
        /// debt survived and another full pass is guaranteed. A high count here IS the loop.
        static let debtUnsettled = "rss.debtUnsettled"
        /// Full passes that gave up mid-pass because the app backgrounded (260906).
        static let abandoned = "rss.abandoned"
    }

    private static var d: UserDefaults { .standard }

    /// Trigger names are a small closed set from `IntelligenceEngine` ("light-today", "idle",
    /// "post-offload", "forced"). Kept as a list so the formatter prints a stable order rather than
    /// whatever order a dictionary happens to yield, and so a renamed trigger shows up as a missing
    /// column instead of silently vanishing into an unread key.
    static let triggers = ["light-today", "idle", "post-offload", "forced"]

    private static func rollIfNeeded(now: Date) {
        let today = dayKey(now)
        guard d.string(forKey: K.day) != today else { return }
        d.set(today, forKey: K.day)
        for t in triggers + ["other"] {
            for p in [K.startedPrefix, K.donePrefix] { d.set(0, forKey: p + t) }
        }
        for c in DeferralCause.allCases { d.set(0, forKey: K.deferredPrefix + c.rawValue) }
        for k in [K.msFg, K.msBg, K.maxMs, K.debtUnsettled, K.abandoned] { d.set(0, forKey: k) }
        d.removeObject(forKey: K.maxTrigger)
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// An unknown trigger is bucketed rather than dropped: a renamed or newly-added trigger must still
    /// be counted, because an uncounted pass is exactly the blind spot this exists to close.
    private static func bucket(_ trigger: String) -> String {
        triggers.contains(trigger) ? trigger : "other"
    }

    private static func bump(_ key: String, now: Date) {
        rollIfNeeded(now: now)
        d.set(d.integer(forKey: key) + 1, forKey: key)
    }

    /// A pass passed every gate and began real work.
    static func recordStarted(trigger: String, now: Date = Date()) {
        bump(K.startedPrefix + bucket(trigger), now: now)
    }

    /// A pass completed. `ms` is the wall-clock the pass itself measured; `inBackground` is the state
    /// it RAN in, which is what decides whether the cost was battery or latency.
    static func recordFinished(trigger: String, ms: Int, inBackground: Bool, now: Date = Date()) {
        bump(K.donePrefix + bucket(trigger), now: now)
        let msKey = inBackground ? K.msBg : K.msFg
        d.set(d.integer(forKey: msKey) + max(0, ms), forKey: msKey)
        if ms > d.integer(forKey: K.maxMs) {
            d.set(ms, forKey: K.maxMs)
            d.set(bucket(trigger), forKey: K.maxTrigger)
        }
    }

    /// A trigger fired and was dropped before doing any work.
    ///
    /// Bucketed by CAUSE rather than by trigger name: the scheduler that makes this decision does not
    /// know which trigger woke it (the policy is a pure function of app state), and the cause is the
    /// more actionable half anyway — "already outstanding" ×41 and "locked" ×41 call for completely
    /// different fixes, whereas knowing both were "light-today" would not change either.
    ///
    /// The causes are the `RescoreBackgroundPolicy.Decision` reasons, reduced to a short stable key so
    /// the line stays readable and a reworded reason string cannot silently split one bucket in two.
    static func recordDeferred(cause: DeferralCause, now: Date = Date()) {
        bump(K.deferredPrefix + cause.rawValue, now: now)
    }

    /// Why a trigger was dropped. Deliberately coarse — these are the distinctions that change what to
    /// do, not every reason string the policy can print.
    enum DeferralCause: String, CaseIterable {
        /// A pass was already owed from an earlier trigger. Self-inflicted churn: work asked for, then
        /// thrown away. The dominant line in the 260906 log.
        case alreadyOutstanding = "outstanding"
        /// The phone was locked, so a pass would have run I/O-throttled and unseen.
        case locked
        /// The last completed pass measured longer than a background wake can be relied on for.
        case tooSlow = "too-slow"
        /// Inside the sleep window — scoring pauses for the night by design. Not churn; counted so the
        /// others can be read against a denominator that excludes it.
        case sleepWindow = "sleep-window"
        /// A backstop tick that simply did not run (nothing queued, nothing owed).
        case backstopSkipped = "backstop-skip"
    }

    /// #1681: a pass finished into a debt that had already been re-marked, guaranteeing another pass.
    static func recordDebtUnsettled(now: Date = Date()) { bump(K.debtUnsettled, now: now) }

    /// 260906: a full pass gave up because the app backgrounded mid-pass.
    ///
    /// This is a SAVING, not a fault — the 260906 log's single 4214 s pass was 82 % of all full-pass
    /// time, and it was a foreground-started pass that kept grinding after the app went away. A
    /// non-zero count here is the fix working; a zero count on a day with a multi-minute background
    /// pass means the abort is not firing.
    static func recordAbandoned(now: Date = Date()) { bump(K.abandoned, now: now) }

    /// Test seam: clear everything, including the day key, so a suite starts from zero.
    static func reset() {
        for t in triggers + ["other"] {
            for p in [K.startedPrefix, K.donePrefix] { d.removeObject(forKey: p + t) }
        }
        for c in DeferralCause.allCases { d.removeObject(forKey: K.deferredPrefix + c.rawValue) }
        for k in [K.day, K.msFg, K.msBg, K.maxMs, K.maxTrigger, K.debtUnsettled,
                  K.abandoned] { d.removeObject(forKey: k) }
    }

    /// One header line, or nothing when no pass ran today (a fresh install, or a quiet macOS session).
    /// Formatted only at export — the counters cost two integer writes each on paths already logging.
    static func summaryLines(now: Date = Date()) -> [String] {
        rollIfNeeded(now: now)
        var started = 0, done = 0, deferred = 0
        var parts: [String] = []
        for t in triggers + ["other"] {
            let s = d.integer(forKey: K.startedPrefix + t)
            let f = d.integer(forKey: K.donePrefix + t)
            started += s; done += f
            guard s > 0 else { continue }
            parts.append("\(t) \(f)/\(s)")
        }
        var causeParts: [String] = []
        for c in DeferralCause.allCases {
            let x = d.integer(forKey: K.deferredPrefix + c.rawValue)
            deferred += x
            if x > 0 { causeParts.append("\(c.rawValue) \(x)") }
        }
        guard started > 0 || deferred > 0 else { return [] }
        let bgS = d.integer(forKey: K.msBg) / 1000
        let fgS = d.integer(forKey: K.msFg) / 1000
        var line = "Re-score today: \(done)/\(started) done, \(deferred) dropped — "
            + "cpu bg=\(bgS)s fg=\(fgS)s"
        let maxMs = d.integer(forKey: K.maxMs)
        if maxMs > 0 {
            let who = d.string(forKey: K.maxTrigger) ?? "?"
            line += " · longest \(maxMs / 1000)s (\(who))"
        }
        let unsettled = d.integer(forKey: K.debtUnsettled)
        if unsettled > 0 { line += " · debt unsettled ×\(unsettled)" }
        let abandoned = d.integer(forKey: K.abandoned)
        if abandoned > 0 { line += " · gave up ×\(abandoned) (backgrounded mid-pass)" }
        var out = [line]
        if !parts.isEmpty { out.append("Re-score by trigger: " + parts.joined(separator: "  ")) }
        if !causeParts.isEmpty { out.append("Re-score dropped: " + causeParts.joined(separator: "  ")) }
        return out
    }
}
