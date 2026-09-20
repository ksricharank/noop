import XCTest
@testable import Strand
import StrandAnalytics

/// The Recap tab's download (260919). The maintainer's stated use is to hand the file to another
/// LLM each morning, so what matters is that the numbers ARRIVE — a summary that silently drops a
/// field is worse than no summary, because the reader cannot tell the difference.
final class DayRecapExportTests: XCTestCase {

    private func score(total: Int = 74) -> DayQualityScore {
        DayQualityScore(
            total: total, executionPoints: 44.2, recoveryPoints: 29.8,
            components: [
                .init(label: "Steps", achieved: 0.82, weight: 0.2, points: 16.4,
                      detail: "7 412 of 8 950 steps"),
                .init(label: "Sleep", achieved: 0.95, weight: 0.25, points: 23.8,
                      detail: "7h 45m of 8h 10m need"),
            ],
            loadFactor: 1.0, missing: ["Water"])
    }

    func testTheHeadlineNumbersAreInTheText() {
        let md = DayRecapExport.markdown(day: "2026-09-19", score: score(), metric: nil)
        XCTAssertTrue(md.contains("2026-09-19"), md)
        XCTAssertTrue(md.contains("74/100"), md)
        XCTAssertTrue(md.contains("44.2"), md)
        XCTAssertTrue(md.contains("29.8"), md)
    }

    /// Every component reaches the file with its evidence. A table that lists the label but drops
    /// the detail would read as complete while being useless to the reader it is written for.
    func testEveryComponentCarriesItsEvidence() {
        let md = DayRecapExport.markdown(day: "2026-09-19", score: score(), metric: nil)
        XCTAssertTrue(md.contains("Steps"), md)
        XCTAssertTrue(md.contains("7 412 of 8 950 steps"), md)
        XCTAssertTrue(md.contains("Sleep"), md)
        XCTAssertTrue(md.contains("7h 45m of 8h 10m need"), md)
        XCTAssertTrue(md.contains("82%"), md)
        XCTAssertTrue(md.contains("95%"), md)
    }

    /// A component that could not be scored is NAMED, not silently omitted: a reader comparing two
    /// days has to know one of them was scored on fewer inputs.
    func testUnscoredComponentsAreNamedNotDropped() {
        let md = DayRecapExport.markdown(day: "2026-09-19", score: score(), metric: nil)
        XCTAssertTrue(md.contains("Water"), md)
    }

    /// An unscored day says so rather than producing a file that looks like a scored one.
    func testAnUnscoredDaySaysSo() {
        let md = DayRecapExport.markdown(day: "2026-09-19", score: nil, metric: nil)
        XCTAssertTrue(md.contains("not scored"), md)
        XCTAssertFalse(md.contains("/100"), "an unscored day must not render a score")
    }

    /// Recent scores give the reader context — one day's number alone supports almost no useful
    /// statement about it.
    func testRecentScoresAreIncludedForContext() {
        let md = DayRecapExport.markdown(day: "2026-09-19", score: score(), metric: nil,
                                         recentScores: ["2026-09-19": 74, "2026-09-18": 61,
                                                        "2026-09-17": 80])
        XCTAssertTrue(md.contains("2026-09-18: 61"), md)
        XCTAssertTrue(md.contains("2026-09-17: 80"), md)
    }

    /// A single day's scores map is not "context" — it is the day itself, and a one-entry list
    /// would just restate the headline.
    func testASingleDayIsNotRenderedAsContext() {
        let md = DayRecapExport.markdown(day: "2026-09-19", score: score(), metric: nil,
                                         recentScores: ["2026-09-19": 74])
        XCTAssertFalse(md.contains("Recent day scores"), md)
    }

    /// The file says what wrote it and when: a stale paste should be recognisable as stale.
    func testTheFileStatesItsProvenance() {
        let md = DayRecapExport.markdown(day: "2026-09-19", score: score(), metric: nil)
        XCTAssertTrue(md.contains("NOOP"), md)
        XCTAssertTrue(md.contains("on-device"), md)
    }

    /// Named for the day it DESCRIBES, not the day it was exported, so re-exporting the same day
    /// overwrites rather than accumulating a pile of near-identical files.
    func testTheFilenameNamesTheDayItDescribes() {
        XCTAssertEqual(DayRecapExport.filename(day: "2026-09-19"), "noop-recap-2026-09-19.md")
    }
}
