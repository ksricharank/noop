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
        XCTAssertEqual(text.body, "20 of 16 cups — you're there. Keep sipping.")
    }

    func testTheActionIsOfferedOnTheCategoryTheRemindersUse() {
        let category = HydrationReminder.category
        XCTAssertEqual(category.identifier, HydrationReminder.categoryId)
        XCTAssertEqual(category.actions.map(\.identifier), [HydrationReminder.logCupActionId])
        // No authentication requirement: logging a cup must stay a one-gesture action.
        XCTAssertFalse(category.actions[0].options.contains(.authenticationRequired))
    }
}
