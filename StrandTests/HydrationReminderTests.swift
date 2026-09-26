import XCTest
@testable import Strand
import StrandAnalytics
import WhoopStore

/// Pins the water reminder (260902) — the scheduling grid, the rounded-cup arithmetic and the copy.
/// The reminder is a layer over the EXISTING hydration tracker, so these also guard the one thing
/// that would make the two surfaces disagree: cups derived from anything other than `HydrationGoal`.
final class HydrationReminderTests: XCTestCase {

    /// 260903: the reminder rides the strap sync instead of calendar triggers, so the app is awake
    /// when it posts (it can buzz, and it reads the live cup count). These pin the firing rule.
    func testFiresOncePerSlotAndOnlyForTheLatestOnePassed() {
        let start = 8 * 60, every = 90   // 08:00, 09:30, 11:00, …

        // Before the first slot: nothing is owed.
        XCTAssertFalse(HydrationReminder.reminderWanted(
            enabled: true, minuteOfDay: 7 * 60 + 30, startMinute: start,
            intervalMinutes: every, lastFiredSlot: nil))

        // First slot passed, nothing fired yet → fire.
        XCTAssertTrue(HydrationReminder.reminderWanted(
            enabled: true, minuteOfDay: 8 * 60 + 5, startMinute: start,
            intervalMinutes: every, lastFiredSlot: nil))

        // Same slot, a later sync in the same ~10-minute window → already reminded, stay silent.
        XCTAssertFalse(HydrationReminder.reminderWanted(
            enabled: true, minuteOfDay: 8 * 60 + 40, startMinute: start,
            intervalMinutes: every, lastFiredSlot: 480))

        // Next slot passed → fire again.
        XCTAssertTrue(HydrationReminder.reminderWanted(
            enabled: true, minuteOfDay: 9 * 60 + 35, startMinute: start,
            intervalMinutes: every, lastFiredSlot: 480))

        // A phone away for hours owes ONE reminder, not one per missed slot.
        XCTAssertEqual(HydrationReminder.dueSlot(minuteOfDay: 15 * 60, startMinute: start,
                                                 intervalMinutes: every), 14 * 60,
                       "the latest slot at or before now is the one that fires")

        XCTAssertFalse(HydrationReminder.reminderWanted(
            enabled: false, minuteOfDay: 12 * 60, startMinute: start,
            intervalMinutes: every, lastFiredSlot: nil))
    }

    /// A new day re-arms even though the stored slot number would otherwise look "already fired".
    func testANewDayRearmsTheFirstSlot() {
        XCTAssertTrue(HydrationReminder.reminderWanted(
            enabled: true, minuteOfDay: 8 * 60 + 5, startMinute: 8 * 60,
            intervalMinutes: 90, lastFiredSlot: nil))
    }

    /// A new day still respects the start time.
    ///
    /// This property was previously UNTESTED — every case passed a time after the start minute — so
    /// it is worth pinning even though it always held. (It was briefly believed to be the cause of
    /// the reported duplicate reminders; it was not. A reproduction of the pre-change function
    /// returned false at 00:00, 02:10, 06:00 and 07:59. The real cause was stale repeating calendar
    /// requests — see `testTheLegacyRequestIdGridCovers…`.)
    func testANewDayDoesNotFireBeforeTheStartTime() {
        for minute in [0, 2 * 60 + 10, 6 * 60, 7 * 60 + 59] {
            XCTAssertFalse(HydrationReminder.reminderWanted(
                enabled: true, minuteOfDay: minute, startMinute: 8 * 60,
                intervalMinutes: 90, lastFiredSlot: nil),
                "a fresh day must not fire at minute \(minute), before the 08:00 window opens")
        }
        // And the moment the window does open, it fires.
        XCTAssertTrue(HydrationReminder.reminderWanted(
            enabled: true, minuteOfDay: 8 * 60, startMinute: 8 * 60,
            intervalMinutes: 90, lastFiredSlot: nil))
    }

