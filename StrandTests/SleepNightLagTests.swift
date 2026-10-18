import XCTest
import WhoopStore
@testable import Strand

/// 261018: the Sleep tab showed yesterday's night under "Last night's sleep wasn't detected" for
/// much of a morning in which every pass had scored and stored the new one — the tab's fuller block
/// list is a separate load that a busy morning keeps cancelling, so it can stand on a list read
/// before the night existed. A night it has not caught up to is taken from the one-per-night list.
@MainActor
final class SleepNightLagTests: XCTestCase {

    /// Local noon on `day` days after 2026-10-15, as unix seconds — a stable wake-time anchor.
    private func ts(day: Int, hour: Int) -> Int {
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: hour))!
        return Int(base.addingTimeInterval(TimeInterval(day * 86_400)).timeIntervalSince1970)
    }

    private func night(endingDay day: Int) -> CachedSleepSession {
        CachedSleepSession(startTs: ts(day: day - 1, hour: 23), endTs: ts(day: day, hour: 7),
                           efficiency: 0.9, restingHr: 58, avgHrv: 45, stagesJSON: nil)
    }

    func testAFullerListBehindThePerNightListTakesTheNewerNight() {
        let loaded = [night(endingDay: 1), night(endingDay: 2)]           // read before night 3 existed
        let perNight = [night(endingDay: 2), night(endingDay: 3)]
        let merged = SleepModel.navSessions(allSessions: loaded, sleeps: perNight)
        XCTAssertEqual(merged.map(\.endTs), [ts(day: 1, hour: 7), ts(day: 2, hour: 7), ts(day: 3, hour: 7)])
        // The newest day group is now night 3 — what the hero shows.
        XCTAssertEqual(SleepModel.navDays(navSessions: merged).first?.first?.endTs, ts(day: 3, hour: 7))
    }

    func testAnUpToDateFullerListIsUsedAsIs() {
        let loaded = [night(endingDay: 2), night(endingDay: 3)]
        XCTAssertEqual(SleepModel.navSessions(allSessions: loaded, sleeps: [night(endingDay: 3)]), loaded)
    }

    func testBeforeTheFullerListLoadsThePerNightListStands() {
        let perNight = [night(endingDay: 3)]
        XCTAssertEqual(SleepModel.navSessions(allSessions: [], sleeps: perNight), perNight)
    }

    /// The evidence line: silent when everything agrees, named when the list was behind.
    func testTheLagLineIsSilentWhenTheListsAgree() {
        let n3 = night(endingDay: 3)
        let day3 = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(n3.endTs)))
        let days = [DailyMetric(day: day3, totalSleepMin: 540, efficiency: 0.9, deepMin: nil, remMin: nil,
                                lightMin: nil, disturbances: nil, restingHr: 58, avgHrv: 45,
                                recovery: 90, strain: nil, exerciseCount: nil)]
        XCTAssertNil(SleepView.nightLagLine(allSessions: [n3], sleeps: [n3], days: days,
                                            shownEndTs: n3.endTs, restored: false))
        let line = SleepView.nightLagLine(allSessions: [night(endingDay: 2)], sleeps: [n3], days: days,
                                          shownEndTs: n3.endTs, restored: true)
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("filled from the per-night list") ?? false, line ?? "")
    }
}
