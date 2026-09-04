import XCTest
@testable import Strand
import StrandAnalytics
import WhoopStore

/// The day-selection and input-assembly logic behind the nightly day-quality score.
///
/// The arithmetic itself is pinned in `DayQualityScoreTests` (StrandAnalytics, no app needed). What
/// is tested here is the part that can only be wrong in the app: which days get scored, and whether
/// each day is graded against the targets and baselines it should be.
@MainActor
final class DayQualityComputerTests: XCTestCase {

    private func metric(day: String, recovery: Double? = 60, strain: Double? = 30,
                        sleep: Double? = 450, hrv: Double? = 58, rhr: Int? = 52,
                        steps: Int? = 8_000, kcal: Double? = 2_200,
                        efficiency: Double? = 0.9) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: efficiency, deepMin: nil,
                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: hrv, recovery: recovery, strain: strain, exerciseCount: nil,
                    steps: steps, activeKcalEst: kcal)
    }

    private func history(_ days: [String]) -> [DailyMetric] { days.map { metric(day: $0) } }

    private var profile: UserProfile {
        UserProfile(weightKg: 78, heightCm: 178, age: 40, sex: "male")
    }

    // MARK: - Which days get scored

    /// The score is a closed book about a FINISHED day. Today must never be scored: a partial day
    /// would publish a low number at breakfast and revise it by bedtime, which is the churn the
    /// "computed at the end of a night" requirement exists to prevent.
    func testTodayIsNeverScored() {
        let picked = DayQualityComputer.daysToScore(
            scoredDays: ["2026-09-01", "2026-09-02", "2026-09-03"],
            todayKey: "2026-09-03")
        XCTAssertEqual(picked, ["2026-09-01", "2026-09-02"])
        XCTAssertFalse(picked.contains("2026-09-03"), "today is still in progress")
    }

    /// A future-dated row (a strap clock that ran ahead, an import) must not be scored either.
    func testFutureDaysAreNotScored() {
        let picked = DayQualityComputer.daysToScore(
            scoredDays: ["2026-09-02", "2026-09-09"], todayKey: "2026-09-03")
        XCTAssertEqual(picked, ["2026-09-02"])
    }

    /// Duplicates collapse and the result is ordered, so a caller handing over the same day twice
    /// writes one point rather than two.
    func testDaysAreDedupedAndOrdered() {
        let picked = DayQualityComputer.daysToScore(
            scoredDays: ["2026-09-02", "2026-09-01", "2026-09-02"], todayKey: "2026-09-05")
        XCTAssertEqual(picked, ["2026-09-01", "2026-09-02"])
    }

    // MARK: - The day is graded against its OWN context

    /// A past day must not be graded against a readiness read that includes days AFTER it — that
    /// would grade Monday using Wednesday's data, which the wearer could never have acted on.
    ///
    /// Asserted by consequence: the same day scored against a history that stops at it, and against
    /// one that continues past it with wildly different rows, must produce the same input.
    func testAPastDayIsNotGradedUsingLaterDays() throws {
        let upToDay = history(["2026-08-28", "2026-08-29", "2026-08-30"])
        var withFuture = upToDay
        // Days after the graded one, deliberately extreme.
        withFuture.append(metric(day: "2026-08-31", recovery: 5, strain: 99, hrv: 10, rhr: 90))
        withFuture.append(metric(day: "2026-09-01", recovery: 5, strain: 99, hrv: 10, rhr: 90))

        let targetsA = DayQualityComputer.targetsByDay(
            history: upToDay, profile: profile,
            onlyDays: DayQualityComputer.targetDaysNeeded(toScore: ["2026-08-30"], history: upToDay))
        let targetsB = DayQualityComputer.targetsByDay(
            history: withFuture, profile: profile,
            onlyDays: DayQualityComputer.targetDaysNeeded(toScore: ["2026-08-30"], history: withFuture))

        let a = try XCTUnwrap(DayQualityComputer.input(for: "2026-08-30", history: upToDay,
                                                       profile: profile, targetsByDay: targetsA,
                                                       waterCups: 10, waterTargetCups: 20))
        let b = try XCTUnwrap(DayQualityComputer.input(for: "2026-08-30", history: withFuture,
                                                       profile: profile, targetsByDay: targetsB,
                                                       waterCups: 10, waterTargetCups: 20))
        XCTAssertEqual(a, b, "later days leaked into an earlier day's grade")
    }

    /// A day must not be its own baseline. If the graded day were included in its own HRV/RHR
    /// median, every day would sit at its own centre and the whole recovery half would go inert.
    func testTheGradedDayIsExcludedFromItsOwnBaseline() throws {
        var rows = history(["2026-08-25", "2026-08-26", "2026-08-27"])   // hrv 58 throughout
        rows.append(metric(day: "2026-08-28", hrv: 100, rhr: 40))        // a standout day
        let targets = DayQualityComputer.targetsByDay(
            history: rows, profile: profile,
            onlyDays: DayQualityComputer.targetDaysNeeded(toScore: ["2026-08-28"], history: rows))
        let input = try XCTUnwrap(DayQualityComputer.input(for: "2026-08-28", history: rows,
                                                          profile: profile, targetsByDay: targets,
                                                          waterCups: nil, waterTargetCups: nil))
        XCTAssertEqual(input.hrv, 100)
        XCTAssertEqual(try XCTUnwrap(input.hrvBaseline), 58, accuracy: 0.001,
                       "the baseline must be the PRIOR days, not including the day being graded")
        XCTAssertEqual(try XCTUnwrap(input.restingHrBaseline), 52, accuracy: 0.001)
    }

    /// A day with no stored row is not scored — that is a data gap, not a bad day.
    func testADayWithNoRowYieldsNoInput() {
        let rows = history(["2026-08-25", "2026-08-26"])
        XCTAssertNil(DayQualityComputer.input(for: "2026-08-27", history: rows, profile: profile,
                                              targetsByDay: [:], waterCups: nil,
                                              waterTargetCups: nil))
    }

    // MARK: - The load factor's window

    /// Below three prior days the factor is inert rather than guessing off one outlier.
    func testTheRecentAverageNeedsThreePriorDays() {
        let two = ["2026-08-01": 40, "2026-08-02": 44]
        XCTAssertNil(DayQualityComputer.recentAvgEffortTarget(before: "2026-08-03",
                                                              targetsByDay: two))
        var three = two
        three["2026-08-03"] = 48
        XCTAssertNotNil(DayQualityComputer.recentAvgEffortTarget(before: "2026-08-04",
                                                                 targetsByDay: three))
    }

    /// Only PRIOR days count, and only the trailing window — a target from after the graded day
    /// cannot inform how demanding that day was.
    func testTheRecentAverageUsesOnlyPriorDaysInTheWindow() throws {
        var table: [String: Int] = [:]
        for d in 1...20 { table[String(format: "2026-08-%02d", d)] = 40 }
        // A huge target AFTER the graded day must be ignored entirely.
        table["2026-08-25"] = 900
        let avg = try XCTUnwrap(DayQualityComputer.recentAvgEffortTarget(before: "2026-08-21",
                                                                        targetsByDay: table))
        XCTAssertEqual(avg, 40, accuracy: 0.001, "a later day's target leaked into the average")

        // And the window is bounded: only the last N prior days participate.
        var mixed: [String: Int] = [:]
        for d in 1...5 { mixed[String(format: "2026-08-%02d", d)] = 1_000 }   // long ago, extreme
        for d in 6...25 { mixed[String(format: "2026-08-%02d", d)] = 50 }     // recent, normal
        let bounded = try XCTUnwrap(DayQualityComputer.recentAvgEffortTarget(before: "2026-08-26",
                                                                            targetsByDay: mixed))
        XCTAssertEqual(bounded, 50, accuracy: 0.001,
                       "days outside the \(DayQualityComputer.recentTargetWindowDays)-day window "
                       + "must not be averaged in")
    }

    // MARK: - Cost control

    /// `targetsByDay` must price only what is needed. `Repository.liveTargets` runs a full-history
    /// readiness sort whose memo cannot help here (each call gets a different slice), so pricing
    /// every row would make the nightly pass scale with total history — a wearer with two years of
    /// data would pay hundreds of sorts per night.
    func testOnlyTheDaysNeededArePriced() {
        let rows = history((1...60).map { String(format: "2026-07-%02d", min($0, 31)) }
            + (1...29).map { String(format: "2026-08-%02d", $0) })
        let toScore = ["2026-08-28", "2026-08-29"]
        let needed = DayQualityComputer.targetDaysNeeded(toScore: toScore, history: rows)

        XCTAssertTrue(needed.isSuperset(of: toScore), "the scored days themselves must be priced")
        // Two scored days plus their (overlapping) 14-day trailing windows — far short of the
        // ~90-row history.
        XCTAssertLessThan(needed.count, 20,
                          "pricing must scale with the days being scored, not with total history")
        let priced = DayQualityComputer.targetsByDay(history: rows, profile: profile,
                                                     onlyDays: needed)
        XCTAssertTrue(Set(priced.keys).isSubset(of: needed),
                      "no day outside the requested set may be priced")
    }

    /// An empty request prices nothing at all, rather than falling back to the whole history.
    func testNoDaysRequestedPricesNothing() {
        let rows = history(["2026-08-01", "2026-08-02"])
        XCTAssertTrue(DayQualityComputer.targetsByDay(history: rows, profile: profile,
                                                      onlyDays: []).isEmpty)
    }

    // MARK: - Rest score normalisation

    /// Efficiency is stored as a fraction on some paths and a percentage on others. Both must read
    /// as the same rest score, or the sleep need this shades would differ by import path.
    func testEfficiencyIsNormalisedFromEitherStoredForm() {
        let asFraction = [metric(day: "2026-08-10", efficiency: 0.91)]
        let asPercent = [metric(day: "2026-08-10", efficiency: 91)]
        XCTAssertEqual(DayQualityComputer.restScoreFor(day: "2026-08-10", history: asFraction), 91)
        XCTAssertEqual(DayQualityComputer.restScoreFor(day: "2026-08-10", history: asPercent), 91)

        // Out-of-range and absent both read as "unknown" rather than a fabricated score.
        let bogus = [metric(day: "2026-08-10", efficiency: 1_200)]
        XCTAssertNil(DayQualityComputer.restScoreFor(day: "2026-08-10", history: bogus))
        let none = [metric(day: "2026-08-10", efficiency: nil)]
        XCTAssertNil(DayQualityComputer.restScoreFor(day: "2026-08-10", history: none))
    }

    // MARK: - The once-per-day latch

    /// Maintainer requirement: computed ONCE, after the night is scored — not continuously. The
    /// engine's derived block runs on every full pass (several times a day), so the latch is what
    /// makes the second and subsequent passes no-ops.
    func testTheLatchMakesASecondPassTheSameDayANoOp() {
        DayQualityPrefs.reset()
        UserDefaults.standard.removeObject(forKey: DayQualityPrefs.K.lastScoredDay)
        UserDefaults.standard.removeObject(forKey: DayQualityPrefs.K.lastScoredConfig)
        defer {
            DayQualityPrefs.reset()
            UserDefaults.standard.removeObject(forKey: DayQualityPrefs.K.lastScoredDay)
            UserDefaults.standard.removeObject(forKey: DayQualityPrefs.K.lastScoredConfig)
        }

        XCTAssertFalse(DayQualityPrefs.alreadyScored(day: "2026-09-04"))
        DayQualityPrefs.markScored(day: "2026-09-04")
        XCTAssertTrue(DayQualityPrefs.alreadyScored(day: "2026-09-04"),
                      "a second full pass the same day must not re-score")
        // A new day re-arms.
        XCTAssertFalse(DayQualityPrefs.alreadyScored(day: "2026-09-05"))
    }

    /// The one legitimate reason to re-score early: the wearer moved a slider. A config change must
    /// apply to history immediately rather than waiting for tomorrow's pass.
    func testChangingAKnobReArmsTheLatch() {
        DayQualityPrefs.reset()
        UserDefaults.standard.removeObject(forKey: DayQualityPrefs.K.lastScoredDay)
        UserDefaults.standard.removeObject(forKey: DayQualityPrefs.K.lastScoredConfig)
        defer {
            DayQualityPrefs.reset()
            UserDefaults.standard.removeObject(forKey: DayQualityPrefs.K.lastScoredDay)
            UserDefaults.standard.removeObject(forKey: DayQualityPrefs.K.lastScoredConfig)
        }

        DayQualityPrefs.markScored(day: "2026-09-04")
        XCTAssertTrue(DayQualityPrefs.alreadyScored(day: "2026-09-04"))
        DayQualityPrefs.setExecutionSharePct(75)
        XCTAssertFalse(DayQualityPrefs.alreadyScored(day: "2026-09-04"),
                       "moving the execution split must re-score the history it applies to")
    }

    // MARK: - The narrative's factual half

    /// The model is handed the SCORED BREAKDOWN, not raw rows, so it interprets numbers it cannot
    /// get wrong rather than re-deriving them. This pins that the facts it receives match the card.
    func testTheNarrativeStatusRestatesTheScoreItWasGiven() throws {
        let input = DayQualityScore.DayInput(
            steps: 9_000, stepsTarget: 8_000, kcal: 2_100, kcalTarget: 2_250,
            effort: 40, effortTarget: 54, waterCups: 12, waterTargetCups: 21,
            sleepMin: 400, sleepNeedMin: 485, hrv: 50, hrvBaseline: 58,
            restingHr: 56, restingHrBaseline: 52)
        let score = try XCTUnwrap(DayQualityScore.score(input))
        let status = AICoachEngine.dayQualityStatus(day: "2026-09-03", score: score)

        XCTAssertTrue(status.contains("Overall score: \(score.total) of 100"),
                      "the model must be told the SAME total the card displays: \(status)")
        XCTAssertTrue(status.contains("2026-09-03"))
        // Every component's evidence is present, so the prose can cite specifics.
        for c in score.components {
            XCTAssertTrue(status.contains(c.label), "missing component \(c.label)")
        }
    }

    /// A missing signal must be labelled as NOT RECORDED, or the model will describe a data gap as
    /// a bad result — the same failure mode the score's own renormalisation exists to prevent.
    func testTheNarrativeStatusMarksMissingDataAsUnrecorded() throws {
        var input = DayQualityScore.DayInput(
            steps: 8_000, stepsTarget: 8_000, kcal: 2_250, kcalTarget: 2_250,
            effort: 54, effortTarget: 54, waterCups: 21, waterTargetCups: 21)
        input.hrv = nil; input.hrvBaseline = nil
        let score = try XCTUnwrap(DayQualityScore.score(input))
        let status = AICoachEngine.dayQualityStatus(day: "2026-09-03", score: score)
        XCTAssertTrue(status.contains("NOT RECORDED"),
                      "an absent signal must be flagged so it is not narrated as a zero: \(status)")
        XCTAssertTrue(status.contains("HRV"))
    }

    // MARK: - The coach's view of the trend

    /// The history block must state the DIRECTION, not just the numbers: the whole point of the
    /// score is that the wearer is trying to move it, and a bare list invites the model to
    /// characterise a trend it has not been told about.
    func testTheHistoryBlockCarriesBothAveragesAndTheChange() {
        // Fourteen ascending days: the last 7 average clearly above the previous 7.
        let series: [(day: String, value: Double)] = (1...14).map {
            (day: String(format: "2026-08-%02d", $0), value: Double(50 + $0 * 2))
        }
        let block = AICoachEngine.dayQualityHistoryLines(series: series)
        let text = try? XCTUnwrap(block)
        XCTAssertNotNil(text)
        guard let text else { return }
        XCTAssertTrue(text.contains("Last 7 days average"), text)
        XCTAssertTrue(text.contains("Previous 7 days average"), text)
        XCTAssertTrue(text.contains("change: +"), "an improving run must be stated as improving: \(text)")
        XCTAssertTrue(text.contains("trending UP"),
                      "the model must be told which direction is the good one")
    }

    /// Under three scored days there is no trend to describe, and a model invited to describe one
    /// produces confident noise.
    func testTheHistoryBlockIsAbsentWithTooFewDays() {
        let two: [(day: String, value: Double)] = [("2026-08-01", 70), ("2026-08-02", 72)]
        XCTAssertNil(AICoachEngine.dayQualityHistoryLines(series: two))
        let three = two + [("2026-08-03", 74)]
        XCTAssertNotNil(AICoachEngine.dayQualityHistoryLines(series: three))
    }

    /// A declining run must read as declining — the sign is the actionable part.
    func testADecliningRunIsReportedAsNegative() throws {
        let series: [(day: String, value: Double)] = (1...14).map {
            (day: String(format: "2026-08-%02d", $0), value: Double(90 - $0 * 2))
        }
        let text = try XCTUnwrap(AICoachEngine.dayQualityHistoryLines(series: series))
        XCTAssertTrue(text.contains("change: -"), text)
    }

    func testMedianHandlesBothParities() {
        XCTAssertEqual(try XCTUnwrap(DayQualityComputer.median([3, 1, 2])), 2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(DayQualityComputer.median([4, 1, 3, 2])), 2.5, accuracy: 0.001)
        XCTAssertNil(DayQualityComputer.median([]))
    }
}