    /// The pre-260903 repeating requests must be retired at launch, on BOTH platforms (260904).
    ///
    /// Reported from the device: the same "5 of 21 cups" arriving many days running, each followed
    /// ~30 seconds later by the correct live figure. Neither the mark-before-await race nor the
    /// day-boundary gate explained a REPEATING constant — a lost write varies, a frozen snapshot
    /// repeats.
    ///
    /// The old reminder scheduled `UNCalendarNotificationTrigger`s with `repeats: true`, ids
    /// "hydration-reminder-<minute>", each carrying a snapshot of the cup count at schedule time.
    /// The 260903 rewrite to sync-driven posting never removed them, and iOS keeps firing a
    /// repeating request with its original body indefinitely.
    func testTheLegacyRequestIdGridCoversEverySettingAPreviousBuildCouldHaveScheduled() {
        let ids = HydrationReminder.retiredCalendarRequestIds
        // The old grid was every 30 minutes from 00:00 through the last slot, deliberately wider
        // than any one interval setting, so a request from ANY previous configuration is covered.
        XCTAssertTrue(ids.contains("hydration-reminder-0"))
        XCTAssertTrue(ids.contains("hydration-reminder-480"), "08:00, the default start")
        XCTAssertTrue(ids.contains("hydration-reminder-\(HydrationReminder.lastSlotMinute)"))
        // A 30-minute grid over 0…lastSlot inclusive.
        XCTAssertEqual(ids.count, HydrationReminder.lastSlotMinute / 30 + 1)
        XCTAssertEqual(Set(ids).count, ids.count, "ids must be unique or removal is ambiguous")
    }

