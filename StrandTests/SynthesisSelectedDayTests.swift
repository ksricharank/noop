import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Guards that the synthesis n/t strip follows the day picker — and that the widget / Live Activity /
/// coach path does NOT.
///
/// The 260906 report: picking a previous date on Today moved the rest of the synthesis section but left
/// Steps, Cal, Effort and Water showing today's numbers. `DailyTargetsStrip` took no day at all and
/// called `repo.cachedLiveTargets()`, which is anchored to today three separate ways (`now: Date()` →
/// `todayKey`, a `cachedWidgetAnchor(now:)` behind every denominator, and the today-only hydration
/// cache) — and whose memo key does not include the browsed day, so even a corrected caller would have
/// been handed today's bundle back.
///
/// The second half matters as much as the first. `cachedLiveTargets` also feeds the Live Activity, the
/// widget faces, the pacing notifications and the coach; a widget quoting a browsed historical day
/// would be a worse bug than the one being fixed. So these tests pin BOTH: past days take the explicit
/// path, and today's path keeps its default.
@MainActor
final class SynthesisSelectedDayTests: XCTestCase {

    private func stripSource() throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Strand/Screens/DailyTargetsStrip.swift"),
                          encoding: .utf8)
    }

    private func source(_ rel: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    /// The strip must accept a day. Without the parameter there is no way for the picker to reach it,
    /// which is the whole defect.
    func testTheStripAcceptsADay() throws {
        let src = try stripSource()
        XCTAssertTrue(src.contains("var day: String?"),
                      "DailyTargetsStrip must take the day to show; without it the picker cannot reach "
                      + "the four n/t pairs and they stay pinned to today")
    }

    /// A browsed day must NOT fall back to the today-anchored bundle. Falling back would print today's
    /// numbers under a past date — data, not an absence, and the original bug wearing a new hat.
    func testABrowsedDayNeverFallsBackToTheLiveBundle() throws {
        let src = try stripSource()
        XCTAssertFalse(src.contains("?? repo.cachedLiveTargets()"),
                       "a browsed day with no row must render empty, NOT fall back to cachedLiveTargets() "
                       + "— that prints today's numbers under a past date")
        XCTAssertTrue(src.contains("repo.liveTargets(forDay:"),
                      "a browsed day must take the explicit day-scoped read")
    }

    /// Both Today implementations must pass the day. The codebase treats classic/liquid divergence as a
    /// bug, and fixing only one would leave the other stale with nothing to catch it.
    func testBothTodayScreensPassTheSelectedDay() throws {
        for path in ["Strand/Screens/TodayView.swift", "Strand/Liquid/LiquidTodayView.swift"] {
            let src = try source(path)
            XCTAssertTrue(src.contains("DailyTargetsStrip(day:"),
                          "\(path) must pass the selected day into the strip")
            XCTAssertFalse(src.contains("DailyTargetsStrip()"),
                           "\(path) still constructs the strip with no day — that instance stays on today")
        }
    }

    /// The today path keeps its memo and its default. If a refactor routed today's read through the
    /// explicit path too, every widget publish would lose the memo that exists to keep it cheap.
    func testTodayStillTakesTheMemoizedPath() throws {
        let src = try stripSource()
        XCTAssertTrue(src.contains("guard let day else { return repo.cachedLiveTargets() }"),
                      "offset 0 must still read the memoized live bundle every other surface uses")
    }

    /// The day-scoped read must not be wired into the surfaces that have to stay on today.
    func testTheWidgetAndCoachPathsStayOnToday() throws {
        for path in ["StrandiOS/Widgets/WidgetPublish.swift", "Strand/AI/AICoach.swift"] {
            let src = try source(path)
            XCTAssertFalse(src.contains("liveTargets(forDay:"),
                           "\(path) must stay pinned to today — a widget or a coach line quoting a "
                           + "browsed historical day is a worse bug than the stale strip this fixes")
        }
    }

    // MARK: - Behaviour, not just wiring

    private func metric(day: String, strain: Double?, kcal: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 480, efficiency: nil, deepMin: nil,
                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: 60,
                    avgHrv: nil, recovery: 70, strain: strain, exerciseCount: nil,
                    activeKcalEst: kcal)
    }

    /// The source checks above prove the day REACHES the derivation; this proves the derivation
    /// actually answers for that day. Without it, a `liveTargets(forDay:)` that accepted the argument
    /// and ignored it would satisfy every other test in this file.
    ///
    /// Pinned on the pure static `liveTargets`, which is what the day-scoped method calls — the method
    /// itself needs a live Repository (and a store), which a unit test has no business standing up.
    func testThePureDerivationAnswersForTheDayItIsGiven() {
        let days = [metric(day: "2026-09-01", strain: 5, kcal: 500),
                    metric(day: "2026-09-02", strain: 9, kcal: 1500)]
        let profile = UserProfile()

        // The browsed day, scored with only what was known THEN — the filter the day-scoped read applies.
        let past = Repository.liveTargets(days: days.filter { $0.day <= "2026-09-01" },
                                          charge: 70, restScore: nil, profile: profile,
                                          todayKey: "2026-09-01")
        let today = Repository.liveTargets(days: days, charge: 70, restScore: nil,
                                           profile: profile, todayKey: "2026-09-02")

        XCTAssertEqual(past.kcalToday, 500, "the browsed day's numerator must be that day's own")
        XCTAssertEqual(today.kcalToday, 1500)
        XCTAssertNotEqual(past.kcalToday, today.kcalToday,
                          "if these match, the fixture cannot detect the bug it exists to catch")
    }

    /// The coach synthesis is written about TODAY (`synthesisIsCurrent` is a freshness check, not a day
    /// match), so it must not be shown under a browsed past date in either Today implementation.
    func testTheCoachParagraphIsGatedOnToday() throws {
        for path in ["Strand/Screens/TodayView.swift", "Strand/Liquid/LiquidTodayView.swift"] {
            let src = try source(path)
            XCTAssertTrue(src.contains("selectedDayOffset == 0, let ai = coach.synthesisText"),
                          "\(path) must gate the coach synthesis on offset 0; it narrates today's "
                          + "numbers and would otherwise appear under an older date")
        }
    }
}
