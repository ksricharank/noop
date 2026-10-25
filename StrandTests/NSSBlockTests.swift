import XCTest
import StrandAnalytics
@testable import Strand

/// The coach's NSS block (`AICoachEngine.nssSummary`, 261024). Pinned because the Today NSS bullet
/// quotes these figures verbatim: "now" must be the snapshot's current reading (the number the Stress
/// tab and the Today card show), the HRV parts are words rather than residuals, and an unscored "now"
/// (running, an unlearnt pace) or a model still learning says so instead of passing off a guess.
/// 261024d: the scale is measured up from a CALM reference, and my typical and "unusual" levels are
/// stated beside it; the band words read the reading against them.
final class NSSBlockTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    private func reading(_ ts: Int, _ nss: Double, pace: NormalizedStress.Pace = .walk, hr: Double = 106,
                         calm: Double = 97, zSI: Double? = 1.6, zRMSSD: Double? = 1.7) -> NormalizedStress.Reading {
        .init(ts: ts, nss: nss, raw: nss, pace: pace, hr: hr, hrCalm: calm, zHR: 1.5, zSI: zSI, zRMSSD: zRMSSD)
    }

    private func snapshot(_ readings: [NormalizedStress.Reading], unusualEpisode: NormalizedStress.Episode? = nil,
                          unscored: NormalizedStress.Window? = nil, typical: Double? = 30,
                          unusual: Double? = 62) -> NormalizedStressStore.Snapshot {
        .init(current: readings.last, readings: readings,
              dayMean: readings.isEmpty ? nil : readings.map(\.nss).reduce(0, +) / Double(readings.count),
              lastUnusual: unusualEpisode, modelDays: 21, modelWindows: 2_400, modelledPaces: [.still, .walk],
              computedAt: 0, unscoredNow: unscored, typical: typical, unusualLevel: unusual, baselineDays: 21)
    }

    func testNowTheNormalTheDayAndTheWhy() {
        let base = 10 * 3600   // 10:00 UTC
        let rs = (0...61).map { reading(base + $0 * 60, $0 < 31 ? 30 : 70) }
        let block = AICoachEngine.nssSummary(snapshot(rs), now: base + 61 * 60 + 120, timeZone: utc)!
        let lines = block.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("NSS — NORMALIZED STRESS (0–100; 0 = my calm state for the pace"), block)
        XCTAssertTrue(lines[0].contains("over the last 21 days"), block)
        XCTAssertEqual(lines[1], "  my normal over the last 21 days: typical 30; unusual for me from 62.")
        XCTAssertEqual(lines[2], "  now 70 (unusual for me — 40 above my typical 30), while walking — heart rate 106 bpm vs my calm 97 at this pace (+9); "
                       + "HRV well below my calm level; beat pattern much more rigid than when calm.")
        XCTAssertTrue(lines[3].hasPrefix("  today: average 50 over 62 scored minutes; every 30 min: 10:30 30 · 11:00 70"), block)
    }

    func testAnUnscoredNowSaysWhyTheFigureIsOlder() {
        let rs = [reading(36_000, 35)]
        let run = NormalizedStress.Window(endTs: 36_600, pace: .run, hr: 160, lnSI: nil, lnRMSSD: nil)
        let block = AICoachEngine.nssSummary(snapshot(rs, unscored: run), now: 36_660, timeZone: utc)!
        XCTAssertTrue(block.contains("right now I am running — not scored"), block)
        XCTAssertTrue(block.contains("now 35 (a little above my typical — 5 above my typical 30)"), block)
    }

    /// 261025: pickleball read as stress. Exercise and its recovery are unscored, and the block says so —
    /// both for "now" and as today's minutes left out — so the coach cannot call a game stress.
    func testExerciseNowAndTodaysExerciseMinutesAreNamed() {
        let rs = [reading(36_000, 22)]
        let game = NormalizedStress.Window(endTs: 36_600, pace: .walk, hr: 136, lnSI: nil, lnRMSSD: nil)
        var s = snapshot(rs, unscored: game)
        s.unscoredExercise = .exercise
        s.exerciseMinutesToday = 75
        s.recoveryMinutesToday = 30
        let block = AICoachEngine.nssSummary(s, now: 36_660, timeZone: utc)!
        XCTAssertTrue(block.contains("right now I am exercising — not scored"), block)
        XCTAssertFalse(block.contains("too little history"), block)
        XCTAssertTrue(block.contains("exercise today: 75 min, plus 30 min of recovery after it, left out of NSS"), block)
        s.unscoredExercise = .recovery
        XCTAssertTrue(AICoachEngine.nssSummary(s, now: 36_660, timeZone: utc)!
            .contains("right now I am recovering from exercise — not scored for 30 min after it"))
    }

    func testAnOldReadingNamesItsAge() {
        let block = AICoachEngine.nssSummary(snapshot([reading(36_000, 40)]), now: 36_000 + 25 * 60,
                                             timeZone: utc)!
        XCTAssertTrue(block.contains("while walking, from 25 min ago"), block)
    }

    func testTheLastUnusualStretchIsNamedWithItsParts() {
        let peak = reading(50_400, 78, pace: .still, hr: 74, calm: 63, zSI: nil, zRMSSD: nil)
        let e = NormalizedStress.Episode(startTs: 49_800, endTs: 51_000, peak: peak)
        let block = AICoachEngine.nssSummary(snapshot([reading(54_000, 32)], unusualEpisode: e),
                                             now: 54_060, timeZone: utc)!
        XCTAssertTrue(block.contains("last unusual stretch today: 13:50–14:10, peak 78 while still — heart rate 74 bpm "
                                     + "vs my calm 63 at this pace (+11); no clean HRV reading in that window."), block)
    }

    func testLearningAndNoReadingSaySo() {
        var learning = NormalizedStressStore.Snapshot.empty
        learning.modelDays = 3
        XCTAssertTrue(AICoachEngine.nssSummary(learning, now: 0, timeZone: utc)!
            .contains("still learning my calm state — 3 of 21 days of history so far; no score yet."))
        var none = NormalizedStressStore.Snapshot.empty
        none.modelledPaces = [.still]
        XCTAssertTrue(AICoachEngine.nssSummary(none, now: 0, timeZone: utc)!.contains("no reading yet today."))
    }

    /// 261024b: past daily averages ride along (oldest first, today excluded), for the trend reads.
    func testPastDailyAveragesRideAlong() {
        let line = AICoachEngine.nssDailyLine(["2026-10-20": 52.4, "2026-10-22": 47, "2026-10-23": 61],
                                              today: "2026-10-23")
        XCTAssertEqual(line, "  daily averages, oldest first: 10-20 52 · 10-22 47.")
        XCTAssertNil(AICoachEngine.nssDailyLine(["2026-10-23": 61], today: "2026-10-23"))
    }

    /// The words read a reading against MY normal; before there is one, against the fixed scale.
    /// 261024g: the words carry the gap, and "about" means within 3 — the maintainer's bullet read
    /// 18 as "sitting right at" a typical of 27.
    func testBandWordsFollowMyNormalThenTheScale() {
        XCTAssertEqual(AICoachEngine.nssBandWord(62, typical: 30, unusual: 62), "unusual for me — 32 above my typical 30")
        XCTAssertEqual(AICoachEngine.nssBandWord(41, typical: 30, unusual: 62), "well above my typical — 11 above my typical 30")
        XCTAssertEqual(AICoachEngine.nssBandWord(35, typical: 30, unusual: 62), "a little above my typical — 5 above my typical 30")
        XCTAssertEqual(AICoachEngine.nssBandWord(32, typical: 30, unusual: 62), "about my typical 30")
        XCTAssertEqual(AICoachEngine.nssBandWord(18, typical: 27, unusual: 62),
                       "a little below my typical, calmer than usual — 9 below my typical 27")
        XCTAssertEqual(AICoachEngine.nssBandWord(10, typical: 27, unusual: 62),
                       "well below my typical, calmer than usual — 17 below my typical 27")
        XCTAssertEqual(AICoachEngine.nssBandWord(12, typical: nil, unusual: nil), "close to my calm state")
        XCTAssertEqual(AICoachEngine.nssBandWord(70, typical: nil, unusual: nil), "far above calm")
    }
}