    /// Structural, like the notification-action wiring guard: the retirement must be reachable from
    /// BOTH `@main` files. `StrandApp.swift` is macOS-only and excluded from the iOS target, so a
    /// cleanup written in one place silently never runs on the other — the exact mistake that made
    /// the "Add a cup" button dead on iOS.
    func testBothPlatformsRetireTheLegacyRequestsAtLaunch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for (platform, path) in [("macOS", "Strand/App/StrandApp.swift"),
                                 ("iOS", "StrandiOS/App/StrandiOSApp.swift")] {
            let src = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(src.contains("HydrationReminder.retireLegacyCalendarRequests()"),
                          """
                          \(platform) launch (\(path)) never retires the legacy water reminders, \
                          so iOS keeps firing their frozen snapshot text on that platform.
                          """)
        }
    }

    func testSlotsRunFromTheStartTimeAtTheChosenIntervalAndStopAt10pm() {
        // 08:00 every 90 min → 08:00, 09:30, … and nothing past 22:00.
        let slots = HydrationReminder.slotMinutes(startMinute: 8 * 60, intervalMinutes: 90)
        XCTAssertEqual(slots.first, 480)
        XCTAssertEqual(slots.prefix(3), [480, 570, 660])
        XCTAssertLessThanOrEqual(slots.last ?? 0, HydrationReminder.lastSlotMinute)
        // A late start still yields a sane, bounded grid rather than an empty or runaway one.
        let late = HydrationReminder.slotMinutes(startMinute: 13 * 60, intervalMinutes: 180)
        XCTAssertEqual(late, [780, 960, 1_140, 1_320])
    }

    func testCupsRoundToWholeCupsAgainstTheTrackersOwnCupSize() {
        // The +Cup button logs `HydrationGoal.cupML`; the reminder must count in exactly that unit.
        XCTAssertEqual(HydrationReminder.cups(fromML: Double(HydrationGoal.cupML)), 1)
        XCTAssertEqual(HydrationReminder.cups(fromML: Double(HydrationGoal.cupML) * 3), 3)
        XCTAssertEqual(HydrationReminder.cups(fromML: 0), 0)
        // Rounded, not truncated: two-and-a-half cups reads as 3, not 2.
        XCTAssertEqual(HydrationReminder.cups(fromML: Double(HydrationGoal.cupML) * 2.5), 3)
    }

    func testCopyStatesGoalDrunkAndRemaining() {
        let text = HydrationReminder.reminderText(totalML: Double(HydrationGoal.cupML) * 4,
                                                  goalCups: 16)
        XCTAssertEqual(text.title, "Water break")
        XCTAssertEqual(text.body, "4 of 16 cups — 12 to go")
    }

    /// 260903: the notification read "2/16" while the Today row read "3/19" — the reminder was
    /// deriving its goal from the retired millilitre formula AND re-rounding the drunk figure to
    /// whole cups. The goal is now passed in from the row's own LiveTargets, and drunk is rendered
    /// at the row's half-cup granularity, so the two surfaces cannot disagree.
    func testCopyMatchesTheTodayRowForTheReportedCase() {
        // 2.5 cups drunk (the row shows "2.5"), goal 19 from the cups rule.
        let total = Double(HydrationGoal.halfCupML) * 5
        let text = HydrationReminder.reminderText(totalML: total, goalCups: 19)
        XCTAssertEqual(text.body, "2.5 of 19 cups — 17 to go",
                       "the goal is the row's, and drunk keeps the row's half-cup precision")
        // The row's own rendering of the same millilitres, for the same-to-the-drop guarantee.
        XCTAssertEqual(HydrationGoal.cupsDisplay(halfCups: HydrationGoal.halfCups(fromML: total)),
                       "2.5")
    }

    /// Past the goal the reminder must not nag with a negative remainder — it keeps firing until
    /// the day's last slot, so the over-goal case is a real, recurring state.
    func testPastTheGoalItCongratulatesInsteadOfShowingNegativeCups() {
        let text = HydrationReminder.reminderText(totalML: Double(HydrationGoal.cupML) * 20,
                                                  goalCups: 16)
        XCTAssertEqual(text.body, "20 of 16 cups — you're there, keep sipping")
    }

    func testBothLogActionsAreOfferedOnTheCategoryTheRemindersUse() {
        let category = HydrationReminder.category
        XCTAssertEqual(category.identifier, HydrationReminder.categoryId)
        // Full cup FIRST (the common case sits closest to the thumb), then the half.
        XCTAssertEqual(category.actions.map(\.identifier),
                       [HydrationReminder.logCupActionId, HydrationReminder.logHalfCupActionId])
        // No authentication requirement: logging a cup must stay a one-gesture action.
        for action in category.actions {
            XCTAssertFalse(action.options.contains(.authenticationRequired))
        }
    }

    /// Half-cup arithmetic must stay exact against the tracker's own cup, or a day logged in
    /// halves would drift from one logged in cups.
    func testHalfCupsComposeExactlyIntoCups() {
        XCTAssertEqual(HydrationGoal.halfCupML * 2, HydrationGoal.cupML - (HydrationGoal.cupML % 2))
        XCTAssertEqual(HydrationGoal.halfCups(fromML: Double(HydrationGoal.cupML)), 2)
        XCTAssertEqual(HydrationGoal.cupsDisplay(halfCups: 5), "2.5")
        XCTAssertEqual(HydrationGoal.cupsDisplay(halfCups: 6), "3")
        XCTAssertEqual(HydrationGoal.cupsDisplay(halfCups: 0), "0")
    }

    /// The status line the coach titles from must state the shortfall — or that the goal is met,
    /// which is what makes an over-goal reminder encouraging rather than nagging.
    func testCoachStatusStatesTheShortfallOrThatTheGoalIsMet() {
        let behind = HydrationReminder.coachStatus(totalML: Double(HydrationGoal.cupML) * 4,
                                                   goalCups: 16)
        XCTAssertTrue(behind.contains("4 of 16 cups"), behind)
        XCTAssertTrue(behind.contains("12 cups still to drink"), behind)
        let met = HydrationReminder.coachStatus(totalML: Double(HydrationGoal.cupML) * 18,
                                                goalCups: 16)
        XCTAssertTrue(met.contains("already hit my target"), met)
    }
}

/// 260903: the water target is FROZEN like the other four — priced off the ANCHOR's effort (the
/// last scored day), never today's accumulating strain, so the denominator cannot move during the
/// day. This is the same call the maintainer made for the effort target ("freeze it", 260831).
/// 260903: the water target in CUPS — `baseline cups + effort/10`, where effort is
/// max(today's TARGET, today's ACCRUED). Pinned end-to-end through `Repository.liveTargets`, in
/// both directions, because three bases shipped in one day and each was wrong in its own way:
/// accrued alone moved the ask DOWN as rows were rescored, yesterday's scored strain was still
/// being rewritten hours into today ("yesterday's effort of 8" when yesterday finished at 7), and
/// the target alone under-asked on a day that genuinely went harder than prescribed.
@MainActor
final class FrozenWaterTargetTests: XCTestCase {

