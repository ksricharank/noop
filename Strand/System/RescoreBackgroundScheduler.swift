import Foundation
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// Runs a backgrounded re-score somewhere it can actually finish, and records honestly when one did not.
///
/// See `RescoreBackgroundPolicy` for the problem (#1538) and the decision rules. This is the plumbing:
/// the durable "a re-score is owed" mark, the measured duration the policy reads, the iOS
/// execution assertion, and the `BGProcessingTask` that work is escalated to.
///
/// `BGProcessingTask` rather than `BGAppRefreshTask` — the two the app already uses (the scheduled debug
/// export, the Health write-back) are refresh tasks, which are metered for short work. Processing tasks are
/// the long, deferrable kind, which is what an eight-minute pass needs. iOS decides when one runs and
/// favours idle and charging, so this is an "eventually, without needing the user to hold the app open"
/// guarantee, NOT a promise that a score appears moments after a sync. Nothing here claims otherwise, and
/// the honest limit is worth stating: on an install where the pass takes minutes, the score still normally
/// appears when the app is next opened. What changes is that the phone stops paying for a full doomed pass
/// on every single offload to get there.
///
/// HONEST about platform limits, in the shape of `ScheduledDebugExport`:
/// - **macOS** — the app is a normal foreground app with no suspension deadline. Every entry point here is
///   a no-op that reports `.run`, so the existing behaviour is exactly preserved.
/// - **iOS** — needs the `processing` background mode AND the identifier listed in
///   `BGTaskSchedulerPermittedIdentifiers` AND `register()` called before launch finishes. If any of those
///   is missing, `submit` fails gracefully and the foreground path still scores normally.
@MainActor
enum RescoreBackgroundScheduler {

    /// A re-score is OWED: either a pass marked itself started and never marked itself finished (it was
    /// killed), or a trigger deferred one to a background task. Survives process death, which is the
    /// entire point — the process being killed is the event we are trying to observe, and it is not an
    /// event the killed process gets any chance to write down.
    static let owedKey = "noop.rescoreOwed"
    /// The debt's KIND: true when the owed re-score exists ONLY because sleep-window deferrals recorded
    /// it — no pass was ever attempted, so there is no evidence it cannot finish in the background, and
    /// the first post-window trigger may simply run it. False (or absent) for a debt with attempt
    /// evidence behind it — a pass that started and was killed, or one the measured rule escalated —
    /// which keeps the #1538 behaviour: background triggers defer it to the processing task / foreground
    /// rather than re-attempting a pass the phone has already proved it cannot finish there.
    static let owedByWindowDeferralOnlyKey = "noop.rescoreOwedByWindowDeferralOnly"
    /// Seconds the last COMPLETED pass took. Only ever written by a pass that reached the end.
    static let lastPassSecondsKey = "noop.rescoreLastPassSeconds"

    /// When the last LOCKED background-processing settle COMPLETED (epoch seconds), feeding the
    /// settle-side pacing (`RescoreBackgroundPolicy.settleDecision`). Stamped only after a pass ran to
    /// the end, so a killed one leaves no stamp and the next task retries freely. Survives process
    /// death for the same reason the debt does — the treadmill this paces spans many process lifetimes.
    static let lastLockedSettleAtKey = "noop.rescoreLastLockedSettleAt"

    /// Identifies the MOST RECENT debt, so a pass can tell its own from someone else's (#1681).
    ///
    /// A token rather than a counter, deliberately. A counter needs read-modify-write, and two triggers
    /// marking a debt at the same moment could both read N and both write N+1 — losing an increment, and
    /// with it exactly the debt this is meant to protect. A fresh token is a single write: concurrent
    /// marks each produce a distinct one, the last wins, and it cannot equal any pass's captured token.
    static let owedTokenKey = "noop.rescoreOwedToken"

    static var isRescoreOwed: Bool { UserDefaults.standard.bool(forKey: owedKey) }

