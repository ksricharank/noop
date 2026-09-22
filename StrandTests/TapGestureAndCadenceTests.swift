import XCTest
@testable import Strand

/// The 260920 gesture gate and the digest's multi-write cadence. Both rules are pure, so both are
/// tested without a strap, a clock or a folder.
final class TapGestureAndCadenceTests: XCTestCase {

    // MARK: - Multi-event tap gesture

    /// The default (1) must behave EXACTLY as before: one event fires. Anything else would change
    /// the gesture for wearers who never reported a false positive.
    func testOneRequiredTapFiresImmediately() {
        let r = WaterTapPrefs.gestureCompletes(now: Date(), pending: [],
                                               requiredTaps: 1, gestureWindowSeconds: 3)
        XCTAssertTrue(r.fires)
        XCTAssertTrue(r.pending.isEmpty)
    }

    /// The maintainer's clap: ONE strap event. With 2 required it must not fire.
    func testASingleEventDoesNotFireWhenTwoAreRequired() {
        let r = WaterTapPrefs.gestureCompletes(now: Date(), pending: [],
                                               requiredTaps: 2, gestureWindowSeconds: 3)
        XCTAssertFalse(r.fires)
        XCTAssertEqual(r.pending.count, 1, "the event is remembered as part of a gesture in progress")
    }

    /// The deliberate gesture: two events a second apart, inside the window.
    func testTwoEventsInsideTheWindowFire() {
        let first = Date()
        let second = first.addingTimeInterval(1.0)
        let a = WaterTapPrefs.gestureCompletes(now: first, pending: [],
                                               requiredTaps: 2, gestureWindowSeconds: 3)
        XCTAssertFalse(a.fires)
        let b = WaterTapPrefs.gestureCompletes(now: second, pending: a.pending,
                                               requiredTaps: 2, gestureWindowSeconds: 3)
        XCTAssertTrue(b.fires)
        XCTAssertTrue(b.pending.isEmpty, "a fired gesture resets, so the next tap starts fresh")
    }

    /// Two claps far apart must NOT accumulate into a gesture — that would make the setting useless
    /// for exactly the wearer it exists for.
    func testEventsOutsideTheWindowDoNotAccumulate() {
        let first = Date()
        let muchLater = first.addingTimeInterval(60)
        let a = WaterTapPrefs.gestureCompletes(now: first, pending: [],
                                               requiredTaps: 2, gestureWindowSeconds: 3)
        let b = WaterTapPrefs.gestureCompletes(now: muchLater, pending: a.pending,
                                               requiredTaps: 2, gestureWindowSeconds: 3)
        XCTAssertFalse(b.fires)
        XCTAssertEqual(b.pending.count, 1, "the stale event is dropped, not counted")
    }

    func testCountAndWindowAreClampedOnRead() {
        XCTAssertEqual(WaterTapPrefs.clampTaps(0), WaterTapPrefs.minRequiredTaps)
        XCTAssertEqual(WaterTapPrefs.clampTaps(99), WaterTapPrefs.maxRequiredTaps)
        XCTAssertEqual(WaterTapPrefs.clampGestureWindow(0), WaterTapPrefs.minGestureWindow)
        XCTAssertEqual(WaterTapPrefs.clampGestureWindow(999), WaterTapPrefs.maxGestureWindow)
    }

    // MARK: - Digest cadence (260922: N updates a day from the sleep window's end)

    private func at(_ h: Int, _ m: Int = 0, day: Int = 20) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: m))!
    }
    private func ms(_ d: Date) -> Int { Int(d.timeIntervalSince1970 * 1000) }
    private let anchor = 7 * 60

    /// Once a day keeps the original behaviour: first opportunity after the anchor, once per day.
    func testOnceADayCadence() {
        XCTAssertTrue(MuseIntegration.isDue(now: at(9), lastWrittenMs: 0, updatesPerDay: 1, anchorMinuteOfDay: anchor))
        XCTAssertFalse(MuseIntegration.isDue(now: at(9), lastWrittenMs: ms(at(8)), updatesPerDay: 1, anchorMinuteOfDay: anchor))
        // Yesterday's write does not satisfy today.
        XCTAssertTrue(MuseIntegration.isDue(now: at(9), lastWrittenMs: ms(at(8, day: 19)), updatesPerDay: 1, anchorMinuteOfDay: anchor))
    }

    /// Four a day from 07:00 → 07, 13, 19, 01.
    func testFourADayWritesFourTimes() {
        // Written at 08:00; at 12:00 we are still inside the 07:00 slot.
        XCTAssertFalse(MuseIntegration.isDue(now: at(12), lastWrittenMs: ms(at(8)), updatesPerDay: 4, anchorMinuteOfDay: anchor))
        // At 13:00 a new slot opens.
        XCTAssertTrue(MuseIntegration.isDue(now: at(13), lastWrittenMs: ms(at(8)), updatesPerDay: 4, anchorMinuteOfDay: anchor))
    }

    /// The regression this rule is easy to get wrong on: BEFORE the anchor, the relevant slot is the
    /// previous day's last one. A naive "clamp to today's anchor" goes silent from midnight to the anchor.
    func testBeforeTheAnchorTheCadenceStillRuns() {
        // 02:00, four a day from 07:00 → the 01:00 slot has opened.
        XCTAssertTrue(MuseIntegration.isDue(now: at(2), lastWrittenMs: ms(at(20, day: 19)), updatesPerDay: 4, anchorMinuteOfDay: anchor))
        // ...and a write already made inside that slot is not repeated.
        XCTAssertFalse(MuseIntegration.isDue(now: at(2), lastWrittenMs: ms(at(1)), updatesPerDay: 4, anchorMinuteOfDay: anchor))
    }

    /// A non-divisor count still lands on evenly spaced slots that repeat daily: 5 a day = every
    /// 4.8 h from the anchor, so the day's slots are 07:00, 11:48, 16:36, 21:24, 02:12.
    func testAnyCountIsEvenlySpacedAndClamped() {
        XCTAssertFalse(MuseIntegration.isDue(now: at(11, 30), lastWrittenMs: ms(at(7, 5)), updatesPerDay: 5, anchorMinuteOfDay: anchor))
        XCTAssertTrue(MuseIntegration.isDue(now: at(11, 50), lastWrittenMs: ms(at(7, 5)), updatesPerDay: 5, anchorMinuteOfDay: anchor))
        XCTAssertEqual(MuseIntegration.clampUpdates(0), 1)
        XCTAssertEqual(MuseIntegration.clampUpdates(99), MuseIntegration.updatesPerDayRange.upperBound)
    }
}
