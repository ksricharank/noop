import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// 261007: a partial pass refreshes TODAY's scored night only under a TRUSTED baseline; every other
/// case keeps the 260922 preserve rule. The field case: a 43 scored from a still-growing night at the
/// 06:00 window end stood for two hours while every later pass, under `hrvNValid=21 trusted`,
/// computed the finished night's 50 and was told to keep 43.
final class PartialPassTrustedRefreshTests: XCTestCase {

    private let today = "2026-10-07"

    func testTodayUnderATrustedBaselineRefreshes() {
        XCTAssertTrue(DailyMetric.partialPassRefreshesNight(day: today, todayKey: today,
                                                            baselineStatus: .trusted))
    }

    /// The original danger, kept exactly: a thin baseline (the 260926 `hrvNValid=2` flip) must
    /// never overwrite a stored night, today included.
    func testAThinBaselineKeepsThePreserveRule() {
        for status in [BaselineStatus.calibrating, .provisional, .stale] {
            XCTAssertFalse(DailyMetric.partialPassRefreshesNight(day: today, todayKey: today,
                                                                 baselineStatus: status),
                           "\(status) must not let a partial pass overwrite the stored night")
        }
        XCTAssertFalse(DailyMetric.partialPassRefreshesNight(day: today, todayKey: today,
                                                             baselineStatus: nil),
                       "no HRV baseline at all is the thinnest case")
    }

    /// Earlier days stay the completed passes' to re-judge: a light pass scans yesterday too, and its
    /// contract for any day but today is numerators only.
    func testEarlierDaysKeepThePreserveRuleEvenWhenTrusted() {
        XCTAssertFalse(DailyMetric.partialPassRefreshesNight(day: "2026-10-06", todayKey: today,
                                                             baselineStatus: .trusted))
    }
}
