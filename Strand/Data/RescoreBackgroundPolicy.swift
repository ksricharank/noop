import Foundation

/// Whether a re-score triggered while the app is BACKGROUNDED should start now or be handed to a
/// background-processing task that has time to finish it.
///
/// #1538: a completed offload rescores immediately, and on iOS that routinely happens while the app is
/// backgrounded — it stays alive as a `bluetooth-central` to receive the offload in the first place. But
/// `analyzeRecent` is all-or-nothing: pass 1 writes nothing, every store write happens after both loops,
/// and the watermark advances only at the very end so an interrupted run can never mark unscored data as
/// scored. On a heavy install the pass measured **474,778 ms** — nearly eight minutes. iOS suspends the
/// process long before that, so the work is lost in full.
///
/// The lost work is not the worst of it. Because the watermark never advanced, the NEXT trigger still saw
/// `newData=yes` and started another full pass, which was killed in turn. The reporter's log shows exactly
/// that: every offload after 05:40:31 reported `caught up` with nothing new to fetch, yet two later ticks
/// still read `newData=yes`. It is a livelock — the pass cannot finish, and failing to finish is what
/// guarantees it will be attempted again. The score appeared 1 h 57 m after the data was complete, and only
/// because the app happened to stay foregrounded for eight unbroken minutes.
///
/// So this decides, before spending anything: is this a pass that can plausibly finish here?
///
/// Deliberately NOT a fix for how long the pass takes. A cold process still re-scores every night in the
/// window, because the per-day reuse cache is in-memory and starts empty (`IntelligenceEngine.dayScanCache`).
/// This changes only WHERE the work runs and how often a doomed attempt is paid for. Making the pass itself
/// cheap across a process restart is the other half of #1538 and is not attempted here.
enum RescoreBackgroundPolicy {

    /// What a background-initiated re-score should do.
    enum Decision: Equatable {
        /// Start the pass now, under an execution assertion.
        case run
        /// Do not start it; leave the work marked pending and let a background-processing task (or the
        /// next foreground) run it. The reason is logged verbatim to the strap log — #1538 was three
        /// nights of chasing BLE precisely because the log did not say why scoring had not happened.
        case deferToBackgroundTask(reason: String)
        /// Do not start it and do NOT hand it to a background task either; leave the work marked pending
        /// for the first trigger after the sleep window ends (the offload cadence resumes scoring on its
        /// own) or the next foreground, whichever comes first. Sleep-window deferrals get their own case
        /// because escalating them to a `BGProcessingTask` would undo the point: iOS favours idle for
        /// processing tasks, and "idle" on a phone worn to bed is 3 a.m. — the pass would run mid-night
        /// after all, just under a different trigger (13 of the 22 passes in the overnight log that
        /// motivated this arrived exactly that way). The reason is logged verbatim, same as the case above.
        case deferUntilSleepWindowEnds(reason: String)
    }

    /// What a background execution assertion is worth relying on, in seconds.
    ///
    /// `beginBackgroundTask` buys roughly 30 s on current iOS, and that figure is a courtesy rather than a
    /// contract — it shrinks under memory pressure and in Low Power Mode. 20 s leaves headroom for the
    /// assertion to be granted late and for the pass's own store writes to land, since being killed
    /// mid-write is the one outcome worth spending real caution to avoid.
    static let backgroundBudgetSeconds: Double = 20

    /// Minimum spacing between LOCKED `BGProcessingTask` settles, in seconds.
    ///
    /// The 260829 logs showed why one is needed: with the phone locked and a +N locked sync landing new
    /// rows every ~5 minutes, EVERY settle completes into "debt NOT settled" (#1681 — a newer mark always
    /// arrives mid-pass), every deferral re-arms the processing task, and the task fires roughly every
    /// half hour. 38 full passes in one day, ~2 hours of I/O-throttled wall time (one pass ran 54
    /// minutes), all of it invisible — a locked phone shows nobody the result. The passes DO persist
    /// scores, so one locked settle is worth having (it is what paints the home-screen widget after the
    /// sleep window ends before the first unlock); a treadmill of them is pure heat. Three hours keeps
    /// the morning paint and caps the waste at a few passes a day; the next unlock still settles
    /// immediately through the foreground path, which this spacing never touches.
    static let lockedSettleSpacingSeconds: Double = 3 * 3600

