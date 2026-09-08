import XCTest
@testable import Strand

/// The strap double-tap's configurable gesture window and its confirmation notification (260907).
///
/// Reported: "the double tap for water still feels somewhat sensitive — can we make sure when I do
/// the tap, there is a notification indicating that water has been logged?"
///
/// Two distinct mechanisms, and conflating them is the mistake worth guarding against:
///
///   * the 16.13 event-timestamp dedup makes ONE physical tap fire exactly once, always. It is
///     structural and must never become a setting — a knob there invites someone to break it.
///   * THIS window is how far apart two SEPARATE taps must be to count as two intentional acts.
///     That is a matter of preference, so it is a setting.
@MainActor
final class WaterTapWindowTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: WaterTapPrefs.windowKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WaterTapPrefs.windowKey)
        super.tearDown()
    }

    /// The default moved UP from the old hard-coded 1.2 s, because 1.2 s is what the "still feels
    /// sensitive" report was raised against. Shipping the complained-about value as the new default
    /// would have been a setting that changes nothing for anyone who never opens it.
    func testTheDefaultIsLooserThanTheOldHardCodedDebounce() {
        XCTAssertGreaterThan(Double(WaterTapPrefs.window), 1.2,
                             "the default must be looser than the value the report was about")
        XCTAssertEqual(WaterTapPrefs.window, WaterTapPrefs.defaultWindow)
    }

    /// Clamped on READ, not only on write. A value can arrive from a restored backup or a hand-set
    /// default, and a 0 there would disable the guard entirely rather than merely being odd.
    func testAnOutOfRangeStoredValueIsClampedOnRead() {
        UserDefaults.standard.set(0, forKey: WaterTapPrefs.windowKey)
        XCTAssertEqual(WaterTapPrefs.window, WaterTapPrefs.minWindow, "0 must not disable the guard")
        UserDefaults.standard.set(9999, forKey: WaterTapPrefs.windowKey)
        XCTAssertEqual(WaterTapPrefs.window, WaterTapPrefs.maxWindow)
        UserDefaults.standard.set(-5, forKey: WaterTapPrefs.windowKey)
        XCTAssertEqual(WaterTapPrefs.window, WaterTapPrefs.minWindow)
    }

    /// A value inside the range is honoured exactly — the setting has to actually do something.
    func testAnInRangeValueIsHonoured() {
        UserDefaults.standard.set(7, forKey: WaterTapPrefs.windowKey)
        XCTAssertEqual(WaterTapPrefs.window, 7)
    }

    /// The bounds are sane: a floor below 1 s would have the wearer fighting the firmware's own
    /// detector, and a ceiling past 30 s would make a deliberate second cup feel broken — trading
    /// one complaint for a worse one.
    func testTheOfferedRangeIsSane() {
        XCTAssertGreaterThanOrEqual(WaterTapPrefs.minWindow, 1)
        XCTAssertLessThanOrEqual(WaterTapPrefs.maxWindow, 30)
        XCTAssertLessThan(WaterTapPrefs.minWindow, WaterTapPrefs.maxWindow)
    }

    /// The debounce must READ the pref, not a constant. This is the wiring that makes the setting
    /// real, and a reverted constant here would leave a knob that silently does nothing.
    func testTheDebounceReadsThePref() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Strand/App/AppModel.swift"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("WaterTapPrefs.window"),
                      "handleDoubleTap must consult the configurable window")
        XCTAssertFalse(src.contains("lastDoubleTapAt) > 1.2"),
                       "the old hard-coded 1.2 s debounce must be gone")
    }

    // MARK: - The confirmation notification

    /// The body names the cup AND the running total. The total is what makes an accidental log
    /// obvious — "11 of 21" when you have drunk eight is the tell.
    func testTheConfirmationStatesTheCupAndTheTotal() {
        let body = WaterTapConfirmation.body(cups: 9, goalCups: 21)
        XCTAssertTrue(body.contains("9"), body)
        XCTAssertTrue(body.contains("21"), body)
        XCTAssertTrue(body.lowercased().contains("cup"), body)
    }

    /// Undo is the load-bearing half of the fix: a confirmation alone would only make a false
    /// positive VISIBLE, leaving the wearer to open the app and edit hydration to correct it.
    func testTheCategoryOffersUndo() {
        let ids = WaterTapConfirmation.category.actions.map(\.identifier)
        XCTAssertEqual(ids, [WaterTapConfirmation.undoActionId],
                       "exactly one action, Undo — not 'add another', which is the wrong "
                       + "affordance on a surface that exists to take a cup back")
    }

    /// The undo carries the ENTRY ID, not an amount. Undoing "the latest cup" would delete the wrong
    /// drink if a reminder-driven cup or an in-app +Cup landed in between.
    func testTheUndoIsKeyedOnTheEntryIdNotAnAmount() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
        let presenter = try String(
            contentsOf: root.appendingPathComponent("Strand/System/NotificationPresenter.swift"),
            encoding: .utf8)
        XCTAssertTrue(presenter.contains("WaterTapConfirmation.entryIdKey"),
                      "the undo handler must resolve the entry id from userInfo")
        XCTAssertTrue(presenter.contains("waterUndoSink"),
                      "and route it through its own sink — the amount-based hydration sink cannot "
                      + "express a delete-by-id")
    }
}
