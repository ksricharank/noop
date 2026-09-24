import Foundation

/// Whether the live-HR Live Activity (Lock Screen + Dynamic Island) should be showing right now.
///
/// Split out of `LiveActivityController` so the rule is a pure function over stated inputs rather than
/// something only reachable through ActivityKit. The controller owns the ActivityKit handles and the
/// ~1 Hz tick; this owns the decision, and the decision is what is worth pinning with a test — the
/// same split `RescoreBackgroundPolicy` makes against `RescoreBackgroundScheduler`.
///
/// The sleep-window rule here is the presentation half of the re-score deferral: the same wall-clock
/// window that pauses background scoring also pauses the surface. Both read one source of truth
/// (`RescoreBackgroundScheduler.isInSleepWindow`) so they can never drift apart, and the caller passes
/// the value in rather than this re-deriving it, which is what makes the window boundaries testable
/// without waiting for 22:00.
enum LiveActivityPresentationPolicy {

    /// What the controller should do with the activity on this tick.
    enum Decision: Equatable {
        /// Show it: start one if none is live, otherwise push the new values.
        case present
        /// Do not show it, and END any activity already on screen. The reason is for the strap log and
        /// for the tests to assert against — "the heart vanished overnight" should be answerable from
        /// the log rather than by reading this file.
        case suppress(reason: String)
        /// Nothing to push on this tick, but LEAVE a running activity alone. Distinct from `suppress`
        /// on purpose: a connected strap that hasn't produced a sample yet (or briefly skipped one) is
        /// the ordinary case, and tearing the activity down for it would make the Lock Screen flicker
        /// off and back on every time a sample slipped. Only start-worthy state is withheld.
        case holdIfShowing(reason: String)
    }

    /// - Parameters:
    ///   - enabledByUser: the in-app Live Activity toggle (#336). An explicit opt-out outranks
    ///     everything below it, including the connection state.
    ///   - inSleepWindow: whether the local wall clock is inside the user's sleep window — the SAME
    ///     value the re-score deferral uses (`RescoreBackgroundScheduler.isInSleepWindow`). Streaming
    ///     and banking continue through the window; only the presentation stops, because the surface
    ///     has no viewer at 3 a.m. and every push still costs against the system's update budget.
    ///   - connected: the LIVE link, not the sticky "paired" flag. Keying off `bonded` is what once
    ///     left a frozen, fabricated HR on the Lock Screen after the strap went out of range.
    ///   - hasBPM: whether a heart rate is actually present. Nothing to show without one.
    static func decide(enabledByUser: Bool,
                       inSleepWindow: Bool,
                       connected: Bool,
                       hasBPM: Bool) -> Decision {
        guard enabledByUser else {
            return .suppress(reason: "the Live Activity toggle is off")
        }
        guard !inSleepWindow else {
            return .suppress(
                reason: "inside the sleep window — the Lock Screen / Dynamic Island pauses for the "
                        + "night and resumes after it ends (streaming and scoring are unaffected)")
        }
        guard connected else {
            return .suppress(reason: "the strap is not connected")
        }
        // Deliberately `holdIfShowing`, not `suppress`: a connected strap with no sample on this tick is
        // routine, and ending the activity for it would flicker the Lock Screen off and on.
        guard hasBPM else {
            return .holdIfShowing(reason: "no live heart rate on this tick")
        }
        return .present
    }
}
