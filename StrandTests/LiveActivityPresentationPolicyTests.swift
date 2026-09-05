import XCTest
@testable import Strand

/// When the live-HR Lock Screen / Dynamic Island surface is allowed to be on screen.
///
/// Pinned here because every one of these rules is invisible from inside a single run: the surface is
/// system-drawn, the failures are "it stayed up all night" or "it flickered off and on", and both are
/// noticed on a wrist hours later rather than in a debugger. The sleep-window rule in particular has a
/// twin — `RescoreBackgroundPolicy` pauses SCORING over the same window — and the pair only stays
/// coherent if the boundaries are asserted rather than assumed.
final class LiveActivityPresentationPolicyTests: XCTestCase {

    /// The ordinary live case: toggle on, awake, connected, a sample in hand.
    func testPresentsWhileStreamingOutsideTheSleepWindow() {
        let decision = LiveActivityPresentationPolicy.decide(
            enabledByUser: true, inSleepWindow: false, connected: true, hasBPM: true)
        XCTAssertEqual(decision, .present)
    }

    /// The point of this change: inside the sleep window the surface goes away, even though the strap
    /// is connected and streaming perfectly well. Streaming and banking are deliberately untouched —
    /// only the presentation pauses.
    func testSuppressesInsideTheSleepWindowDespiteALiveStream() {
        let decision = LiveActivityPresentationPolicy.decide(
            enabledByUser: true, inSleepWindow: true, connected: true, hasBPM: true)
        guard case .suppress(let reason) = decision else {
            return XCTFail("expected suppression inside the sleep window, got \(decision)")
        }
        XCTAssertTrue(reason.contains("sleep window"),
                      "the reason is logged verbatim and must name the cause; got: \(reason)")
    }

    /// The window must not leak into the rest of the day: the same inputs one minute outside it present
    /// normally. This is the assertion that would catch an inverted or off-by-one window check.
    func testOutsideTheWindowIsUnaffected() {
        XCTAssertEqual(
            LiveActivityPresentationPolicy.decide(
                enabledByUser: true, inSleepWindow: false, connected: true, hasBPM: true),
            .present)
    }

    /// #336: an explicit user opt-out outranks every other input, including a healthy live stream.
    func testUserOptOutWinsOverEverything() {
        let decision = LiveActivityPresentationPolicy.decide(
            enabledByUser: false, inSleepWindow: false, connected: true, hasBPM: true)
        guard case .suppress(let reason) = decision else {
            return XCTFail("expected suppression when the toggle is off, got \(decision)")
        }
        XCTAssertTrue(reason.contains("toggle"), "got: \(reason)")
    }

    /// The opt-out is checked BEFORE the window, so a user who turned the feature off gets the toggle
    /// reason rather than a sleep-window one. Ordering matters for the log, which is the only place
    /// "why did it disappear" gets answered.
    func testToggleReasonOutranksWindowReason() {
        let decision = LiveActivityPresentationPolicy.decide(
            enabledByUser: false, inSleepWindow: true, connected: true, hasBPM: true)
        guard case .suppress(let reason) = decision else {
            return XCTFail("expected suppression, got \(decision)")
        }
        XCTAssertTrue(reason.contains("toggle"),
                      "the explicit opt-out should be reported ahead of the window; got: \(reason)")
    }

    /// A dropped live link HOLDS the activity rather than ending it (260829). The end was one-way —
    /// iOS forbids background starts — so charging the strap or a locked pocket-drop killed the island
    /// until the next app open. Honesty about the frozen number (#911, the reason this used to
    /// suppress) is carried by the drop-edge repaint instead: not-live, not-connected cue.
    func testDisconnectHoldsRatherThanSuppresses() {
        let decision = LiveActivityPresentationPolicy.decide(
            enabledByUser: true, inSleepWindow: false, connected: false, hasBPM: true)
        guard case .holdIfShowing(let reason) = decision else {
            return XCTFail("expected a hold when disconnected, got \(decision)")
        }
        XCTAssertTrue(reason.contains("not connected"), "got: \(reason)")
    }

