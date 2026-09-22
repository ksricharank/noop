import XCTest
@testable import StrandAnalytics

/// Pins the 1h / 3h / 6h horizon planner that sits under the synthesis card.
///
/// The planner is rule-based and pure, so everything here runs with no app, no strap and no database.
/// What is worth pinning is not the exact prose — that will be reworded — but the DECISIONS: which
/// constraints override which, when a horizon stays silent, and that the copy never contradicts the
/// synthesis verdict sitting directly above it.
final class HorizonPlannerTests: XCTestCase {

    /// A mid-morning, well-rested, nothing-flagging baseline. Individual tests vary one field so the
    /// thing under test is the only difference.
    private func input(level: ReadinessEngine.Level = .balanced,
                       strain: Double? = 0,
                       sleep: Int? = 8 * 60,
                       hour: Int = 9,
                       bedtime: Int = 22) -> HorizonPlanner.Input {
        HorizonPlanner.Input(level: level, strainSoFar: strain, sleepMinutes: sleep,
                             hour: hour, bedtimeHour: bedtime)
    }

    private func text(_ horizon: HorizonPlanner.Horizon, _ input: HorizonPlanner.Input) -> String? {
        HorizonPlanner.plan(input).first { $0.horizon == horizon }?.text
    }

    // MARK: Shape

    /// A normal mid-morning read fills all three horizons, in order, with no duplicates. The ordering
    /// matters because the card renders them top-to-bottom as a timeline.
    func testFullDayReturnsThreeHorizonsInOrder() {
        let plans = HorizonPlanner.plan(input())
        XCTAssertEqual(plans.map(\.horizon), [.hour, .threeHours, .sixHours])
        XCTAssertEqual(Set(plans.map(\.text)).count, 3, "the three horizons must not repeat one line")
        XCTAssertFalse(plans.contains { $0.text.isEmpty })
    }

