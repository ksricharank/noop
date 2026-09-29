import Foundation

/// Whether a re-score triggered while the app is BACKGROUNDED should start now or be handed to a
/// background-processing task that has time to finish it.
///
/// #1538: a completed offload rescores immediately, and on iOS that routinely happens while the app is
/// backgrounded — it stays alive as a `bluetooth-central` to receive the offload in the first place. But
/// `analyzeRecent` is all-or-nothing: pass 1 writes nothing, every store write happens after both loops,
/// and the watermark advances only at the very end so an interrupted run can never mark unscored data as
/// scored. On a heavy install the pass measured **474,778 ms** — nearly eight minutes. iOS ends the
/// process long before that, so the work is lost in full.
///
/// The lost work is not the worst of it. Because the watermark never advanced, the NEXT trigger still saw
/// `newData=yes` and started another full pass, which was killed in turn. The reporter's log shows exactly
/// that: every offload after 05:40:31 reported `caught up` with nothing new to fetch, yet two later ticks
/// still read `newData=yes`. It is a livelock — the pass cannot finish, and failing to finish is what
/// guarantees it will be attempted again. The score appeared 1 h 57 m after the data was complete, and only
/// because the app happened to stay foregrounded for eight unbroken minutes.
///
/// What ends those passes is the background CPU limit, not suspension (see `backgroundRestPerWorkSecond`):
/// a suspended pass resumes on the next wake, a killed one does not. A backgrounded pass therefore paces
/// itself under that limit, and this decides only whether one should start here at all.
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
        /// `cause` is the same decision in one stable token, for the day tally (`RescoreStats`). The
        /// reason string stays the human-readable log line; a token beside it means a reworded reason
        /// cannot silently split one counter bucket into two.
        case deferToBackgroundTask(reason: String, cause: RescoreStats.DeferralCause)
        /// Do not start it and do NOT hand it to a background task either; leave the work marked pending
        /// for the first trigger after the sleep window ends (the offload cadence resumes scoring on its
        /// own) or the next foreground, whichever comes first. Sleep-window deferrals get their own case
        /// because escalating them to a `BGProcessingTask` would undo the point: iOS favours idle for
        /// processing tasks, and "idle" on a phone worn to bed is 3 a.m. — the pass would run mid-night
        /// after all, just under a different trigger (13 of the 22 passes in the overnight log that
        /// motivated this arrived exactly that way). The reason is logged verbatim, same as the case above.
        case deferUntilSleepWindowEnds(reason: String, cause: RescoreStats.DeferralCause)
    }

    /// How long a backgrounded pass rests per second of work it just did.
    ///
    /// What actually killed the background passes was CPU, not time: iOS terminates a background process
    /// that holds more than 80% CPU over 60 s (`cpu_resource_fatal`). A cold pass is roughly 144 s of
    /// near-continuous CPU on a large install, so every overnight attempt was killed about 52 s in — 26 kills
    /// on one phone in five nights, each leaving the debt for the next attempt to be killed on. Resting as
    /// long as it worked holds the pass near 50%. A suspension between rests is harmless: the pass is not
    /// killed by it, it resumes on the next wake, so a pass longer than any single wake still completes.
    static let backgroundRestPerWorkSecond: Double = 1.0

    /// The longest single rest. Work measured on the uptime clock can include a suspension the process
    /// spent mid-unit; resting for all of it would stall a pass that has already been idle.
    static let maxBackgroundRestSeconds: Double = 30

    /// How much work a backgrounded pass does between rests.
    ///
    /// Resting after every unit (every night) turned out to be the expensive part. A rest is a `Task.sleep`,
    /// and a backgrounded process that is only sleeping is exactly what iOS suspends, until the next
    /// bluetooth wake about ten minutes later. Each unit took milliseconds to a few seconds of CPU, so a pass
    /// advanced roughly one night per wake. On one phone a 21-night pass ran 2 h 27 min, and a one-time
    /// full-history pass held the re-score lock from 21:34 until after 11:00 the next day. Every post-offload
    /// pass in between returned at the lock, so that morning's night was never scored. Working for ten seconds
    /// before resting ten keeps the same ~50% ceiling under iOS's 80%-over-60 s kill, with one suspension
    /// opportunity per ten seconds of work instead of one per night.
    static let backgroundWorkQuantumSeconds: Double = 10

    /// 260929, THE iOS-27 POSTURE — the root-cause gate. DO NOT DELETE IN AN UPLIFT without
    /// re-reading docs/releases/fork/v11.8.0.18.31.md.
    ///
    /// Root cause it answers, established from a controlled log comparison (same phone, same strap):
    /// upstream v11.8.0's #2296 deleted the "defer heavy passes out of the background" policy and
    /// paced them THROUGH the background instead. iOS 27 polices sustained background CPU by
    /// starving the process progressively — measured directly on 260929: 585 s of wall for ~5 s of
    /// compute — so paced background passes stretched from ≤30 s (260914-19, including iOS 27 on
    /// the pre-uplift app) to 8360 s within a week, dragging every store consumer (screens queue on
    /// the store actor behind starved reads) and HealthKit with them. Foreground was never affected
    /// (30 ms/statement all week). If an uplift removes this gate, the signature returns within
    /// days: multi-hundred-second light passes, multi-second `store sql` statements ONLY in
    /// background, and Battery-screen complaints about the Health app.
    ///
    /// The rule: before any pass starts inline in the background, a 50 ms CPU canary
    /// (`BackgroundCPUCanary`) measures the actual starvation; at or past this factor the pass is
    /// not attempted inline — the debt machinery hands it to a granted `BGProcessingTask` window or
    /// the next foreground, where iOS provides real CPU. Below it, background behaves as before.
    /// 4× is deliberately permissive: mild contention (a spotlight index, a photo pass) should not
    /// defer scoring; only genuine starvation (the measured episodes ran ×100+) should.
    static let backgroundStarvationFactor = 4.0

    /// Pure so it is pinned by tests: whether a pass may start inline in the background given the
    /// canary's measured wall-per-CPU factor.
    static func inlineBackgroundAllowed(canaryFactor: Double) -> Bool {
        canaryFactor.isFinite && canaryFactor < backgroundStarvationFactor
    }

    /// Seconds to rest after `workSeconds` of re-score work done since the last rest. Zero until a quantum of
    /// work has accumulated (`backgroundWorkQuantumSeconds`), and always zero in the foreground, where no CPU
    /// limit applies and the user is waiting on the result. A non-finite measurement rests zero.
    static func restSeconds(afterWorkSeconds workSeconds: Double, isBackground: Bool) -> Double {
        guard isBackground, workSeconds.isFinite, workSeconds >= backgroundWorkQuantumSeconds else { return 0 }
        return min(workSeconds * backgroundRestPerWorkSecond, maxBackgroundRestSeconds)
    }

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
    ///   - isRealUpdate: the trigger carries new data that must be scored (an offload), as opposed to the
    ///     steady-state backstop tick. A backgrounded backstop does not run: a paced pass costs minutes,
    ///     the tick cannot tell live HR from a real change, and every real update already runs its own.
    ///   - rescoreAlreadyOwed: a re-score is outstanding — either a pass marked itself started and never
    ///     marked itself finished (it was killed; the mark survives process death, which is the point,
    ///     because the killed process gets no chance to record anything) or an earlier trigger already
    ///     deferred one. The work is spoken for by the processing task this escalated to.
    ///   - passInProgress: a pass is running in THIS process. Its own started-mark is what reads as owed, so
    ///     it is not evidence of a killed pass; the engine re-arms one follow-up pass for a trigger that
    ///     lands mid-run. Deferring instead recorded a newer debt, the running pass then finished without
    ///     settling it (#1681), and every offload after that deferred on it. Spacing does not apply either.
    ///   - secondsSinceLastAttempt: how long ago the last pass STARTED, nil when unknown. An outstanding
    ///     debt defers only while that attempt is recent (`interruptedRetryCooldownSeconds`), and any
    ///     offload defers while it is under `backgroundSpacingSeconds`.
    static func decide(isBackground: Bool,
                       inSleepWindow: Bool,
                       rescoreAlreadyOwed: Bool,
                       owedByWindowDeferralOnly: Bool = false,
                       isRealUpdate: Bool = true,
                       passInProgress: Bool = false,
                       secondsSinceLastAttempt: Double? = nil) -> Decision {
        guard isBackground else { return .run }

        // Before the owed rules on purpose: an in-window deferral must resolve to the first post-window
        // trigger, never to a background task — falling through to the owed rule would schedule one.
        if inSleepWindow {
            return .deferUntilSleepWindowEnds(
                reason: "inside the sleep window — scoring pauses for the night and settles once after it ends (or on next foreground)",
                cause: .sleepWindow)
        }

        guard isRealUpdate else {
            return .deferToBackgroundTask(
                reason: "the backstop tick does not re-score while backgrounded; offloads run their own",
                cause: .backstopSkipped)
        }

        // A debt with ATTEMPT EVIDENCE behind it keeps the #1538 rule: don't re-attempt in the
        // background what the phone has already proved it cannot finish there — but only while that
        // attempt is RECENT (`interruptedRetryCooldownSeconds`); past the cooldown the retry runs,
        // paced, instead of deferring forever (19 h with no score, the shipped failure). A debt that
        // exists ONLY because the sleep window deferred it was never attempted at all, so it falls
        // through — the first post-window trigger runs it, and that pass IS the morning settle.
        if rescoreAlreadyOwed, !owedByWindowDeferralOnly, !passInProgress,
           let since = secondsSinceLastAttempt, since >= 0, since < interruptedRetryCooldownSeconds {
            return .deferToBackgroundTask(
                reason: "a re-score is already outstanding from an earlier trigger",
                cause: .alreadyOutstanding)
        }

        if !passInProgress, let since = secondsSinceLastAttempt, since >= 0, since < backgroundSpacingSeconds {
            return .deferToBackgroundTask(
                reason: "the last pass started \(Int(since / 60)) min ago; a backgrounded offload re-scores"
                    + " at most every \(Int(backgroundSpacingSeconds / 60)) min")
        }

        return .run
    }

    /// How long after an attempt that did not finish a backgrounded offload waits before trying again.
    ///
    /// Deferring on ANY outstanding debt, with no end, stopped scoring outright. A suspended app is
    /// routinely terminated by iOS for memory, not CPU, so a pass interrupted that way is ordinary, and the
    /// processing task it escalates to is granted rarely if ever. On one phone a pass left unfinished at
    /// 11:25 deferred every offload until the app was next opened: 19 hours, with no score for the night
    /// in between. Pacing (`backgroundRestPerWorkSecond`) is what keeps a background attempt under the CPU
    /// limit now, so this only needs to stop a retry on every offload, not forever.
    static let interruptedRetryCooldownSeconds: Double = 30 * 60

    /// The least time between the starts of two backgrounded offload re-scores.
    ///
    /// A strap offloads about every ten minutes, and each offload re-scored the whole window. On one
    /// WHOOP 5.0 that was about 7 passes an hour of 7–9 s CPU each, day and night: ~900 CPU-s over 16 h
    /// in the background, mostly re-scoring a night still in progress that nobody was looking at. Spaced
    /// 30 minutes apart, the same offloads cost ~250 CPU-s, and a backgrounded score trails its data by
    /// at most the spacing plus one offload interval. The work is moved, not dropped: the deferral records
    /// the debt, which the first offload past the spacing, the processing task or the next foreground
    /// settles, and a foregrounded pass is never spaced.
    static let backgroundSpacingSeconds: Double = 30 * 60
}