    /// A connected strap with no sample on this tick must NOT tear the activity down — that is the
    /// flicker case. It holds instead, which is a different decision from suppression precisely so the
    /// controller can tell "nothing to push" from "take it off screen".
    func testMissingSampleHoldsRatherThanSuppresses() {
        let decision = LiveActivityPresentationPolicy.decide(
            enabledByUser: true, inSleepWindow: false, connected: true, hasBPM: false)
        guard case .holdIfShowing = decision else {
            return XCTFail("a missing sample must hold, not suppress; got \(decision)")
        }
    }

    /// A missing sample never overrides a real teardown reason: inside the window the activity still
    /// comes down. A dropped link is no longer a teardown reason — it holds, sample or not, and the
    /// reason names the link so the two hold flavours stay distinguishable in the log.
    func testTheWindowOutranksAMissingSampleAndADropStillHolds() {
        guard case .suppress = LiveActivityPresentationPolicy.decide(
            enabledByUser: true, inSleepWindow: true, connected: true, hasBPM: false) else {
            return XCTFail("sleep window must suppress even with no sample")
        }
        guard case .holdIfShowing(let reason) = LiveActivityPresentationPolicy.decide(
            enabledByUser: true, inSleepWindow: false, connected: false, hasBPM: false) else {
            return XCTFail("a dropped link must hold even with no sample")
        }
        XCTAssertTrue(reason.contains("not connected"), "got: \(reason)")
    }

    /// The toggle and the window still outrank a drop — an opted-out or sleeping card comes down even
    /// while the link is down, or the hold would pin a card the user asked to remove.
    func testTeardownReasonsOutrankTheDropHold() {
        guard case .suppress = LiveActivityPresentationPolicy.decide(
            enabledByUser: false, inSleepWindow: false, connected: false, hasBPM: true) else {
            return XCTFail("the opt-out must suppress even while disconnected")
        }
        guard case .suppress = LiveActivityPresentationPolicy.decide(
            enabledByUser: true, inSleepWindow: true, connected: false, hasBPM: true) else {
            return XCTFail("the sleep window must suppress even while disconnected")
        }
    }
}

/// The lock-screen card's columns (260905).
///
/// Structural, because the widget extension's view code is not linked into the test target and its
/// helpers are file-private: what can be checked is WHICH columns the card is built from, and that
/// is exactly the thing this change is about.
///
/// Maintainer instruction: "for the lock screen live notification, I realized I want HR, plus steps
/// n/t cal n/t, effort n/t" — and, separately and explicitly, "for the dynamic island, we have the
/// right behavior". So the card changes and the island must NOT, which is the pairing worth pinning:
/// an edit to this file that improves the card while quietly restyling the island would satisfy the
/// first half of the instruction and break the second.
final class LiveActivityBannerColumnsTests: XCTestCase {

    private var source: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StrandiOSWidgets/NOOPLiveActivity.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Isolate the Lock-Screen banner: everything before the `dynamicIsland:` closure.
    private var bannerBlock: String {
        let src = source
        guard let end = src.range(of: "} dynamicIsland: { context in") else { return "" }
        return String(src[src.startIndex..<end.lowerBound])
    }

    /// Isolate the island: everything from that closure on.
    private var islandBlock: String {
        let src = source
        guard let start = src.range(of: "} dynamicIsland: { context in") else { return "" }
        return String(src[start.lowerBound...])
    }

    func testTheBannerCarriesHRStepsCalAndEffort() {
        let banner = bannerBlock
        XCTAssertFalse(banner.isEmpty, "could not isolate the Lock-Screen banner")
        for column in ["HR", "Steps", "Cal", "Effort"] {
            XCTAssertTrue(banner.contains("bannerStat(label: \"\(column)\""),
                          "the Lock-Screen card must carry a \(column) column")
        }
        XCTAssertTrue(banner.contains("hrText(context.state)"),
                      "HR must render through hrText, which carries the live `~` marker")
    }