    /// The maintainer's rule: "a target strain today of 50 leads to 16 + 50/10 = 21 cups".
    func testGoalIsBaselineCupsPlusOneCupPerTenEffort() {
        XCTAssertEqual(HydrationGoal.cups(fromML: Double(HydrationGoal.baselineMaleML)), 16,
                       "16 cups is the male baseline the rule is anchored on")
        XCTAssertEqual(HydrationGoal.dailyGoalCups(sex: "male", effortTarget: 50), 21)
        XCTAssertEqual(HydrationGoal.dailyGoalCups(sex: "male", effortTarget: 0), 16)
        XCTAssertEqual(HydrationGoal.dailyGoalCups(sex: "male", effortTarget: 100), 26)
        XCTAssertEqual(HydrationGoal.dailyGoalCups(sex: "male", effortTarget: nil), 16,
                       "a rest day prices the body baseline alone")
        XCTAssertGreaterThanOrEqual(HydrationGoal.dailyGoalCups(sex: "", effortTarget: -50), 1)
    }

    func testBelowThePlanTheAskIsThePlans() {
        let morning = targets(accrued: 3)
        XCTAssertEqual(morning.waterTargetCups,
                       HydrationGoal.dailyGoalCups(sex: maleProfile.sex,
                                                   effortTarget: morning.effortTarget.map(Double.init)))
        // Strain climbs but stays under the plan → unchanged.
        let planned = Double(morning.effortTarget ?? 0)
        XCTAssertEqual(targets(accrued: planned - 5).waterTargetCups, morning.waterTargetCups)
    }

    /// Past the plan the ask follows the real work — sweat loss is same-day, which is the whole
    /// reason the basis is a max rather than the frozen target.
    func testExceedingThePlanRaisesTheAsk() {
        let morning = targets(accrued: 3)
        let planned = Double(morning.effortTarget ?? 0)
        let evening = targets(accrued: planned + 30)
        XCTAssertEqual(evening.waterTargetCups,
                       HydrationGoal.dailyGoalCups(sex: maleProfile.sex, effortTarget: planned + 30))
        XCTAssertGreaterThan(evening.waterTargetCups ?? 0, morning.waterTargetCups ?? 0)
    }

    /// The guarantee the max buys: within a day the ask can never fall below what the plan already
    /// asked, even when a rescore rewrites accrued strain downward.
    func testTheAskNeverFallsBelowThePlan() {
        let planFloor = HydrationGoal.dailyGoalCups(
            sex: maleProfile.sex,
            effortTarget: targets(accrued: 0).effortTarget.map(Double.init))
        for accrued in [3.0, 60.0, 50.0, 20.0] {
            XCTAssertGreaterThanOrEqual(targets(accrued: accrued).waterTargetCups ?? 0, planFloor,
                                        "accrued \(accrued) must not walk the ask back")
        }
    }

    func testNoWaterTargetWhenTrackingIsOff() {
        let days = [metric(day: "2026-09-15", strain: 10)]
        let t = Repository.liveTargets(days: days, charge: 80, restScore: 81,
                                       profile: maleProfile, todayKey: "2026-09-15",
                                       waterTodayML: nil, waterEnabled: false)
        XCTAssertNil(t.waterTargetCups)
    }

    // MARK: fixtures

    private func targets(accrued: Double) -> LiveTargets {
        var days = (1...14).map { metric(day: String(format: "2026-09-%02d", $0), strain: 10) }
        days.append(metric(day: "2026-09-15", strain: accrued))
        return Repository.liveTargets(days: days, charge: 80, restScore: 81,
                                      profile: maleProfile, todayKey: "2026-09-15",
                                      waterTodayML: 0, waterEnabled: true)
    }

    private var maleProfile: UserProfile {
        UserProfile(weightKg: 70, heightCm: 175, age: 34, sex: "male", stepTicksPerStep: 0)
    }

    private func metric(day: String, strain: Double) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 480, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: 60, avgHrv: 40, recovery: 80,
                    strain: strain, exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil,
                    respRateBpm: nil, steps: 5000, activeKcalEst: 1200, spo2Red: nil,
                    spo2Ir: nil, avgSdnn: nil, skinTempC: nil)
    }
}

/// 260903: the Today water count must survive a cold start. The drinks always persisted (they
/// live in UserDefaults); the in-memory cache the row reads did not — it was refreshed only by the
/// three mutation sites, so a relaunch read 0 until the user happened to log another drink. The
/// cache is now self-seeding, so it cannot be read before it has been derived for the day.
@MainActor
final class HydrationCacheSeedingTests: XCTestCase {