    static var currentOwedToken: String? { UserDefaults.standard.string(forKey: owedTokenKey) }

    /// See `owedByWindowDeferralOnlyKey`. Reads false whenever nothing is owed at all.
    static var isOwedByWindowDeferralOnly: Bool {
        isRescoreOwed && UserDefaults.standard.bool(forKey: owedByWindowDeferralOnlyKey)
    }

    static var lastCompletedPassSeconds: Double? {
        guard UserDefaults.standard.object(forKey: lastPassSecondsKey) != nil else { return nil }
        let value = UserDefaults.standard.double(forKey: lastPassSecondsKey)
        return value.isFinite && value > 0 ? value : nil
    }

    /// See `lastLockedSettleAtKey`. Nil until a locked settle has ever completed, or when the stored
    /// value is unreadable — both mean "unknown" to the pacing rule, which runs.
    static var lastLockedSettleAt: Date? {
        guard UserDefaults.standard.object(forKey: lastLockedSettleAtKey) != nil else { return nil }
        let value = UserDefaults.standard.double(forKey: lastLockedSettleAtKey)
        return value.isFinite && value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    /// Stamp that a LOCKED background settle ran to completion just now — see `lastLockedSettleAtKey`.
    static func markLockedSettleCompleted(now: Date = Date()) {
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastLockedSettleAtKey)
    }

    /// Mark a re-score as owed with attempt evidence behind it. Called by `IntelligenceEngine` once a
    /// pass is past every gate and is definitely about to work — so that a kill leaves the debt behind —
    /// and by the background-task deferral path (the measured rule already decided this pass cannot
    /// finish in a plain background wake). Either way the debt is NOT window-deferral-only, so a later
    /// background trigger defers it rather than re-attempting it.
    /// Returns the token stamped on this debt (#1681). A pass keeps it and hands it back at completion;
    /// every other caller (the deferral paths) can ignore it, since it is not the one that will settle up.
    @discardableResult
    static func markRescoreOwed() -> String {
        let token = UUID().uuidString
        UserDefaults.standard.set(true, forKey: owedKey)
        UserDefaults.standard.set(false, forKey: owedByWindowDeferralOnlyKey)
        UserDefaults.standard.set(token, forKey: owedTokenKey)
        return token
    }

    /// Mark a re-score as owed by a SLEEP-WINDOW deferral: never attempted, safe for the first
    /// post-window trigger to simply run. Never downgrades an existing attempt-evidence debt — if a
    /// killed pass already left its mark, that stronger meaning survives any number of overnight
    /// deferrals piling on top.
    static func markRescoreDeferredForSleepWindow() {
        if !isRescoreOwed {
            UserDefaults.standard.set(true, forKey: owedByWindowDeferralOnlyKey)
        }
        UserDefaults.standard.set(true, forKey: owedKey)
        // A deferral records NEW outstanding data, so it stamps a fresh token too (#1681): a pass that
        // was already in flight when the window opened read its inputs before this data existed, and
        // must not settle a debt recorded for data it never saw — the same mid-pass hole the token
        // exists to close, arriving through the deferral door instead of a trigger.
        UserDefaults.standard.set(UUID().uuidString, forKey: owedTokenKey)
    }

    /// May a pass holding [capturedToken] settle the debt?
    ///
    /// Only if nothing newer was recorded while it ran. The bug in #1681 is that this question was never
    /// asked: completion cleared one global boolean unconditionally, so a trigger firing mid-pass — for
    /// data that arrived AFTER the pass had already read its inputs — had its debt erased before the
    /// correction it was recorded for ever ran. The scoring loop starts at today, so the night most
    /// likely to still be syncing is the first thing read and the likeliest to be caught mid-write.
    ///
    /// A pass with NO token never settles. That errs toward one extra pass, which costs battery; the
    /// other direction costs a night's scores until something unrelated happens to re-score it, which is
    /// the failure being fixed.
    ///
    /// Pure, so the rule is pinned without UserDefaults or a background task.
    static func maySettleDebt(capturedToken: String?, currentToken: String?) -> Bool {
        guard let capturedToken, !capturedToken.isEmpty else { return false }
        return capturedToken == currentToken
    }