    /// Mid-calibration the planner says so ONCE and stops. Three confident instructions off a baseline
    /// the app does not have yet would be exactly the kind of invented certainty the synthesis avoids.
    func testInsufficientHistorySaysSoOnceAndStops() {
        let plans = HorizonPlanner.plan(input(level: .insufficient))
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.horizon, .hour)
        XCTAssertTrue(plans[0].text.contains("baseline"))
    }

    /// `Plan.id` is the stable horizon key, not the prose — SwiftUI list identity must not churn when
    /// the copy changes between refreshes.
    func testPlanIdentityIsTheHorizonNotTheText() {
        XCTAssertEqual(HorizonPlanner.Plan(horizon: .threeHours, text: "anything").id, "3h")
        XCTAssertEqual(HorizonPlanner.Horizon.allCases.map(\.rawValue), ["1h", "3h", "6h"])
    }

    // MARK: Readiness drives the advice

    /// Run down: no horizon may suggest training. This is the single most important property here — the
    /// card would actively harm someone if it told them to push on a rundown day.
    func testRunDownNeverSuggestsTraining() {
        for hour in [6, 9, 12, 15, 18] {
            let plans = HorizonPlanner.plan(input(level: .rundown, hour: hour))
            for plan in plans {
                XCTAssertFalse(plan.text.lowercased().contains("hard session"),
                               "rundown at \(hour):00 suggested a hard session: \(plan.text)")
            }
        }
    }

    /// Primed, rested, nothing logged yet, mid-morning: the 3h window is the day's training window.
    func testPrimedAndUntrainedGetsTheTrainingWindow() {
        let line = text(.threeHours, input(level: .primed, strain: 0, hour: 9))
        XCTAssertEqual(line, "Your best window today for a hard session.")
    }

    /// Strained sits between the two: movement is fine, intensity is not.
    func testStrainedAllowsMovementButNotIntensity() {
        XCTAssertEqual(text(.hour, input(level: .strained)), "Keep it gentle — a walk is plenty for now.")
        XCTAssertEqual(text(.threeHours, input(level: .strained)),
                       "Low-intensity only if you do move — save the intensity for tomorrow.")
    }

    // MARK: Load already banked

    /// Having already trained outranks a good readiness score: a primed athlete who has logged real work
    /// should be told to stop, not to go again.
    func testAlreadyTrainedOutranksPrimed() {
        let trained = input(level: .primed, strain: HorizonPlanner.trainedTodayEffort, hour: 9)
        XCTAssertEqual(text(.hour, trained), "You've done the work today. Refuel and let it settle.")
        XCTAssertEqual(text(.threeHours, trained),
                       "Good work already logged — a second hard effort would cost you.")
    }

    /// The threshold is inclusive at the boundary and genuinely switches behaviour either side of it.
    func testTrainedThresholdBoundary() {
        let below = input(level: .primed, strain: HorizonPlanner.trainedTodayEffort - 0.1, hour: 9)
        let atMark = input(level: .primed, strain: HorizonPlanner.trainedTodayEffort, hour: 9)
        XCTAssertEqual(text(.threeHours, below), "Your best window today for a hard session.")
        XCTAssertNotEqual(text(.threeHours, atMark), text(.threeHours, below))
    }

    /// Unknown strain must not be read as "trained already" — a day with no scored strain is treated as
    /// nothing logged, which is what an unscored morning actually means.
    func testUnknownStrainReadsAsNothingLogged() {
        XCTAssertEqual(text(.threeHours, input(level: .primed, strain: nil, hour: 9)),
                       "Your best window today for a hard session.")
    }

    // MARK: Sleep

    /// A short night tempers the near-term advice even when the score looks fine — one good-HRV night on
    /// five hours does not justify stacking hard work on top of it.
    func testShortNightTempersAGoodScore() {
        let short = input(level: .primed, sleep: HorizonPlanner.shortSleepMinutes - 1, hour: 9)
        XCTAssertEqual(text(.hour, short), "Short night behind you — ease into the day before anything hard.")
    }

    /// …and it changes what the evening line asks for.
    func testShortNightAsksForAnEarlierNight() {
        let short = input(level: .balanced, sleep: 5 * 60, hour: 16)
        XCTAssertEqual(text(.sixHours, short),
                       "Bank an earlier night than last night — that's the biggest lever you have.")
    }

    /// Unknown sleep is not a short night. Missing data must not manufacture a warning.
    func testUnknownSleepIsNotTreatedAsShort() {
        XCTAssertEqual(text(.hour, input(level: .primed, sleep: nil, hour: 9)),
                       "Clear to move. Warm up properly if you're training soon.")
    }

    // MARK: Time of day overrides everything

    /// Late evening never proposes a hard session, however primed and however untrained the day was.
    /// A late session eats the night the whole app exists to protect.
    func testLateEveningNeverProposesHardWork() {
        let late = input(level: .primed, strain: 0, hour: HorizonPlanner.lateTrainingCutoffHour)
        for plan in HorizonPlanner.plan(late) {
            XCTAssertFalse(plan.text.lowercased().contains("hard session"),
                           "20:00 proposed a hard session: \(plan.text)")
        }
    }

    /// Approaching bedtime, the nearest horizon becomes the wind-down instruction — it outranks the
    /// readiness advice that would otherwise fill that slot.
    func testBedtimeOutranksReadinessOnTheNearHorizon() {
        // Bedtime 22:00 with a 2 h lead ⇒ wind-down starts 20:00, which is inside 21:00's next hour.
        XCTAssertEqual(text(.hour, input(level: .primed, hour: 21, bedtime: 22)),
                       "Wind down now — screens off and lights out soon.")
    }

    /// Morning is well clear of the wind-down window, so the near horizon is normal advice.
    func testMorningIsNotAWindDownWindow() {
        XCTAssertEqual(text(.hour, input(level: .balanced, hour: 8, bedtime: 22)),
                       "Clear to move. Warm up properly if you're training soon.")
    }

    // MARK: Bedtime window arithmetic

    /// The window-end scale is un-wrapped (hour + hoursAhead may exceed 23), so a past-midnight bedtime
    /// must shift forward a day rather than wrapping the window backwards. Without that, an 18:00 read
    /// of a 23:00 bedtime and of a 01:00 bedtime would be indistinguishable.
    func testPastMidnightBedtimeShiftsForwardNotBackward() {
        // 23:00 bedtime, 2 h lead ⇒ wind-down 21:00, inside 18:00 + 6 h = 24.
        XCTAssertTrue(HorizonPlanner.bedtimeFalls(within: 24, bedtimeHour: 23, leadHours: 2, fromHour: 18))
        // 01:00 bedtime ⇒ wind-down 23:00, also inside that window.
        XCTAssertTrue(HorizonPlanner.bedtimeFalls(within: 24, bedtimeHour: 1, leadHours: 2, fromHour: 18))
        // But at 18:00 neither is inside the NEXT HOUR.
        XCTAssertFalse(HorizonPlanner.bedtimeFalls(within: 19, bedtimeHour: 23, leadHours: 2, fromHour: 18))
        XCTAssertFalse(HorizonPlanner.bedtimeFalls(within: 19, bedtimeHour: 1, leadHours: 2, fromHour: 18))
    }

    /// A wind-down that crosses midnight backwards (bedtime 01:00, lead 2 h ⇒ 23:00) resolves to the
    /// same evening, not to 23:00 the previous day.
    func testWindDownLeadCrossingMidnightResolvesToTonight() {
        XCTAssertTrue(HorizonPlanner.bedtimeFalls(within: 23, bedtimeHour: 1, leadHours: 2, fromHour: 22))
    }

    /// A bedtime already passed today belongs to tomorrow — at 23:00 with a 22:00 bedtime the user is
    /// past it, and the next wind-down is a day away, not retroactively "now".
    func testBedtimeEarlierThanNowBelongsToTomorrow() {
        XCTAssertFalse(HorizonPlanner.bedtimeFalls(within: 24, bedtimeHour: 22, leadHours: 2, fromHour: 23))
    }

    // MARK: No contradiction with the synthesis above it

    /// #1405: the horizon copy must not reuse the ReadinessEngine's verdict words, or the two halves of
    /// one card read as though they are arguing. The verdict owns Push / Maintain / Rest as standalone
    /// labels; the horizons speak in imperatives about a window of time.
    func testHorizonCopyAvoidsTheVerdictVocabulary() {
        let verdictWords = ["push", "maintain"]
        for level in [ReadinessEngine.Level.primed, .balanced, .strained, .rundown] {
            for hour in [7, 12, 17, 21] {
                for plan in HorizonPlanner.plan(input(level: level, hour: hour)) {
                    let words = plan.text.lowercased()
                        .split(whereSeparator: { !$0.isLetter })
                        .map(String.init)
                    for verdict in verdictWords {
                        XCTAssertFalse(words.contains(verdict),
                                       "\(level)@\(hour):00 reused the verdict word '\(verdict)': \(plan.text)")
                    }
                }
            }
        }
    }

    /// Every reachable combination produces non-empty, sentence-shaped copy — no placeholder leaks and
    /// no horizon renders as a bare fragment.
    func testAllCombinationsProduceWellFormedCopy() {
        for level in [ReadinessEngine.Level.primed, .balanced, .strained, .rundown, .insufficient] {
            for hour in 0...23 {
                for strain in [nil, 0, 15] as [Double?] {
                    for sleep in [nil, 4 * 60, 8 * 60] as [Int?] {
                        let plans = HorizonPlanner.plan(
                            input(level: level, strain: strain, sleep: sleep, hour: hour))
                        for plan in plans {
                            XCTAssertFalse(plan.text.trimmingCharacters(in: .whitespaces).isEmpty)
                            XCTAssertTrue(plan.text.hasSuffix(".") || plan.text.hasSuffix("!"),
                                          "not a sentence: \(plan.text)")
                        }
                    }
                }
            }
        }
    }
}