    private let day = Repository.localDayKey(Date())

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: HydrationStore.entriesKey(forDay: day))
        super.tearDown()
    }

    func testAFreshRepositoryReadsTheDaysStoredDrinks() {
        // Two cups already logged, exactly as a previous app session left them.
        writeEntries([HydrationGoal.cupML, HydrationGoal.cupML])

        // A brand-new Repository — the cold-start case. No mutation, no explicit refresh.
        let repo = Repository(deviceId: "test-hydration-seeding")
        XCTAssertEqual(repo.hydrationTodayCachedML, Double(HydrationGoal.cupML * 2),
                       "a relaunch must show the drinks already logged, not zero")
    }

    func testAnOptimisticBumpAddsToTheStoredTotalNotToZero() {
        writeEntries([HydrationGoal.cupML, HydrationGoal.cupML])
        let repo = Repository(deviceId: "test-hydration-seeding")
        // The Today row's + control on a freshly launched app.
        repo.bumpHydrationOptimistically(deltaML: HydrationGoal.halfCupML)
        XCTAssertEqual(repo.hydrationTodayCachedML,
                       Double(HydrationGoal.cupML * 2 + HydrationGoal.halfCupML),
                       "the bump must land on the real total, not on a zeroed cache")
    }

    private func writeEntries(_ amounts: [Int]) {
        let entries = amounts.map {
            HydrationEntry(id: UUID(), amountMl: $0, loggedAt: Date())
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(entries),
                                  forKey: HydrationStore.entriesKey(forDay: day))
    }
}

/// Pins the shared notification-title enforcement (260903). The prompt asks the model for ≤32
/// characters with examples; only this code can guarantee it, because a clipped Lock-Screen title
/// is a worse outcome than a plain one.
final class NotificationTitleCleaningTests: XCTestCase {

    func testAShortCleanLinePassesThrough() {
        XCTAssertEqual(AICoachEngine.cleanNotificationTitle("Two thousand steps to go"),
                       "Two thousand steps to go")
    }

    /// A model that echoes one of the prompt's shape examples has said nothing about the day, so
    /// the line is rejected and the caller's plain title is used — the 260903 report, where every
    /// nudge arrived titled "Big push left, block an hour" (an example, verbatim).
    func testAParrotedPromptExampleIsRejected() {
        for example in AICoachEngine.notificationTitleExamples {
            XCTAssertNil(AICoachEngine.cleanNotificationTitle(example), example)
        }
        // Case and trailing punctuation must not smuggle one through.
        XCTAssertNil(AICoachEngine.cleanNotificationTitle("Quick lap around the block?"))
        XCTAssertNil(AICoachEngine.cleanNotificationTitle("NAILED IT, KEEP IT ROLLING"))
    }

    func testForbiddenShapesAreStripped() {
        XCTAssertEqual(AICoachEngine.cleanNotificationTitle("  \"Time to earn that couch.\"  "),
                       "Time to earn that couch")
        // A model that ignores "no line breaks" usually offers its best line first.
        XCTAssertEqual(AICoachEngine.cleanNotificationTitle("Keep it rolling\nOr maybe: go walk"),
                       "Keep it rolling")
    }

    func testAnOverLongLineIsTrimmedAtAWordBoundaryNotMidWord() {
        let long = "You are quite a long way behind pace today, friend"
        let cleaned = AICoachEngine.cleanNotificationTitle(long)
        XCTAssertNotNil(cleaned)
        XCTAssertLessThanOrEqual(cleaned!.count, AICoachEngine.notificationTitleMaxChars)
        // Whole words only — the trim must land on a word from the original.
        XCTAssertTrue(long.hasPrefix(cleaned!), cleaned!)
        XCTAssertFalse(cleaned!.hasSuffix(" "), cleaned!)
    }

    func testAnUnusableReplyFallsBackToTheCallersTitle() {
        XCTAssertNil(AICoachEngine.cleanNotificationTitle("   "))
        XCTAssertNil(AICoachEngine.cleanNotificationTitle(""))
        // A single word longer than the bound cannot be trimmed into a title.
        XCTAssertNil(AICoachEngine.cleanNotificationTitle(String(repeating: "a", count: 40)))
    }

    func testTheBoundMatchesWhatALockScreenTitleCanShow() {
        XCTAssertEqual(AICoachEngine.notificationTitleMaxChars, 32)
    }
    // MARK: - The configurable stop time (260904)
    //
    // Maintainer request: start AND stop time controls for the water reminder, with the stop
    // following the sleep-window start already configured in Settings rather than a second number.

