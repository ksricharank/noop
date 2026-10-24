import XCTest
import StrandAnalytics
@testable import Strand

/// The coach's NSS block (`AICoachEngine.nssSummary`, 261024). Pinned because the Today NSS bullet
/// quotes these figures verbatim: "now" must be the snapshot's current reading (the number the Stress
/// tab and the Today card show), the HRV parts are words rather than residuals, and an unscored "now"
/// (running, an unlearnt pace) or a model still learning says so instead of passing off a guess.
final class NSSBlockTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    private func reading(_ ts: Int, _ nss: Double, pace: NormalizedStress.Pace = .walk, hr: Double = 106,
                         pred: Double = 97, zSI: Double? = 1.2, zRMSSD: Double? = 1.5) -> NormalizedStress.Reading {
        .init(ts: ts, nss: nss, raw: nss, pace: pace, hr: hr, hrPred: pred, zHR: 1.5, zSI: zSI, zRMSSD: zRMSSD)
    }

    private func snapshot(_ readings: [NormalizedStress.Reading], high: NormalizedStress.Episode? = nil,
                          unscored: NormalizedStress.Window? = nil) -> NormalizedStressStore.Snapshot {
        .init(current: readings.last, readings: readings,
              dayMean: readings.isEmpty ? nil : readings.map(\.nss).reduce(0, +) / Double(readings.count),
              lastHigh: high, modelDays: 14, modelWindows: 2_400, modelledPaces: [.still, .walk],
              computedAt: 0, unscoredNow: unscored)
    }

    func testNowTheDayAndTheWhy() {
        let base = 10 * 3600   // 10:00 UTC
        let rs = (0...61).map { reading(base + $0 * 60, $0 < 31 ? 50 : 70) }
        let block = AICoachEngine.nssSummary(snapshot(rs), now: base + 61 * 60 + 120, timeZone: utc)!
        let lines = block.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("NSS — NORMALIZED STRESS (0–100; 50 = my usual for the pace"), block)
        XCTAssertEqual(lines[1], "  now 70 (high), while walking — heart rate 106 bpm vs my usual 97 at this pace (+9); "
                       + "HRV lower than usual at this pace; beat pattern more rigid than usual.")
        XCTAssertTrue(lines[2].hasPrefix("  today: average 60 over 62 scored minutes; every 30 min: 10:30 50 · 11:00 70"), block)
    }

    func testAnUnscoredNowSaysWhyTheFigureIsOlder() {
        let rs = [reading(36_000, 55)]
        let run = NormalizedStress.Window(endTs: 36_600, pace: .run, hr: 160, lnSI: nil, lnRMSSD: nil)
        let block = AICoachEngine.nssSummary(snapshot(rs, unscored: run), now: 36_660, timeZone: utc)!
        XCTAssertTrue(block.contains("right now I am running — not scored"), block)
        XCTAssertTrue(block.contains("now 55 (within my usual range)"), block)
    }

    func testAnOldReadingNamesItsAge() {
        let block = AICoachEngine.nssSummary(snapshot([reading(36_000, 40)]), now: 36_000 + 25 * 60,
                                             timeZone: utc)!
        XCTAssertTrue(block.contains("while walking, from 25 min ago"), block)
    }

    func testTheLastHighIsNamedWithItsParts() {
        let peak = reading(50_400, 78, pace: .still, hr: 74, pred: 63, zSI: nil, zRMSSD: nil)
        let e = NormalizedStress.Episode(startTs: 49_800, endTs: 51_000, peak: peak)
        let block = AICoachEngine.nssSummary(snapshot([reading(54_000, 52)], high: e), now: 54_060, timeZone: utc)!
        XCTAssertTrue(block.contains("last high today: 13:50–14:10, peak 78 while still — heart rate 74 bpm vs my usual 63 "
                                     + "at this pace (+11); no clean HRV reading in that window."), block)
    }

    func testLearningAndNoReadingSaySo() {
        var learning = NormalizedStressStore.Snapshot.empty
        learning.modelDays = 3
        XCTAssertTrue(AICoachEngine.nssSummary(learning, now: 0, timeZone: utc)!
            .contains("still learning my usual — 3 of 14 days of history so far; no score yet."))
        var none = NormalizedStressStore.Snapshot.empty
        none.modelledPaces = [.still]
        XCTAssertTrue(AICoachEngine.nssSummary(none, now: 0, timeZone: utc)!.contains("no reading yet today."))
    }

    func testBandWordsFollowTheStressScreenBands() {
        XCTAssertEqual(AICoachEngine.nssBandWord(67), "high")
        XCTAssertEqual(AICoachEngine.nssBandWord(50), "within my usual range")
        XCTAssertEqual(AICoachEngine.nssBandWord(30), "low — calmer than usual for this pace")
    }
}