    /// What a fired background-processing settle should do (`RescoreBackgroundScheduler.register`).
    ///
    /// Distinct from `Decision`, which paces the TRIGGER side (a completed offload deciding whether to
    /// run or defer). This paces the SETTLE side — the processing task that the deferrals escalate to —
    /// which previously ran unconditionally and was the door the treadmill walked through.
    enum SettleDecision: Equatable {
        /// Run the deferred pass now.
        case run
        /// Skip this wake; re-arm the task no earlier than `retryAfterSeconds` from now (nil = the
        /// scheduler's default pacing). The reason is logged verbatim to the strap log.
        case skip(reason: String, retryAfterSeconds: Double?)
    }

    /// Decide whether a fired background settle should actually run the pass.
    ///
    /// - An UNLOCKED settle always runs: it is the original #1538 escalation (a heavy pass that a
    ///   bluetooth-central wake could not finish gets minutes here), and unlocked means the result can
    ///   be seen.
    /// - Inside the sleep window it never runs — same reasoning as `Decision.deferUntilSleepWindowEnds`:
    ///   a processing task favours idle, and idle on a phone worn to bed is mid-night. The task that
    ///   fires anyway (one scheduled before the window opened) re-arms for just past the window's end.
    /// - Locked outside the window, it runs at most once per `spacingSeconds`: locked passes are
    ///   I/O-throttled and unseen, and under a +N locked sync cadence they can never settle the debt
    ///   (new data always lands mid-pass), so each extra one is waste. The one it does allow is the
    ///   morning widget paint.
    ///
    /// `secondsSinceLastLockedSettle` nil (no locked settle has ever completed) or unreadable
    /// (non-finite / negative, e.g. a clock change) means "unknown", and unknown runs — refusing to
    /// score on a value we cannot read would be the worse failure, same rule as the measured-cost gate.
    static func settleDecision(isLocked: Bool,
                               inSleepWindow: Bool,
                               secondsSinceLastLockedSettle: Double?,
                               secondsUntilSleepWindowEnd: Double?,
                               spacingSeconds: Double = lockedSettleSpacingSeconds) -> SettleDecision {
        guard isLocked else { return .run }
        if inSleepWindow {
            return .skip(
                reason: "inside the sleep window — the first post-window settle (or the next unlock) runs it",
                retryAfterSeconds: secondsUntilSleepWindowEnd)
        }
        if let since = secondsSinceLastLockedSettle, since.isFinite, since >= 0,
           since < spacingSeconds {
            return .skip(
                reason: "a locked settle already ran \(Int((since / 60).rounded()))m ago — locked passes "
                        + "are I/O-throttled and unseen, so they run at most every "
                        + "\(Int(spacingSeconds / 60))m (the next unlock settles immediately)",
                retryAfterSeconds: spacingSeconds - since)
        }
        return .run
    }

