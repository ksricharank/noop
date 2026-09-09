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

    // MARK: - Which night the recovery half grades (260906)

    /// The reported bug: "the day quality score seems to use yesterday night's sleep instead of
    /// tonight's sleep (which I count as part of yesterday — i.e., the sleep is the conclusion of the
    /// day)".
    ///
    /// A sleep session is attributed to the day its END falls on, so row D holds the night D-1→D —
    /// the night BEFORE day D's waking hours. Grading day D's steps and effort against that night
    /// graded the work against the sleep that preceded it. The recovery half must read row D+1.
    ///
    /// Distinct sleep values per day make the assertion unambiguous: if the wrong row were read the
    /// value would be 400, not 500.
    func testTheRecoveryHalfGradesTheNightThatConcludesTheDay() {
        let history = [metric(day: "2026-09-01", sleep: 300),
                       metric(day: "2026-09-02", sleep: 400),   // the night that OPENED 09-02
                       metric(day: "2026-09-03", sleep: 500)]   // the night that CONCLUDED it
        let input = DayQualityComputer.input(for: "2026-09-02", history: history, profile: profile,
                                             targetsByDay: [:], waterCups: nil, waterTargetCups: nil)
        XCTAssertEqual(input?.sleepMin, 500,
                       "day 09-02 must be graded against the night that closed it (row 09-03)")
    }

    /// HRV and resting HR are measured during that same night, so they move with it. Leaving them on
    /// row D would make the recovery half incoherent — the sleep after the day against the autonomic
    /// response to the day before it.
    func testHrvAndRestingHrComeFromTheSameConcludingNight() {
        let history = [metric(day: "2026-09-01", hrv: 30, rhr: 70),
                       metric(day: "2026-09-02", hrv: 40, rhr: 60),
                       metric(day: "2026-09-03", hrv: 50, rhr: 50)]
        let input = DayQualityComputer.input(for: "2026-09-02", history: history, profile: profile,
                                             targetsByDay: [:], waterCups: nil, waterTargetCups: nil)
        XCTAssertEqual(input?.hrv, 50, "HRV must come from the concluding night")
        XCTAssertEqual(input?.restingHr, 50, "resting HR must come from the concluding night")
    }

    /// The EXECUTION half stays on the day itself — that is the day's own work, and it was never
    /// wrong. A change that moved everything forward by a day would grade the wrong day entirely.
    func testTheExecutionHalfStaysOnTheDayItself() {
        let history = [metric(day: "2026-09-02", strain: 30, steps: 8_000),
                       metric(day: "2026-09-03", strain: 99, steps: 99_000)]
        let input = DayQualityComputer.input(for: "2026-09-02", history: history, profile: profile,
                                             targetsByDay: [:], waterCups: nil, waterTargetCups: nil)
        XCTAssertEqual(input?.steps, 8_000, "steps are the day's own work")
        XCTAssertEqual(input?.effort, 30, "effort is the day's own work")
    }

    /// With no following row the concluding night has not landed. Every recovery component reports
    /// ABSENT (the scorer renormalises over what is present) rather than the day being graded against
    /// the wrong night — absent is not the same as zero, and not the same as "use yesterday's".
    func testAMissingConcludingNightLeavesTheRecoveryHalfAbsent() {
        let history = [metric(day: "2026-09-01", sleep: 300), metric(day: "2026-09-02", sleep: 400)]
        let input = DayQualityComputer.input(for: "2026-09-02", history: history, profile: profile,
                                             targetsByDay: [:], waterCups: nil, waterTargetCups: nil)
        XCTAssertNil(input?.sleepMin, "no concluding night → absent, never the preceding one")
        XCTAssertNil(input?.hrv)
        XCTAssertNil(input?.restingHr)
        XCTAssertEqual(input?.steps, 8_000, "the execution half is still gradeable")
    }

    /// The baseline must exclude the night being graded, or a night becomes its own yardstick and the
    /// recovery half flattens to the baseline for every day.
    func testTheBaselineExcludesTheNightBeingGraded() {
        let history = [metric(day: "2026-09-01", hrv: 30),
                       metric(day: "2026-09-02", hrv: 30),
                       metric(day: "2026-09-03", hrv: 90)]   // the graded night, a big outlier
        let input = DayQualityComputer.input(for: "2026-09-02", history: history, profile: profile,
                                             targetsByDay: [:], waterCups: nil, waterTargetCups: nil)
        XCTAssertEqual(input?.hrv, 90, "the graded value is the concluding night's")
        XCTAssertEqual(input?.hrvBaseline, 30,
                       "the 90 must not be inside its own baseline — that would flatten the score")
    }

    /// Day arithmetic across a month boundary, where a naive string increment breaks.
    func testTheConcludingNightCrossesAMonthBoundary() {
        XCTAssertEqual(DayQualityComputer.nextDayKey("2026-09-30"), "2026-10-01")
        XCTAssertEqual(DayQualityComputer.nextDayKey("2026-12-31"), "2027-01-01")
        XCTAssertEqual(DayQualityComputer.nextDayKey("2028-02-28"), "2028-02-29", "leap year")
        XCTAssertNil(DayQualityComputer.nextDayKey("not-a-day"))
    }

    // MARK: - Which days get scored

    /// The score is a closed book about a FINISHED day. Today must never be scored: a partial day
    /// would publish a low number at breakfast and revise it by bedtime, which is the churn the
    /// "computed at the end of a night" requirement exists to prevent.
    func testTodayIsNeverScored() {
        let picked = DayQualityComputer.daysToScore(
            scoredDays: ["2026-09-01", "2026-09-02", "2026-09-03"],
            todayKey: "2026-09-03")
        // 260906: 09-02 is still scorable — the night that CONCLUDES it is the one that ENDED on
        // the morning of 09-03, and that row exists even though 09-03's own day is in progress. The
        // concluding night is banked at wake-up, hours before the day it is dated to is finished.
        XCTAssertEqual(picked, ["2026-09-01", "2026-09-02"])
        XCTAssertFalse(picked.contains("2026-09-03"), "today is still in progress")
    }

    /// A future-dated row (a strap clock that ran ahead, an import) must not be scored either.
    func testFutureDaysAreNotScored() {
        // 09-02's concluding night would sit on 09-03, which is absent from the history here, so
        // nothing is scorable — the future-dated 09-09 row is no help to it.
        let picked = DayQualityComputer.daysToScore(
            scoredDays: ["2026-09-02", "2026-09-09"], todayKey: "2026-09-03")
        XCTAssertEqual(picked, [])
        XCTAssertFalse(picked.contains("2026-09-09"), "a future-dated row is never scored")
    }

    /// Duplicates collapse and the result is ordered, so a caller handing over the same day twice
    /// writes one point rather than two.
    func testDaysAreDedupedAndOrdered() {
        // 09-03 is present so 09-02's concluding night exists; 09-03 itself has no 09-04 row and is
        // therefore not yet scorable. Duplicates of 09-02 must still collapse to one entry.
        let picked = DayQualityComputer.daysToScore(
            scoredDays: ["2026-09-02", "2026-09-01", "2026-09-02", "2026-09-03"],
            todayKey: "2026-09-05")
        XCTAssertEqual(picked, ["2026-09-01", "2026-09-02"])
    }

    /// The backfill is a ONE-TIME event, then one new day per day (260904, maintainer).
    ///
    /// First pass: nothing is stored, so every finished day is scored. Steady state: only the day
    /// that has just finished. A finished day's inputs are fixed, so re-deriving its score nightly
    /// is work that cannot change an answer.
    func testTheFirstPassBackfillsAndLaterPassesScoreOnlyTheNewDay() {
        let history = (1...10).map { String(format: "2026-09-%02d", $0) }

        // First run: empty series → the whole finished history.
        // 260906: the LAST day of the run (09-10) has no 09-11 row, so its concluding night has not
        // landed — nine of the ten backfill, not ten.
        let first = DayQualityComputer.daysToScore(scoredDays: history, todayKey: "2026-09-11",
                                                   alreadyScored: [])
        XCTAssertEqual(first, Array(history.dropLast()),
                       "the first pass backfills every day whose concluding night is in")

        // Next day, with those nine stored and the 09-11 row landed: 09-10 becomes scorable, because
        // its concluding night now exists. Still exactly one new day per day.
        let stored = Set(history.dropLast())
        let second = DayQualityComputer.daysToScore(scoredDays: history + ["2026-09-11"],
                                                    todayKey: "2026-09-12",
                                                    alreadyScored: stored)
        // 09-11 itself is NOT scorable yet: its own concluding night would sit on a 09-12 row that
        // does not exist. Exactly one new day per day, just shifted back by one.
        XCTAssertEqual(second, ["2026-09-10"],
                       "the day whose concluding night has just landed")

        // Same inputs again (a second full pass): nothing at all.
        XCTAssertTrue(DayQualityComputer.daysToScore(scoredDays: history, todayKey: "2026-09-11",
                                                     alreadyScored: Set(history)).isEmpty)
    }

    /// A gap in the middle is filled without re-scoring its neighbours — a day the strap missed and
    /// that later gained data must not require redoing the history around it.
    func testAGapIsFilledWithoutRescoringItsNeighbours() {
        let history = ["2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04", "2026-09-05"]
        let stored: Set<String> = ["2026-09-01", "2026-09-02", "2026-09-04"]
        // 09-05 is not scorable here — its concluding night would be on a 09-06 row that does not
        // exist yet — so the gap fill is 09-03 alone.
        XCTAssertEqual(DayQualityComputer.daysToScore(scoredDays: history, todayKey: "2026-09-06",
                                                      alreadyScored: stored),
                       ["2026-09-03"])
    }

    /// A CONFIG change is the one thing that justifies redoing history: the weighting moved, so
    /// every stored score is stale even though the days' inputs are not.
    func testAConfigChangeRescoresEverything() {
        let history = (1...10).map { String(format: "2026-09-%02d", $0) }
        let picked = DayQualityComputer.daysToScore(scoredDays: history, todayKey: "2026-09-11",
                                                    alreadyScored: Set(history), rescoreAll: true)
        XCTAssertEqual(picked.count, 9,
                       "moving a knob re-scores every day whose concluding night is in (09-10's is not)")
    }

    // MARK: - The day is graded against its OWN context

    /// A past day must not be graded against a readiness read that includes days after its
    /// CONCLUDING NIGHT — that would grade Monday using Wednesday's data, which the wearer could
    /// never have acted on.
    ///
    /// 260906: the boundary moved by exactly one day with the recovery half. Day D legitimately
    /// reads row D+1 (that row IS the night that closed day D), so the invariant is now "nothing
    /// after D+1 leaks in", not "nothing after D". Asserted by consequence: the same day scored
    /// against a history that stops at its concluding night, and against one that continues past it
    /// with wildly different rows, must produce the same input.
    func testAPastDayIsNotGradedUsingLaterDays() throws {
        // Ends at 08-31 — the row carrying the night that concluded 08-30, which the grade needs.
        let upToDay = history(["2026-08-28", "2026-08-29", "2026-08-30", "2026-08-31"])
        var withFuture = upToDay
        // Days after the concluding night, deliberately extreme.
        withFuture.append(metric(day: "2026-09-01", recovery: 5, strain: 99, hrv: 10, rhr: 90))
        withFuture.append(metric(day: "2026-09-02", recovery: 5, strain: 99, hrv: 10, rhr: 90))

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

    /// A night must not be its own baseline. If the graded night were included in its own HRV/RHR
    /// median, every day would sit at its own centre and the whole recovery half would go inert.
    ///
    /// 260906: the standout row is now the day AFTER the one being graded, because that is the row
    /// the recovery half reads.
    func testTheGradedDayIsExcludedFromItsOwnBaseline() throws {
        var rows = history(["2026-08-25", "2026-08-26", "2026-08-27"])   // hrv 58 throughout
        rows.append(metric(day: "2026-08-28", hrv: 58, rhr: 52))         // the day being graded
        rows.append(metric(day: "2026-08-29", hrv: 100, rhr: 40))        // its concluding night
        let targets = DayQualityComputer.targetsByDay(
            history: rows, profile: profile,
            onlyDays: DayQualityComputer.targetDaysNeeded(toScore: ["2026-08-28"], history: rows))
        let input = try XCTUnwrap(DayQualityComputer.input(for: "2026-08-28", history: rows,
                                                          profile: profile, targetsByDay: targets,
                                                          waterCups: nil, waterTargetCups: nil))
        XCTAssertEqual(input.hrv, 100, "the graded value is the concluding night's")
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

/// The scale-version migration (260908).
///
/// The signed −100…+100 rescale changes what a stored `day_quality` value MEANS for identical inputs,
/// so every day already in the series has to be re-derived. Rather than a bespoke migration, the scale
/// version rides in the config fingerprint and reuses the path a moved slider already takes — these
/// tests pin that it actually fires, because a silent failure here would leave two scales mixed under
/// one metric key and look like real data.
@MainActor
final class DayQualityScaleMigrationTests: XCTestCase {

    /// The version must be part of the fingerprint, or nothing re-scores.
    func testScaleVersionIsPartOfTheConfigFingerprint() {
        XCTAssertTrue(DayQualityPrefs.configFingerprint.contains(DayQualityPrefs.scaleVersion),
                      "the scale version must ride in the fingerprint, or a rescale silently leaves "
                      + "the old values in place under the same metric key")
    }

    /// A fingerprint recorded under the PREVIOUS scale must read as changed, which is what clears the
    /// incremental latch and re-derives history.
    func testAFingerprintFromTheOldScaleCountsAsChanged() {
        let old = "60/50/125"                       // the v1 form: no scale version at all
        XCTAssertNotEqual(old, DayQualityPrefs.configFingerprint,
                          "a pre-rescale fingerprint cannot equal the current one")
    }

    /// `rescoreAll` must actually widen the day set to the whole history rather than the missing tail.
    func testRescoreAllRedoesEveryFinishedDayNotJustTheMissingOnes() {
        let days = (1...10).map { String(format: "2026-09-%02d", $0) }
        let allButLast = Set(days.dropLast(2))      // pretend the series already holds these

        let incremental = DayQualityComputer.daysToScore(
            scoredDays: days, todayKey: "2026-09-10", alreadyScored: allButLast, rescoreAll: false)
        let full = DayQualityComputer.daysToScore(
            scoredDays: days, todayKey: "2026-09-10", alreadyScored: allButLast, rescoreAll: true)

        XCTAssertLessThan(incremental.count, full.count,
                          "the incremental pass must score fewer days than the full re-derivation")
        XCTAssertEqual(full.count, 9,
                       "every finished day with a following night re-scores: 09-01…09-09")
        XCTAssertTrue(full.allSatisfy { $0 < "2026-09-10" },
                      "today is never scored — the score is a closed book")
    }
}

/// Two defects the field cards exposed on 260908, both of which passed every test that existed.
@MainActor
final class DayQualityFieldDefectTests: XCTestCase {

    /// Day-quality scoring must NOT be gated behind a full pass.
    ///
    /// It was, and the stated reason ("a 2-day window cannot compute the scored-night fields") was
    /// false — the function takes no rows from the calling pass, reading the full history itself. The
    /// consequence was real: full passes are the ones deferred and abandoned under the battery policy
    /// (`forced 15/49` with repeated `gave up` in the 260908 log), so the score and any re-derivation
    /// of history after a formula change never ran. Cards showed values from an older formula beside a
    /// live breakdown that disagreed with them.
    ///
    /// A source assertion, since the call site is inside a long async function with no seam to inject:
    /// the call must sit at the method's own indentation, not nested inside the `if !lightPass` block.
    func testDayQualityScoringIsNotGatedBehindAFullPass() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // StrandTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("Strand/Data/IntelligenceEngine.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let callLines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("await scoreDayQuality(") }
        XCTAssertFalse(callLines.isEmpty, "the scoring pass must be called from somewhere")
        // EVERY call site must sit at the method's own indentation (8 spaces). At 12 it is nested
        // inside `if !lightPass`, which is the bug: the score stops being written whenever full
        // passes are being deferred — and the 260908 log contains no `day-quality:` line at all.
        //
        // Asserts a property of all sites rather than a COUNT: counting broke the moment the
        // on-demand re-score added a legitimate second caller, which is the same "counting was the
        // wrong property" mistake the CBCentralManager test made.
        for line in callLines {
            let indent = String(line).prefix { $0 == " " }.count
            XCTAssertEqual(indent, 8,
                           "call site must not be nested inside a conditional: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    /// The Day tab must be able to trigger a re-score itself.
    ///
    /// The scoring pass is the only writer of `day_quality`, and it runs on the engine's schedule.
    /// Everything below the score card reads the stored series while the card re-scores live, so
    /// after a formula change the tab showed two formulas at once — reported as "the changes haven't
    /// propagated below to the trends sections" — with no action available that would reconcile them.
    func testTheEngineExposesAnOnDemandRescore() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Strand/Data/IntelligenceEngine.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("func rescoreDayQualityNow()"),
                      "the Day tab needs a way to reconcile a stale stored series")
    }

    /// The scale version must have moved past `v2`, or the stored 0–100/first-signed values are never
    /// re-derived and the series mixes formulas under one metric key.
    func testTheScaleVersionMovedPastTheRetiredScales() {
        XCTAssertNotEqual(DayQualityPrefs.scaleVersion, "v1")
        XCTAssertNotEqual(DayQualityPrefs.scaleVersion, "v2",
                          "the absolute-anchor scale needs its own version, or history keeps values "
                          + "computed by the formula it replaced")
        XCTAssertTrue(DayQualityPrefs.configFingerprint.contains(DayQualityPrefs.scaleVersion))
    }
}