    /// The grid ends at the stop, not at the old fixed 22:00.
    func testTheStopTimeBoundsTheGrid() {
        let slots = HydrationReminder.slotMinutes(startMinute: 7 * 60 + 30, intervalMinutes: 60,
                                                  stopMinute: 21 * 60)
        XCTAssertEqual(slots.first, 7 * 60 + 30)
        XCTAssertEqual(slots.last, 20 * 60 + 30,
                       "the last slot is the final whole interval AT OR BEFORE the stop")
        XCTAssertFalse(slots.contains(21 * 60 + 30), "nothing past the stop")
        XCTAssertEqual(slots.count, 14)
    }

    /// An earlier stop genuinely silences the evening, and a later one is not allowed past the
    /// 22:00 ceiling the feature has always enforced.
    func testTheStopTimeSilencesTheEveningAndIsCeilinged() {
        // 18:00 stop: a 19:30 sync has nothing newer than the 18:00 slot.
        XCTAssertEqual(HydrationReminder.dueSlot(minuteOfDay: 19 * 60 + 30, startMinute: 8 * 60,
                                                 intervalMinutes: 120, stopMinute: 18 * 60),
                       18 * 60)
        XCTAssertFalse(HydrationReminder.reminderWanted(
            enabled: true, minuteOfDay: 19 * 60 + 30, startMinute: 8 * 60,
            intervalMinutes: 120, lastFiredSlot: 18 * 60, stopMinute: 18 * 60),
            "past the stop, the last in-window slot is already spent — stay silent")

        // A stop beyond the ceiling is clamped rather than honoured.
        XCTAssertEqual(HydrationReminder.clampStop(23 * 60 + 45, startMinute: 8 * 60),
                       HydrationReminder.lastSlotMinute)
    }

    /// An inverted pair must never yield an empty grid — that would silently disable the feature.
    func testAStopBeforeTheStartCannotDisableTheFeature() {
        let start = 13 * 60
        XCTAssertEqual(HydrationReminder.clampStop(6 * 60, startMinute: start), start,
                       "a stop before the start is floored at the start")
        let slots = HydrationReminder.slotMinutes(startMinute: start, intervalMinutes: 60,
                                                  stopMinute: 6 * 60)
        XCTAssertEqual(slots, [start], "the first reminder survives an inverted pair")
    }

    /// The DEFAULT stop is the sleep-window start, and the shipped default of that window (22:00)
    /// reproduces the old hardcoded last slot exactly — so an existing install sees no shift.
    func testTheDefaultStopFollowsTheSleepWindowAndPreservesOldBehaviour() {
        let d = UserDefaults.standard
        let savedStop = d.object(forKey: HydrationReminder.K.stopMin)
        let savedSleep = d.object(forKey: ContinuousHrvSchedule.quietStartKey)
        let savedStart = d.object(forKey: HydrationReminder.K.startMin)
        defer {
            savedStop == nil ? d.removeObject(forKey: HydrationReminder.K.stopMin)
                             : d.set(savedStop, forKey: HydrationReminder.K.stopMin)
            savedSleep == nil ? d.removeObject(forKey: ContinuousHrvSchedule.quietStartKey)
                              : d.set(savedSleep, forKey: ContinuousHrvSchedule.quietStartKey)
            savedStart == nil ? d.removeObject(forKey: HydrationReminder.K.startMin)
                              : d.set(savedStart, forKey: HydrationReminder.K.startMin)
        }

        d.removeObject(forKey: HydrationReminder.K.stopMin)
        d.removeObject(forKey: ContinuousHrvSchedule.quietStartKey)
        d.set(8 * 60, forKey: HydrationReminder.K.startMin)
        XCTAssertEqual(HydrationReminder.stopMinute, ContinuousHrvSchedule.defaultStartMinutes)
        XCTAssertEqual(HydrationReminder.stopMinute, HydrationReminder.lastSlotMinute,
                       "the shipped default must equal the old fixed last slot")

        // Move the sleep window earlier: the last reminder follows it, with no second control.
        d.set(21 * 60, forKey: ContinuousHrvSchedule.quietStartKey)
        XCTAssertEqual(HydrationReminder.stopMinute, 21 * 60)

        // An explicit stop overrides the window.
        HydrationReminder.setStopMinute(19 * 60)
        XCTAssertEqual(HydrationReminder.stopMinute, 19 * 60)
        d.set(20 * 60, forKey: ContinuousHrvSchedule.quietStartKey)
        XCTAssertEqual(HydrationReminder.stopMinute, 19 * 60,
                       "an explicit choice is not overwritten by a sleep-window edit")
    }

