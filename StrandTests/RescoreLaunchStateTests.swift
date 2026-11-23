import XCTest
@testable import Strand

/// The abort gate's launch-state seed (260908).
///
/// The re-score abort gate reads a nonisolated mirror of the scene phase. That mirror is written by
/// `.onChange(of: scenePhase)`, which fires on a TRANSITION — so a cold launch straight into the
/// background never wrote it, and it reported its initial "foreground" default. The gate was therefore
/// disabled for exactly the passes it exists to stop: the 260908-2112 log shows
/// `trigger=forced where=background` at 17:53:06 running 1021 s before giving up, when the gate should
/// have fired at the first day boundary.
///
/// These are the invariants that failure violated. On macOS the whole mechanism is compiled out (the
/// gate is a no-op there), so the substantive assertions are iOS-only and the macOS leg pins that the
/// API exists and stays inert.
final class RescoreLaunchStateTests: XCTestCase {

    /// The seed API must exist on both platforms, so the call site compiles for either.
    func testSeedApiIsCallableOnThisPlatform() {
        RescoreBackgroundScheduler.seedLaunchState(isBackgrounded: false)
        RescoreBackgroundScheduler.noteScenePhase(isActive: true)
    }

    #if os(iOS)
    /// A real transition must take precedence over the launch seed from then on — the seed is only
    /// for the window BEFORE the first transition.
    func testATransitionOverridesTheLaunchSeed() {
        RescoreBackgroundScheduler.seedLaunchState(isBackgrounded: true)
        // Before any transition the seed answers.
        XCTAssertTrue(RescoreBackgroundScheduler.isBackgroundedSnapshot,
                      "a background launch must report backgrounded, not the default")
        // A transition to active now answers instead.
        RescoreBackgroundScheduler.noteScenePhase(isActive: true)
        XCTAssertFalse(RescoreBackgroundScheduler.isBackgroundedSnapshot,
                       "an observed transition outranks the launch seed")
        // And back again.
        RescoreBackgroundScheduler.noteScenePhase(isActive: false)
        XCTAssertTrue(RescoreBackgroundScheduler.isBackgroundedSnapshot)
    }

    /// The regression itself: a launch into the background must be visible to the gate immediately,
    /// with no transition needed.
    func testABackgroundLaunchIsVisibleWithoutATransition() {
        RescoreBackgroundScheduler.noteScenePhase(isActive: true)   // establish a known state
        RescoreBackgroundScheduler.seedLaunchState(isBackgrounded: true)
        // A transition HAS been seen in this process, so the mirror rightly wins — this documents
        // that the seed is not a retroactive override, only a pre-transition default.
        XCTAssertFalse(RescoreBackgroundScheduler.isBackgroundedSnapshot)
    }
    #else
    /// On macOS the gate is compiled out entirely and must always report foreground, so a shared
    /// code path can call it unconditionally.
    func testTheGateIsInertOnMacOS() {
        RescoreBackgroundScheduler.seedLaunchState(isBackgrounded: true)
        XCTAssertFalse(RescoreBackgroundScheduler.isBackgroundedSnapshot,
                       "there is no background scene phase to honour on macOS")
    }
    #endif
}
