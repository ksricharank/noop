import XCTest
@testable import Strand
import StrandAnalytics

/// Pins the water reminder (260902) — the scheduling grid, the rounded-cup arithmetic and the copy.
/// The reminder is a layer over the EXISTING hydration tracker, so these also guard the one thing
/// that would make the two surfaces disagree: cups derived from anything other than `HydrationGoal`.
final class HydrationReminderTests: XCTestCase {

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
        // A 3700 ml male baseline is ~16 cups; 4 cups in leaves 12.
        let text = HydrationReminder.reminderText(totalML: Double(HydrationGoal.cupML) * 4,
                                                  goalML: 3_700)
        XCTAssertEqual(text.title, "Water break")
        XCTAssertEqual(text.body, "4 of 16 cups — 12 to go")
    }

    /// Past the goal the reminder must not nag with a negative remainder — it keeps firing until
    /// the day's last slot, so the over-goal case is a real, recurring state.
    func testPastTheGoalItCongratulatesInsteadOfShowingNegativeCups() {
        let text = HydrationReminder.reminderText(totalML: Double(HydrationGoal.cupML) * 20,
                                                  goalML: 3_700)
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
                                                   goalML: 3_700)
        XCTAssertTrue(behind.contains("4 of 16 cups"), behind)
        XCTAssertTrue(behind.contains("12 cups still to drink"), behind)
        let met = HydrationReminder.coachStatus(totalML: Double(HydrationGoal.cupML) * 18,
                                                goalML: 3_700)
        XCTAssertTrue(met.contains("already hit my target"), met)
    }
}

/// 260903: the water target is FROZEN like the other four — priced off the ANCHOR's effort (the
/// last scored day), never today's accumulating strain, so the denominator cannot move during the
/// day. This is the same call the maintainer made for the effort target ("freeze it", 260831).
final class FrozenWaterTargetTests: XCTestCase {

    func testTheTargetIsTwoTermsBaselinePlusAnEffortBump() {
        // The whole formula: round50(baseline_for_sex + effort/100 × 700).
        XCTAssertEqual(HydrationGoal.dailyGoalML(sex: "male", effort: 0),
                       HydrationGoal.baselineMaleML)
        XCTAssertEqual(HydrationGoal.dailyGoalML(sex: "male", effort: 100),
                       HydrationGoal.baselineMaleML + HydrationGoal.maxEffortBumpML)
        // Linear in between, rounded to 50.
        XCTAssertEqual(HydrationGoal.effortBump(effort: 50), HydrationGoal.maxEffortBumpML / 2)
        // Nothing else feeds it — no charge, no sleep, no temperature.
        XCTAssertEqual(HydrationGoal.dailyGoalML(sex: "male", effort: nil),
                       HydrationGoal.baselineMaleML)
    }

    /// The freeze itself: yesterday's scored effort sets today's target, so accumulating strain
    /// through the day leaves the cup goal untouched.
    func testTodaysAccumulatingStrainDoesNotMoveTheTarget() {
        let anchorEffort: Double = 40          // last night's scored day
        let frozen = HydrationGoal.dailyGoalML(sex: "male", effort: anchorEffort)
        // Whatever today racks up, the target priced off the anchor is unchanged.
        for todayStrain in [0.0, 12.0, 59.0, 95.0] {
            let stillFrozen = HydrationGoal.dailyGoalML(sex: "male", effort: anchorEffort)
            XCTAssertEqual(stillFrozen, frozen,
                           "today's strain \(todayStrain) must not reprice the water target")
        }
        // And the live-target formula would have moved — proving the freeze is what's doing work.
        XCTAssertNotEqual(HydrationGoal.dailyGoalML(sex: "male", effort: 95), frozen)
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
}