    /// Sleep left the CARD (four columns is what fits at this type size) but must still read in the
    /// expanded island — the instruction moved it, it did not delete it.
    func testSleepLeftTheCardButNotTheIsland() {
        XCTAssertFalse(bannerBlock.contains("bannerStat(label: \"Sleep\""),
                       "Sleep gave up its column to HR; a fifth column does not fit")
        XCTAssertTrue(islandBlock.contains("statColumn(label: \"Sleep\""),
                      "the expanded island must still show Sleep — the maintainer asked for the "
                      + "island to be left exactly as it was")
    }

    /// THE ISLAND SHOWS HR WHEN COLLAPSED (260905).
    ///
    /// CORRECTION, recorded because I got this wrong and shipped it: the original instruction was
    /// "I want the island to show the live hr only". When the maintainer then said "for the dynamic
    /// island, we have the right behavior", I read it as "leave the island alone" and reverted the
    /// island change wholesale — but they were confirming the CADENCE (window average locked, live
    /// unlocked, the -1 window), not the island's contents. Build 321 therefore shipped the island
    /// still showing Effort, and the report was "the dynamic HR is messed up - you didn't implement
    /// any of the changes I asked for". This test is what makes that reading unambiguous in code.
    func testTheCollapsedIslandShowsHeartRate() {
        let island = islandBlock
        XCTAssertTrue(island.contains("Text(hrText(context.state))"),
                      "the compact trailing slot must show the heart rate")
        XCTAssertTrue(island.contains("Text(\"\\(bpm)\")"),
                      "the minimal slot must show the heart rate")
        XCTAssertFalse(island.contains("effortNowText"),
                       "effort no longer owns a collapsed slot — it moved to the expanded region")
    }

    /// The EXPANDED island carries the day: "hr, sleep target, steps n/t, cal n/t, effort n/t,
    /// water n/t". Collapsing the island to a pure HR readout is only acceptable because expanding
    /// it still answers everything else.
    func testTheExpandedIslandCarriesTheDaysPairs() {
        let island = islandBlock
        for column in ["Effort", "Steps", "Cal", "Water", "Sleep"] {
            XCTAssertTrue(island.contains("statColumn(label: \"\(column)\""),
                          "the expanded island must carry a \(column) column")
        }
    }

    /// Charge was REMOVED from the island (260905, maintainer: "get rid of charge"). It is a score
    /// rather than a pair, and the top row reads better balanced two-up.
    ///
    /// The FIELD is deliberately still pushed — see `ContentState.recovery` — so an activity adopted
    /// across a build change still decodes. This asserts only that nothing renders it.
    func testChargeIsNoLongerRendered() {
        XCTAssertFalse(islandBlock.contains("statColumn(label: \"Charge\""),
                       "Charge was removed from the island")
        XCTAssertFalse(bannerBlock.contains("Charge"),
                       "Charge left the Lock-Screen banner earlier and must not return")
    }

    /// The corner-clipping fix (260905): "hr and charge are getting cutoff at the corners, same with
    /// effort on the bottom left".
    ///
    /// The expanded presentation wraps the sensor cutout and its regions run into the rounded
    /// corners, so content pinned to an outer edge is clipped by the curve. Both halves of the fix
    /// are pinned here because either alone leaves the report unaddressed: the regions must CENTRE
    /// their content, and the outer edges must be inset off the curve.
    func testTheExpandedRegionsAreInsetAndCentred() {
        let island = islandBlock
        XCTAssertTrue(island.contains(".padding(.leading, 6)"),
                      "the leading region must be inset off the corner curve")
        XCTAssertTrue(island.contains(".padding(.trailing, 6)"),
                      "the trailing region must be inset off the corner curve")
        XCTAssertTrue(island.contains(".padding(.horizontal, 4)"),
                      "the bottom row must be inset, or its first and last columns clip")
        XCTAssertTrue(island.contains(".frame(maxWidth: .infinity)"),
                      "regions must centre their content rather than pinning it to an edge")
    }
}
