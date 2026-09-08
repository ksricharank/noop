import Foundation
import UserNotifications

/// The confirmation a strap double-tap posts after logging a cup, and the undo that goes with it.
///
/// 260907, reported: "the double tap for water still feels somewhat sensitive — can we make sure
/// when I do the tap, there is a notification indicating that water has been logged?"
///
/// The tap already buzzes the strap, but a buzz says only "something happened" — it cannot say WHAT,
/// and on a gesture with no on-screen feedback that is the whole question. A notification names the
/// action and the new total.
///
/// ## Why undo is the load-bearing half
///
/// The report is about false positives, and a confirmation alone would only make them VISIBLE — the
/// wearer would still have to open the app and edit hydration to correct one. `Undo` makes a false
/// positive costless, which is the actual complaint. It is also why the notification is worth posting
/// at all rather than relying on the buzz: a buzz cannot carry an action.
///
/// ## Why not simply raise the debounce
///
/// 16.13 already made a duplicate structurally impossible (deduping on the event's own
/// `event_timestamp`), so what remains is the STRAP deciding a knock was a double-tap. That is
/// firmware, above our layer — we see a `DOUBLE_TAP` event and cannot tell a deliberate tap from a
/// bump. The gesture window is now user-configurable (`WaterTapPrefs`) so the wearer can trade
/// sensitivity for certainty themselves, and the undo covers whatever still slips through.
enum WaterTapConfirmation {

    static let categoryId = "noop.water.tapConfirm"
    static let undoActionId = "noop.water.undoTap"

    /// One action: Undo. Deliberately not "Add another" — this notification exists because a tap may
    /// have been ACCIDENTAL, and offering to log a second cup from it would be the wrong affordance
    /// on the surface whose purpose is to take one back.
    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryId,
            actions: [
                UNNotificationAction(identifier: undoActionId,
                                     title: String(localized: "Undo"),
                                     options: []),
            ],
            intentIdentifiers: [],
            options: [])
    }

    /// The confirmation body: what was logged, and where that leaves the day.
    ///
    /// States the CUP and the running total, because the total is what makes an accidental log
    /// obvious ("11 of 21" when you have drunk eight is the tell). Pure, so the copy is testable
    /// without a notification centre.
    static func body(cups: Int, goalCups: Int) -> String {
        String(localized: "Logged a cup from your strap — \(cups) of \(goalCups) cups today")
    }

    /// userInfo key carrying the id of the entry this notification's Undo should remove.
    ///
    /// The id is captured at POST time rather than resolved when Undo is tapped. Undoing "the most
    /// recent cup" would be wrong: if a reminder-driven cup or an in-app +Cup landed in between, the
    /// undo would silently delete THAT one instead of the accidental tap it was offered for.
    static let entryIdKey = "noop.water.entryId"
    static let dayKey = "noop.water.day"

    /// Post the confirmation for a specific logged entry.
    ///
    /// A FRESH identifier each time, so a second genuine tap does not silently replace the first
    /// notification and rob it of its undo. Time-sensitive is deliberately NOT requested: this is a
    /// receipt, not a summons, and it should not break through a Focus.
    @MainActor
    static func post(cups: Int, goalCups: Int, entryId: UUID, day: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Water logged")
        content.body = body(cups: cups, goalCups: goalCups)
        content.categoryIdentifier = categoryId
        content.userInfo = [entryIdKey: entryId.uuidString, dayKey: day]
        // Silent: the strap buzz already carried the alert, and a sound here would double it.
        content.sound = nil
        let req = UNNotificationRequest(identifier: "noop.water.tap.\(UUID().uuidString)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

/// How long the app ignores a second strap double-tap after acting on one.
///
/// 260907, maintainer's ask: a configurable gesture window "right at the top of the automations page
/// (in seconds?)".
///
/// This is NOT the 16.13 duplicate dedup — that one keys on the event's own timestamp and makes one
/// physical tap fire once, always, and is not a knob anyone should turn. This is the separate
/// question of how far apart two SEPARATE taps must be to count as two intentional acts. A wearer who
/// finds the gesture over-sensitive raises it; one who logs several cups in quick succession lowers
/// it.
enum WaterTapPrefs {

    static let windowKey = "noop.water.tapWindowSeconds"

    /// Seconds. 2 is the shipped default — the old hard-coded debounce was 1.2 s, and the report is
    /// that this still felt loose, so the default moves up rather than staying where the complaint
    /// was raised about it.
    static let defaultWindow = 2

    /// The range offered. Floored at 1 (below that a wearer is fighting the firmware's own detector,
    /// not this) and capped at 30 (beyond it a deliberate second cup would feel broken, which trades
    /// one complaint for a worse one).
    static let minWindow = 1
    static let maxWindow = 30

    static var window: Int {
        let stored = UserDefaults.standard.object(forKey: windowKey) as? Int ?? defaultWindow
        return clamp(stored)
    }

    /// Clamped on READ as well as on write: a value can arrive from a restored backup or a hand-set
    /// default, and a 0 there would disable the guard entirely rather than merely being odd.
    static func clamp(_ seconds: Int) -> Int { min(max(seconds, minWindow), maxWindow) }
}
