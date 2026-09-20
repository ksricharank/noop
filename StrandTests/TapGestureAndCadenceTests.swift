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

    // MARK: - Digest cadence

    private func at(_ h: Int, day: Int = 20) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h))!
    }
    private func ms(_ d: Date) -> Int { Int(d.timeIntervalSince1970 * 1000) }

    /// 24 h keeps the original once-a-day behaviour.
    func testDailyCadenceIsUnchanged() {
        XCTAssertTrue(MuseIntegration.isDue(now: at(9), lastWrittenMs: 0,
                                            hourOfDay: 7, intervalHours: 24))
        XCTAssertFalse(MuseIntegration.isDue(now: at(9), lastWrittenMs: ms(at(8)),
                                             hourOfDay: 7, intervalHours: 24))
        // Yesterday's write does not satisfy today.
        XCTAssertTrue(MuseIntegration.isDue(now: at(9), lastWrittenMs: ms(at(8, day: 19)),
                                            hourOfDay: 7, intervalHours: 24))
    }

    /// 6 h = four writes a day, anchored at 07:00 → 07, 13, 19, 01.
    func testSixHourCadenceWritesFourTimes() {
        // Written at 08:00; at 12:00 we are still inside the 07:00 slot.
        XCTAssertFalse(MuseIntegration.isDue(now: at(12), lastWrittenMs: ms(at(8)),
                                             hourOfDay: 7, intervalHours: 6))
        // At 13:00 a new slot opens.
        XCTAssertTrue(MuseIntegration.isDue(now: at(13), lastWrittenMs: ms(at(8)),
                                            hourOfDay: 7, intervalHours: 6))
    }

    /// The regression this rule is easy to get wrong on: BEFORE the anchor hour, the relevant slot
    /// is the previous day's last one. A naive "clamp to today's anchor" goes silent from midnight
    /// to the anchor every single day.
    func testBeforeTheAnchorHourTheCadenceStillRuns() {
        // 02:00, six-hourly from 07:00 → the 01:00 slot has opened.
        XCTAssertTrue(MuseIntegration.isDue(now: at(2), lastWrittenMs: ms(at(20, day: 19)),
                                            hourOfDay: 7, intervalHours: 6))
        // ...and a write already made inside that slot is not repeated.
        XCTAssertFalse(MuseIntegration.isDue(now: at(2), lastWrittenMs: ms(at(1)),
                                             hourOfDay: 7, intervalHours: 6))
    }

    /// Only divisors of 24 are accepted, so writes land at the same clock times every day instead
    /// of walking around it.
    func testIntervalIsClampedToDivisorsOfADay() {
        XCTAssertEqual(MuseIntegration.clampInterval(5), MuseIntegration.defaultIntervalHours)
        XCTAssertEqual(MuseIntegration.clampInterval(0), MuseIntegration.defaultIntervalHours)
        XCTAssertEqual(MuseIntegration.clampInterval(6), 6)
        for h in MuseIntegration.intervalOptions {
            XCTAssertEqual(24 % h, 0, "\(h) must divide a day evenly")
        }
    }
}