    /// Raising the start past a stored stop re-normalises the STORED stop, so the picker never
    /// displays a stop the schedule is ignoring.
    func testRaisingTheStartRepairsAnExplicitStop() {
        let d = UserDefaults.standard
        let savedStop = d.object(forKey: HydrationReminder.K.stopMin)
        let savedStart = d.object(forKey: HydrationReminder.K.startMin)
        defer {
            savedStop == nil ? d.removeObject(forKey: HydrationReminder.K.stopMin)
                             : d.set(savedStop, forKey: HydrationReminder.K.stopMin)
            savedStart == nil ? d.removeObject(forKey: HydrationReminder.K.startMin)
                              : d.set(savedStart, forKey: HydrationReminder.K.startMin)
        }

        HydrationReminder.setStartMinute(7 * 60)
        HydrationReminder.setStopMinute(9 * 60)
        HydrationReminder.setStartMinute(13 * 60)
        XCTAssertEqual(d.object(forKey: HydrationReminder.K.stopMin) as? Int, 13 * 60,
                       "the stored stop is repaired, not just clamped on read")
    }

    /// The retirement id grid must keep spanning the ORIGINAL 22:00 range even though the schedule
    /// no longer ends there — those legacy ids were minted against it.
    func testTheRetirementGridStillCoversTheLegacyRange() {
        let ids = HydrationReminder.retiredCalendarRequestIds
        XCTAssertTrue(ids.contains("hydration-reminder-\(22 * 60)"))
        XCTAssertEqual(HydrationReminder.lastSlotMinute, 22 * 60,
                       "changing this orphans the pre-260903 repeating requests")
    }

    // MARK: - Notification titles (260904, from the 1119 log)

    /// The prompt must not QUOTE any line the validator rejects.
    ///
    /// The 1119 log caught the trap: the prompt offered "Time to block out an hour" as an example,
    /// the model returned exactly that against a genuinely large gap, and the parrot check threw it
    /// away — so the nudge arrived titled "Behind pace". The two mechanisms were pulling in
    /// opposite directions. Fixed by DESCRIBING the shape rather than supplying quotable text, and
    /// this is the guard that stops an example being reintroduced into the prompt later.
    func testThePromptDoesNotQuoteAnyRejectedTitle() {
        let prompt = AICoachEngine.defaultNotificationTitlePrompt.lowercased()
        for canned in AICoachEngine.notificationTitleExamples {
            XCTAssertFalse(prompt.contains(canned),
                           "the prompt quotes \"\(canned)\", which cleanNotificationTitle rejects — "
                           + "a model that follows the example is guaranteed the static fallback")
        }
    }

    /// The prompt must still steer length and specificity, which is what actually produces short,
    /// day-specific lines — removing the examples must not have removed the constraints with them.
    func testThePromptStillConstrainsLengthAndDemandsMyNumbers() {
        let prompt = AICoachEngine.defaultNotificationTitlePrompt
        XCTAssertTrue(prompt.contains("\(AICoachEngine.notificationTitleMaxChars) characters"),
                      "the character limit must be stated in the prompt, not only enforced after")
        XCTAssertTrue(prompt.lowercased().contains("my numbers"),
                      "the prompt must still demand a day-specific line")
    }

    /// A title generated for a notification gets a MUCH tighter stall budget than the coach.
    ///
    /// From the 1119 log: both title failures were "took too long", and the lines before them show
    /// a 25-second re-score and a just-finished backfill — titles are requested from the
    /// post-offload path, competing with work the coach screen never competes with. The nudge
    /// already carries a correct static title, so a long wait can win nothing.
    func testTheNotificationTitleBudgetIsFarTighterThanTheCoachs() {
        XCTAssertLessThan(AICoachEngine.notificationTitleTimeoutSeconds,
                          AICoachEngine.requestTimeoutSeconds,
                          "a background decoration must not wait as long as a user-initiated answer")
        XCTAssertLessThanOrEqual(AICoachEngine.notificationTitleTimeoutSeconds, 30)
    }

}