    /// Settle the debt at the end of a completed pass, beside the watermark advance. A pass that is
    /// killed never reaches this, which is what leaves the mark set for the next launch to find.
    /// [owedToken] is the token this pass received from its own `markRescoreOwed()`. The debt is settled
    /// only if it is still the current one — see `maySettleDebt`. The pass duration is recorded either
    /// way: it is telemetry about THIS pass, and true regardless of whose debt is now outstanding.
    /// Returns whether the debt was actually settled, so the caller can SAY when it was not. Declining
    /// is the interesting outcome and it must not be silent: #1538 cost three nights because the log
    /// recorded that scoring had not happened without ever recording why, and a pass that completes
    /// while leaving the mark set looks identical to one that cleared it unless something says so.
    @discardableResult
    static func markRescoreCompleted(seconds: Double, owedToken: String?) -> Bool {
        let settled = maySettleDebt(capturedToken: owedToken, currentToken: currentOwedToken)
        if settled {
            UserDefaults.standard.set(false, forKey: owedKey)
            UserDefaults.standard.set(false, forKey: owedByWindowDeferralOnlyKey)
        }
        if seconds.isFinite, seconds > 0 {
            UserDefaults.standard.set(seconds, forKey: lastPassSecondsKey)
        }
        return settled
    }

