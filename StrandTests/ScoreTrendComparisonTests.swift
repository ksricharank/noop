import XCTest
@testable import Strand

/// The trend footer's like-for-like comparison.
///
/// 260906, reported as: "the day quality trend always seems to do compare vs next 7 and prev 7 - is
/// that a bug?" The arithmetic was right — with the 13 stored days on screen, last-7 averaged 62 and
/// the earlier bucket 69, so −7 was correct — but the FRAMING was wrong in two ways:
///
///  1. The "prev 7" bucket held only SIX days while the label claimed seven. A 7-day mean compared
///     against a 6-day mean is not like-for-like, and printing it as one is how a trend gets misread.
///  2. Both halves were hard-coded at 7 regardless of the selected window, so 14d / 30d / 90d all
///     produced the identical figure — the window selector visibly did nothing to that footer.
///
/// These pin the pure comparison helper: the buckets scale with the window, and a delta is produced
/// ONLY when both halves are full.
@MainActor
final class ScoreTrendComparisonTests: XCTestCase {

    /// The values from the reported screenshot: 13 scored days ending at 62.
    private let reported: [Double] = [56, 87, 67, 77, 63, 64, 65, 72, 65, 54, 56, 60, 62]

    private func series(_ values: [Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        // Days ending today, so every value falls inside any window under test.
        for (i, v) in values.enumerated() {
            let daysAgo = values.count - 1 - i
            let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
            out[Self.key(d)] = v
        }
        return out
    }

    private static func key(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    /// The exact case reported: 13 days in a 14-day window cannot fill two 7-day buckets, so no
    /// delta is claimed at all. Previously this printed "vs prev 7" over a six-day bucket.
    func testAPartialBucketProducesNoComparison() {
        let c = ScoreTrendSection.comparison(valuesByDay: series(reported), windowDays: 14)
        XCTAssertNil(c, "13 days cannot fill 7 + 7; a 7-vs-6 delta must not be labelled 'prev 7'")
    }

    /// One more day and the comparison becomes honest — both buckets hold seven.
    func testAFullWindowProducesASevenVsSevenComparison() {
        let c = ScoreTrendSection.comparison(valuesByDay: series([55] + reported), windowDays: 14)
        let unwrapped = try? XCTUnwrap(c)
        XCTAssertEqual(unwrapped?.n, 7, "a 14-day window compares 7 against 7")
        // recent = the last seven of the reported run; prior = the seven before them.
        XCTAssertEqual(unwrapped?.recent ?? 0, 62.0, accuracy: 0.001)
        XCTAssertEqual(unwrapped?.prior ?? 0, (55.0 + 56 + 87 + 67 + 77 + 63 + 64) / 7, accuracy: 0.001)
    }

    /// The bucket size follows the WINDOW, which is what makes the selector mean something. The old
    /// footer produced the same figure at every window.
    func testTheBucketScalesWithTheWindow() {
        let long = series((0..<60).map { Double(50 + $0 % 10) })
        XCTAssertEqual(ScoreTrendSection.comparison(valuesByDay: long, windowDays: 14)?.n, 7)
        XCTAssertEqual(ScoreTrendSection.comparison(valuesByDay: long, windowDays: 30)?.n, 15)
    }

    /// Capped at 30 so a 90-day view compares months rather than half-quarters — a 45-day bucket no
    /// longer reads as "recently", which is what the comparison is for.
    func testTheBucketIsCappedSoLongWindowsStillCompareRecentPeriods() {
        let long = series((0..<120).map { Double(50 + $0 % 10) })
        XCTAssertEqual(ScoreTrendSection.comparison(valuesByDay: long, windowDays: 90)?.n, 30)
    }

    /// Only days INSIDE the window count, or a 14-day comparison would quietly draw on older data.
    func testDaysOutsideTheWindowAreExcluded() {
        var values = series((0..<10).map { _ in 60.0 })
        // A very old, extreme day that must not reach a 14-day comparison.
        let old = Calendar.current.date(byAdding: .day, value: -200, to: Date())!
        values[Self.key(old)] = 5
        let c = ScoreTrendSection.comparison(valuesByDay: values, windowDays: 14)
        XCTAssertNil(c, "10 in-window days cannot fill 7 + 7, and the 200-day-old row must not help")
    }

    /// A window too short to halve meaningfully yields nothing rather than comparing single days.
    func testAWindowTooShortToHalveYieldsNoComparison() {
        XCTAssertNil(ScoreTrendSection.comparison(valuesByDay: series(reported), windowDays: 3))
    }
}

/// The "Week in review" card must mean a WEEK.
///
/// 260906. The chart footer's comparison deliberately scales with the selected window (30d compares
/// 15 vs 15), which is right for a footer that sits under a 30-day chart. But a card headed "Week in
/// review" reading fifteen days because the picker moved would be the same class of mislabelling as
/// the "prev 7" bug this file exists for — the label and the arithmetic have to agree.
///
/// So the card asks over a fixed 14-day window regardless of the chart's selection, and self-hides
/// unless both weeks are complete.
@MainActor
final class WeekInReviewScopeTests: XCTestCase {

    private func series(_ values: [Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (i, v) in values.enumerated() {
            let daysAgo = values.count - 1 - i
            let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            out[f.string(from: d)] = v
        }
        return out
    }

    /// Fourteen days give exactly two full weeks: 7 vs 7, whatever the chart is showing.
    func testTheCardComparesSevenAgainstSeven() {
        let values = series((0..<14).map { Double(50 + $0) })
        let c = ScoreTrendSection.comparison(valuesByDay: values, windowDays: 14)
        XCTAssertEqual(c?.n, 7, "a week-in-review card must compare a week against a week")
        // recent = the last seven (57...63), prior = the seven before (50...56).
        XCTAssertEqual(c?.recent ?? 0, (57.0 + 58 + 59 + 60 + 61 + 62 + 63) / 7, accuracy: 0.001)
        XCTAssertEqual(c?.prior ?? 0, (50.0 + 51 + 52 + 53 + 54 + 55 + 56) / 7, accuracy: 0.001)
    }

    /// Under two full weeks, the card shows nothing rather than comparing a short week to a long one.
    func testThirteenDaysIsNotTwoWeeks() {
        XCTAssertNil(ScoreTrendSection.comparison(valuesByDay: series((0..<13).map { _ in 60.0 }),
                                                  windowDays: 14),
                     "13 days cannot fill two weeks; the card must hide rather than mislabel")
    }

    /// The card's own window is INDEPENDENT of the chart's selection. This is the property that keeps
    /// the heading honest: selecting 90d must not turn "this week" into "this month".
    func testTheCardsWindowIsIndependentOfTheChartSelection() {
        let values = series((0..<120).map { Double(50 + $0 % 20) })
        let weekly = ScoreTrendSection.comparison(valuesByDay: values, windowDays: 14)
        let quarterly = ScoreTrendSection.comparison(valuesByDay: values, windowDays: 90)
        XCTAssertEqual(weekly?.n, 7, "the card always asks over 14 days")
        XCTAssertEqual(quarterly?.n, 30, "the chart footer legitimately scales with its own window")
        XCTAssertNotEqual(weekly?.n, quarterly?.n,
                          "if these matched, the card could not be showing a week")
    }
}