    /// - Parameters:
    ///   - isBackground: whether the app is currently backgrounded. A foregrounded app is never deferred:
    ///     the user is looking at the screen, there is no suspension deadline, and the existing behaviour
    ///     is correct.
    ///   - inSleepWindow: whether the local wall clock sits inside the user's sleep window (the reused
    ///     quiet-hours window, editable in Settings). The sleep window is where the overnight re-score
    ///     storm lives: the strap banks all night, every ~10-minute offload lands new data, and each
    ///     landing triggers a full pass that nobody can see the result of — 22 passes and ~15 minutes of
    ///     heavy CPU in the motivating night's log, most of it prep reads contending with the very
    ///     offloads that triggered them. In-window ⇒ defer, whatever the measured cost: the first trigger
    ///     AFTER the window (the offload cadence resumes scoring on its own, locked or not) runs ONE
    ///     coalesced pass over everything the night banked. Deliberately a clock window and NOT the
    ///     phone's lock state: daytime pocket-time was deferring passes too and then settling on every
    ///     unlock, which both staled the day and ran a pass per unlock. A wall-clock window means daytime
    ///     scoring follows the offload cadence exactly as it always did, whatever the lock state. Checked
    ///     before the owed/measured rules so an in-window deferral never schedules a background task
    ///     (see `Decision.deferUntilSleepWindowEnds`).
    ///   - rescoreAlreadyOwed: a re-score is outstanding — either a pass marked itself started and never
    ///     marked itself finished (it was killed; the mark survives process death, which is the point,
    ///     because the killed process gets no chance to record anything) or an earlier trigger already
    ///     deferred one. This is the self-correcting part — the FIRST background attempt on an install we
    ///     know nothing about is allowed to run, and from then on the work escalates instead of being
    ///     re-killed on every offload.
    ///   - owedByWindowDeferralOnly: the outstanding debt exists ONLY because sleep-window deferrals
    ///     recorded it — no pass was ever attempted, so there is no can't-finish evidence and the owed
    ///     rule steps aside: the first post-window trigger runs the pass (still subject to the measured
    ///     rule), and that run is the morning settle. False for any debt with attempt evidence behind
    ///     it, which keeps the full #1538 escalation.
    ///   - isDeviceLocked: whether the phone is locked (protected data unavailable). A backgrounded
    ///     trigger on a LOCKED phone defers whatever the measurement says, closing the measured rule's
    ///     trailing-edge hole: every fast foreground pass resets `lastCompletedPassSeconds` to under a
    ///     second, so the FIRST post-lock trigger was waved through — and a locked background pass runs
    ///     I/O-throttled (the 260827 log's two: 56 s and 66 s for work a foreground pass does in ~1 s),
    ///     which is also what re-teaches the rule, one wasted throttled pass per pocket-in. Locked means
    ///     nobody can see the result, so nothing is staled by waiting for the processing task or the
    ///     next unlock's forced pass. Distinct from the sleep-window rule's deliberate lock-state
    ///     rejection: THAT case must not schedule a background task at all (it would run mid-night);
    ///     this one wants exactly that escalation, and its debt coalesces every later locked trigger
    ///     into the one settle — not a pass per unlock.
    ///   - lastCompletedPassSeconds: how long the last pass that ran to completion took, or nil if none
    ///     has. Measured rather than assumed — the cost varies by more than an order of magnitude with
    ///     history size, and a fixed guess would either defer installs that finish comfortably or wave
    ///     through ones that never could.
    ///   - budgetSeconds: see `backgroundBudgetSeconds`; a parameter so the tests can state the boundary
    ///     rather than inherit it.
    static func decide(isBackground: Bool,
                       inSleepWindow: Bool,
                       rescoreAlreadyOwed: Bool,
                       owedByWindowDeferralOnly: Bool,
                       isDeviceLocked: Bool = false,
                       lastCompletedPassSeconds: Double?,
                       budgetSeconds: Double = backgroundBudgetSeconds) -> Decision {
        guard isBackground else { return .run }

        // Before the owed/measured rules on purpose: an in-window deferral must resolve to the first
        // post-window trigger, never to a background task — falling through to the owed rule would
        // schedule one.
        if inSleepWindow {
            return .deferUntilSleepWindowEnds(
                reason: "inside the sleep window — scoring pauses for the night and settles once after it ends (or on next foreground)")
        }

        // A debt with ATTEMPT EVIDENCE behind it (a killed pass, or one the measured rule escalated)
        // keeps the #1538 rule: don't re-attempt in the background what the phone has already proved it
        // cannot finish there. A debt that exists ONLY because the sleep window deferred it was never
        // attempted at all, so it falls through — the first post-window trigger runs it, subject to the
        // measured rule below, and that pass IS the morning settle.
        if rescoreAlreadyOwed, !owedByWindowDeferralOnly {
            return .deferToBackgroundTask(
                reason: "a re-score is already outstanding from an earlier trigger")
        }

        // Locked ⇒ defer, whatever the measurement says (see the `isDeviceLocked` parameter doc): the
        // measured rule below only knows the LAST pass's cost, and after any fast foreground pass it
        // would wave the first post-lock trigger through into a ~60× I/O-throttled pass nobody can see.
        if isDeviceLocked {
            return .deferToBackgroundTask(
                reason: "the phone is locked — a locked background pass runs I/O-throttled and unseen; "
                        + "the background task or the next unlock settles it")
        }

        // Only a FINITE, positive measurement can justify deferring. A nil (nothing has ever completed),
        // a zero, or a NaN/infinity from a corrupted default all mean "unknown", and unknown must fall
        // through to running: refusing to score on the strength of a value we cannot read would be a far
        // worse failure than one wasted pass.
        if budgetSeconds > 0,
           let measured = lastCompletedPassSeconds,
           measured.isFinite, measured > 0,
           measured > budgetSeconds {
            return .deferToBackgroundTask(
                reason: "last completed pass took \(Int(measured.rounded()))s, over the "
                        + "\(Int(budgetSeconds.rounded()))s a background wake can be relied on for")
        }

        return .run
    }
}