    /// Whether the app is somewhere a long pass might not survive. Always false on macOS — see the type doc.
    ///
    /// Anything that is not `.active` counts, `.inactive` included, which is the conservative direction on
    /// purpose. `.inactive` is the state on the way to suspension, so reading it as "foreground" is the
    /// error that loses work; reading it as "background" costs at most a deferral that the very next
    /// `.active` transition drains. The transient `.inactive` cases — app switcher, notification centre,
    /// an incoming call — therefore self-correct within seconds, and the case that matters is never missed.
    static var isBackgrounded: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState != .active
        #else
        return false
        #endif
    }

    /// Whether the phone is locked (protected data unavailable) — the same read the Live Activity's
    /// cadence and the stream duty cycle use; the keybag tracks the passcode lock and follows the
    /// physical lock near-instantly both ways. Always false on macOS, like `isBackgrounded`.
    static var isDeviceLocked: Bool {
        #if os(iOS)
        return !UIApplication.shared.isProtectedDataAvailable
        #else
        return false
        #endif
    }

    /// Whether the local wall clock is inside the user's sleep window — the reused quiet-hours window
    /// (`ContinuousHrvSchedule.quietStartKey`/`quietEndKey`, 22:00–07:00 by default, editable in
    /// Settings on iOS and in Notification settings on macOS). Re-derived on every call, same as the
    /// continuous-capture gate, so a Settings edit or the window rolling over applies to the very next
    /// decision. Platform-agnostic on purpose — but macOS never reaches the policy's window rule anyway,
    /// because `isBackgrounded` is hard-false there and foreground is never deferred.
    static var isInSleepWindow: Bool {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let d = UserDefaults.standard
        return ContinuousHrvSchedule.windowContains(
            minuteOfDay,
            startMin: d.object(forKey: ContinuousHrvSchedule.quietStartKey) as? Int
                ?? ContinuousHrvSchedule.defaultStartMinutes,
            endMin: d.object(forKey: ContinuousHrvSchedule.quietEndKey) as? Int
                ?? ContinuousHrvSchedule.defaultEndMinutes)
    }

    /// Seconds from `minuteOfDay` until the sleep window's `endMinute`, plus a small buffer so the
    /// re-armed task lands clearly OUTSIDE the window rather than racing its edge. Pure — the wrap-around
    /// (an 22:00–07:00 window queried at 23:30) is exactly the arithmetic worth pinning in a test.
    static func secondsUntilWindowEnd(minuteOfDay: Int, endMinute: Int,
                                      bufferSeconds: Double = 300) -> Double {
        let remaining = ((endMinute - minuteOfDay) % 1440 + 1440) % 1440
        return Double(remaining * 60) + bufferSeconds
    }

    /// `secondsUntilWindowEnd` against the live clock and stored window — nil when the clock is not
    /// inside the window at all (there is no edge to wait for).
    static var secondsUntilSleepWindowEnd: Double? {
        guard isInSleepWindow else { return nil }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let end = UserDefaults.standard.object(forKey: ContinuousHrvSchedule.quietEndKey) as? Int
            ?? ContinuousHrvSchedule.defaultEndMinutes
        return secondsUntilWindowEnd(minuteOfDay: minuteOfDay, endMinute: end)
    }

    /// Decide, then either run `work` under an execution assertion or leave it for `BGProcessingTask`.
    ///
    /// `log` goes to the strap log, always — both the decision and its reason. #1538 cost three nights
    /// because the log recorded that scoring had not happened without ever recording why.
    /// `isBackground` defaults to the real application state and is a parameter only so a test can drive
    /// the deferral branch, which is unreachable on macOS (where `isBackgrounded` is always false) and is
    /// exactly where the work-is-owed bookkeeping lives.
    /// - Parameter owesOnDefer: whether a deferral should record a debt for a background task to settle.
    ///   True for a real update path — a completed offload MUST eventually be scored, so deferring it has
    ///   to leave something behind or the work is dropped rather than moved. FALSE for the steady-state
    ///   backstop tick, which by its own contract is not the thing that must happen: every real update
    ///   forces its own pass, so the tick exists only to catch what those missed. Recording a debt for it
    ///   would conjure a forced full pass for a processing task to run when very likely nothing changed,
    ///   which is the churn #1146 exists to avoid. A debt an earlier real pass already recorded is
    ///   untouched either way.
    static func run(isBackground: Bool? = nil,
                    inSleepWindow: Bool? = nil,
                    isLocked: Bool? = nil,
                    owesOnDefer: Bool = true,
                    log: @escaping (String) -> Void,
                    work: () async -> Void) async {
        let decision = RescoreBackgroundPolicy.decide(
            isBackground: isBackground ?? isBackgrounded,
            inSleepWindow: inSleepWindow ?? isInSleepWindow,
            rescoreAlreadyOwed: isRescoreOwed,
            owedByWindowDeferralOnly: isOwedByWindowDeferralOnly,
            isDeviceLocked: isLocked ?? isDeviceLocked,
            lastCompletedPassSeconds: lastCompletedPassSeconds)

        switch decision {
        case .deferToBackgroundTask(let reason):
            guard owesOnDefer else {
                // Nothing is queued and nothing is owed: the backstop simply does not run here. Said
                // plainly in the log, because "deferred" would promise a background task that is not
                // coming.
                log("re-score: backstop tick skipped while backgrounded — \(reason)")
                return
            }
            // Record the debt BEFORE scheduling. Without this the background task wakes, finds nothing
            // marked owed, and returns having done nothing — the deferral would silently drop the work
            // rather than move it.
            markRescoreOwed()
            log("re-score: deferred to a background task — \(reason)")
            schedule()
        case .deferUntilSleepWindowEnds(let reason):
            guard owesOnDefer else {
                log("re-score: backstop tick skipped during the sleep window — \(reason)")
                return
            }
            // Same debt bookkeeping shape as the case above, but the DEFERRAL-ONLY mark and deliberately
            // NO `schedule()`: a processing task favours idle, and idle on a phone worn to bed is
            // mid-night — it would run the pass at 3 a.m. after all. The debt is settled by the first
            // data-driven trigger after the window ends (the offload cadence keeps firing; post-window
            // the policy lets a never-attempted debt simply run, locked or not) or the next foreground
            // entry. Repeated in-window deferrals only re-set the same mark, so a whole night coalesces
            // into one pass.
            markRescoreDeferredForSleepWindow()
            log("re-score: deferred to the end of the sleep window — \(reason)")
        case .run:
            await withAssertion(log: log, work: work)
        }
    }

    /// Hold an execution assertion for the duration of `work` so a SHORT pass is not suspended halfway.
    /// A long one still outlives the grant; the assertion's expiry handler is where that becomes visible
    /// in the log and where the work is escalated, rather than the process simply vanishing.
    private static func withAssertion(log: @escaping (String) -> Void, work: () async -> Void) async {
        #if os(iOS)
        let assertion = BackgroundAssertion()
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "noop.rescore") {
            // iOS invokes this on the main thread when it is about to reclaim the assertion. The pass
            // itself cannot be cancelled from here — its heavy loop runs in a detached task, which does
            // not inherit cancellation — so do not pretend to stop it. Record the fact and escalate:
            // the owed mark is still set (only a completed pass clears it) and that is what the next
            // decision reads.
            MainActor.assumeIsolated {
                log("re-score: background time expired before the pass finished — escalating (#1538)")
                schedule()
                assertion.end()
            }
        }
        assertion.store(taskID)
        await work()
        // Idempotent under the box's lock, so the expiry path and this one cannot double-end the task —
        // which UIKit treats as a programmer error — and cannot leak it either.
        assertion.end()
        #else
        await work()
        #endif
    }

    /// Public assertion holder for OTHER short post-offload work (the 260831 background light pass):
    /// same short-pass suspension protection as `withAssertion`, but the expiry deliberately does NOT
    /// `schedule()` — a light pass leaves no debt behind by design (it recurs on the very next sync),
    /// so asking iOS for a processing task on its behalf would conjure work the debt system never
    /// recorded. `name` distinguishes the holders in the system's assertion accounting.
    static func holdAssertion(name: String, log: @escaping (String) -> Void,
                              work: () async -> Void) async {
        #if os(iOS)
        let assertion = BackgroundAssertion()
        let taskID = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated {
                log("\(name): background time expired before the work finished — it retries on the next trigger")
                assertion.end()
            }
        }
        assertion.store(taskID)
        await work()
        assertion.end()
        #else
        await work()
        #endif
    }

    // MARK: - iOS background-processing plumbing

    #if os(iOS)
    static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".rescore"

    /// Register the handler. MUST be called from `StrandiOSApp.init()` before launch finishes, and the
    /// identifier MUST be listed in `BGTaskSchedulerPermittedIdentifiers`, or iOS never delivers the task.
    /// Safe to leave uncalled: `schedule()` fails gracefully and the foreground path still scores.
    /// `log` reaches the strap log (rare-event: it speaks only when a wake is skipped, which is exactly
    /// the decision that must not be silent — the treadmill this gate stops was 38 unexplained passes).
    static func register(log: @escaping @MainActor (String) -> Void = { _ in },
                         perform operation: @escaping @MainActor () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let completion = TaskCompletionGuard(task: task)
            let worker = Task { @MainActor in
                // The settle-side convergence gate (260829): under a +N locked sync, a locked settle can
                // NEVER clear the debt — new data lands mid-pass, the token supersedes (#1681), the next
                // deferral re-arms this task — so unconditional runs became a treadmill of I/O-throttled
                // passes nobody could see. Decide first; a skipped wake costs one log line.
                let lockedAtStart = isDeviceLocked
                if isRescoreOwed {
                    let decision = RescoreBackgroundPolicy.settleDecision(
                        isLocked: lockedAtStart,
                        inSleepWindow: isInSleepWindow,
                        secondsSinceLastLockedSettle: lastLockedSettleAt.map {
                            Date().timeIntervalSince($0)
                        },
                        secondsUntilSleepWindowEnd: secondsUntilSleepWindowEnd)
                    if case .skip(let reason, let retryAfter) = decision {
                        log("re-score: background settle skipped — \(reason)")
                        schedule(earliestIn: retryAfter)
                        // Skipping IS the intended behaviour here, not a failure iOS should penalise.
                        completion.finish(success: true)
                        return
                    }
                }
                await operation()
                guard !Task.isCancelled else { return }
                // Only a pass that RAN TO COMPLETION here paces the next locked settle; a killed one
                // leaves no stamp, so the next task retries freely (the #1538 escalation is preserved).
                if lockedAtStart, isDeviceLocked { markLockedSettleCompleted() }
                // Re-arm only while work remains. A processing task is single-shot, and re-submitting
                // unconditionally would ask iOS for a wake on every install forever, including the ones
                // that never have anything to do.
                if isRescoreOwed { schedule() }
                completion.finish(success: !isRescoreOwed)
            }
            task.expirationHandler = {
                worker.cancel()
                // The pass did not finish inside the processing budget either. Ask for another rather
                // than dropping the work, and report the failure so iOS's own scheduling heuristics see
                // it honestly instead of being told this succeeded.
                schedule()
                completion.finish(success: false)
            }
        }
    }

    /// Keep exactly one pending request, so calling this from several places is idempotent and also
    /// repairs a request the system discarded.
    ///
    /// `earliestIn` asks iOS not to fire before that many seconds from now. When it is nil, the pacing
    /// falls back to whatever the last completed LOCKED settle implies: the offload deferral path calls
    /// this every few minutes under a +N locked sync, and since each call is cancel-and-resubmit, a bare
    /// request here would erase the spacing the settle gate just re-armed — the treadmill by another door.
    static func schedule(earliestIn: TimeInterval? = nil) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        // Neither is required. Network is irrelevant to an offline app, and demanding external power
        // would strand the work for anyone who does not charge overnight — the exact population most
        // likely to be wearing the strap continuously.
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        var delay = earliestIn
        if delay == nil, let last = lastLockedSettleAt {
            let since = Date().timeIntervalSince(last)
            if since >= 0, since < RescoreBackgroundPolicy.lockedSettleSpacingSeconds {
                delay = RescoreBackgroundPolicy.lockedSettleSpacingSeconds - since
            }
        }
        if let delay, delay > 0 {
            request.earliestBeginDate = Date().addingTimeInterval(delay)
        }
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Holds the background-task identifier so the normal path and the expiry handler can each try to end
    /// it while exactly one of them succeeds. UIKit treats a double `endBackgroundTask` as a programmer
    /// error and a never-ended one as grounds for killing the app, so neither may be left to ordering.
    /// Plain lock rather than actor isolation, matching `TaskCompletionGuard` below.
    private final class BackgroundAssertion: @unchecked Sendable {
        private let lock = NSLock()
        private var id: UIBackgroundTaskIdentifier = .invalid

        func store(_ newID: UIBackgroundTaskIdentifier) {
            lock.lock()
            defer { lock.unlock() }
            id = newID
        }

        @MainActor func end() {
            lock.lock()
            let current = id
            id = .invalid
            lock.unlock()
            guard current != .invalid else { return }
            UIApplication.shared.endBackgroundTask(current)
        }
    }

    /// Guards `setTaskCompleted` against being called twice — once normally and once from the expiration
    /// handler — which `BGTaskScheduler` treats as a programmer error. Plain lock rather than actor
    /// isolation: iOS can invoke the expiration handler on a different queue. Mirrors the guard in
    /// `ScheduledDebugExport`.
    private final class TaskCompletionGuard: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var finished = false

        init(task: BGTask) { self.task = task }

        func finish(success: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            task.setTaskCompleted(success: success)
        }
    }
    #else
    /// macOS has no background-task scheduler and no suspension deadline — nothing to schedule.
    static func schedule(earliestIn: TimeInterval? = nil) {}
    #endif
}
