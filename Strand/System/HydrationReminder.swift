import Foundation
import UserNotifications
import StrandAnalytics

/// The hydration REMINDER (260902) — a scheduling + notification layer over the EXISTING hydration
/// tracker (`HydrationStore` / `HydrationGoal` / the Today card), never a second water tracker. The
/// cups it counts, the goal it measures against and the log its action writes to are the same ones
/// the app's own hydration screen uses, so the two surfaces can never disagree.
///
/// Shape (maintainer, 260902): two settings beside the existing Hydration tracking toggle — a START
/// TIME and a REMINDER INTERVAL — and a notification carrying today's cup goal, cups drunk and cups
/// left, with a "Logged a cup" action that writes through to the tracker without opening the app.
/// The daily cup GOAL is derived, not configured: `HydrationGoal.dailyGoalML` already prices it off
/// profile + today's effort, and a second hand-set number would disagree with the Today card the
/// moment effort moved. Rendered in ROUNDED CUPS for the reminder's copy.
///
/// Scheduled as repeating `UNCalendarNotificationTrigger`s (the `WindDownNudge` idiom): they live in
/// the notification centre, not our process, so reminders keep firing with the app killed. One
/// request per slot from the start time to the end of the day; iOS's 64-pending-notification cap is
/// never approached (a 1 h interval from 07:00 yields 17).
enum HydrationReminder {

    // MARK: - Prefs

    enum K {
        static let enabled = "hydration.reminder.enabled"
        static let startMin = "hydration.reminder.startMin"        // default 08:00
        static let intervalMin = "hydration.reminder.intervalMin"  // default 90 min
    }

    private static var d: UserDefaults { .standard }

    static var isEnabled: Bool { d.bool(forKey: K.enabled) }

    /// First reminder of the day, local minute-of-day. Clamped to sane waking hours.
    static var startMinute: Int {
        let v = d.object(forKey: K.startMin) as? Int ?? 8 * 60
        return min(max(v, 4 * 60), 14 * 60)
    }

    /// Minutes between reminders. The UI offers 60/90/120/150/180; clamped here so a stray write
    /// can never schedule a reminder storm.
    static var intervalMinutes: Int {
        let v = d.object(forKey: K.intervalMin) as? Int ?? 90
        return min(max(v, 30), 240)
    }

    /// The last slot of the day — no reminders past this, so a late interval can't buzz at 01:00.
    static let lastSlotMinute = 22 * 60

    // MARK: - Pure policy

    /// Reminder instants for a start time + interval: every `interval` minutes from `start` through
    /// the day's last slot. Pure so the grid is pinned without a clock.
    static func slotMinutes(startMinute: Int, intervalMinutes: Int) -> [Int] {
        let step = max(30, intervalMinutes)
        return Array(stride(from: startMinute, through: lastSlotMinute, by: step))
    }

    /// Whole cups from a millilitre figure — delegated to `HydrationGoal` so the reminder cannot
    /// round differently from the Today row (260903: it did).
    static func cups(fromML ml: Double) -> Int { HydrationGoal.cups(fromML: ml) }

    /// The reminder's copy: today's cup goal, cups drunk, cups left.
    ///
    /// `goalCups` is the goal the Today ROW shows — passed in, never recomputed here. 260903: the
    /// reminder used to derive it from `hydrationGoalML` (the retired millilitre formula) and
    /// re-round the drunk figure to whole cups, so the notification read "2/16" while the row read
    /// "3/19" — two formulas and two roundings for one number. Both now come from the one
    /// `LiveTargets` the row reads.
    ///
    /// Drunk is rendered at the ROW's granularity (half-cups: "2.5"), not re-rounded to whole cups.
    static func reminderText(totalML: Double, goalCups: Int) -> (title: String, body: String) {
        let drunkHalves = HydrationGoal.halfCups(fromML: totalML)
        let drunk = HydrationGoal.cupsDisplay(halfCups: drunkHalves)
        let goal = max(1, goalCups)
        // `left` counts WHOLE cups still to drink and never goes negative: the reminders keep
        // coming to the day's last slot (hydration is not a finish line), so the over-goal copy
        // has to encourage rather than show a "-2 cups left" that reads as a bug.
        let left = max(0, goal - Int((Double(drunkHalves) / 2.0).rounded(.down)))
        let title = String(localized: "Water break")
        if left == 0 {
            return (title, String(format: String(localized: "%@ of %d cups — you're there, keep sipping"),
                                  drunk, goal))
        }
        return (title, String(format: String(localized: "%@ of %d cups — %d to go"), drunk, goal, left))
    }

    /// The status line handed to the coach for a written title (260903) — the same figures the body
    /// states, in the plain-language shape `AICoach.notificationTitle` expects.
    static func coachStatus(totalML: Double, goalCups: Int) -> String {
        let drunk = HydrationGoal.cupsDisplay(halfCups: HydrationGoal.halfCups(fromML: totalML))
        let goal = max(1, goalCups)
        let left = max(0, goal - Int((Double(HydrationGoal.halfCups(fromML: totalML)) / 2.0).rounded(.down)))
        if left == 0 {
            return "Water: \(drunk) of \(goal) cups today — I have already hit my target"
        }
        return "Water: \(drunk) of \(goal) cups today — \(left) cups still to drink"
    }

    // MARK: - Notification category + actions

    static let categoryId = "noop.hydration.reminder"
    static let logCupActionId = "noop.hydration.logCup"
    static let logHalfCupActionId = "noop.hydration.logHalfCup"

    /// The actions shown when the banner is expanded (long-press on the Lock Screen, or swipe →
    /// tap). `.authenticationRequired` is deliberately NOT set: logging a cup is trivial and
    /// harmless, and requiring Face ID for it would defeat a one-gesture log. Tapping the
    /// notification BODY opens the app — iOS reserves that gesture and it cannot be reassigned.
    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryId,
            // Full cup first: the common case sits closest to the thumb when expanded.
            actions: [
                UNNotificationAction(identifier: logCupActionId,
                                     title: String(localized: "Add a cup"),
                                     options: []),
                UNNotificationAction(identifier: logHalfCupActionId,
                                     title: String(localized: "Add half a cup"),
                                     options: []),
            ],
            intentIdentifiers: [],
            options: [])
    }

    // MARK: - Sync-driven firing (260903)
    //
    // The reminder used to be a set of repeating `UNCalendarNotificationTrigger`s: punctual, but
    // fired with NOOP not running, which meant (a) no wrist buzz was possible, and (b) the copy
    // was a snapshot written at schedule time, so a fired reminder could state a stale cup count.
    //
    // It now rides the strap sync like every other automation. The strap pushes data every ~10
    // minutes, iOS wakes NOOP to receive it, and the post-offload path asks "has a slot passed
    // since the last reminder?". The app is therefore AWAKE when the reminder posts: it can buzz
    // the strap, and it reads the live cup count instead of a snapshot.
    //
    // The trade, stated: a calendar trigger fired at 09:30 exactly; this fires at the first sync
    // after 09:30 — typically within ~10 minutes, later if the strap is off or out of range. On a
    // hydration nudge that drift is immaterial, and it buys the buzz and a live count.

    private static let lastFiredSlotKey = "hydration.reminder.lastFiredSlot"
    private static let lastFiredDayKey = "hydration.reminder.lastFiredDay"

    /// The most recent slot at or before `minuteOfDay`, or nil before the day's first slot.
    static func dueSlot(minuteOfDay: Int, startMinute: Int, intervalMinutes: Int) -> Int? {
        slotMinutes(startMinute: startMinute, intervalMinutes: intervalMinutes)
            .last { $0 <= minuteOfDay }
    }

    /// Should a reminder post right now? True when a slot has passed that this day has not already
    /// been reminded for. Pure, so the schedule is pinned without a clock or a notification centre.
    ///
    /// Only the LATEST due slot fires: a phone that was away for hours owes one reminder, not six.
    static func reminderWanted(enabled: Bool, minuteOfDay: Int, startMinute: Int,
                               intervalMinutes: Int, lastFiredSlot: Int?, isNewDay: Bool) -> Bool {
        guard enabled else { return false }
        guard let due = dueSlot(minuteOfDay: minuteOfDay, startMinute: startMinute,
                                intervalMinutes: intervalMinutes) else { return false }
        if isNewDay { return true }
        guard let lastFiredSlot else { return true }
        return due > lastFiredSlot
    }

    /// Day-keyed bookkeeping for the above.
    static func lastFiredSlot(today: String) -> Int? {
        guard d.string(forKey: lastFiredDayKey) == today else { return nil }
        let v = d.integer(forKey: lastFiredSlotKey)
        return v > 0 || d.object(forKey: lastFiredSlotKey) != nil ? v : nil
    }

    static func markFired(slot: Int, today: String) {
        d.set(today, forKey: lastFiredDayKey)
        d.set(slot, forKey: lastFiredSlotKey)
    }

    /// Enable/disable. No scheduling any more — the sync path decides when to post — so this only
    /// records the choice and secures notification permission at the moment of intent.
    static func setEnabled(_ on: Bool, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard on else {
            d.set(false, forKey: K.enabled)
            Task { @MainActor in completion?(false) }
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in
                    d.set(true, forKey: K.enabled)
                    completion?(true)
                }
            case .notDetermined:
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        Task { @MainActor in
                            d.set(granted, forKey: K.enabled)
                            completion?(granted)
                        }
                    }
            default:
                Task { @MainActor in
                    d.set(false, forKey: K.enabled)
                    completion?(false)
                }
            }
        }
    }

    static func setStartMinute(_ minutes: Int) {
        d.set(min(max(minutes, 4 * 60), 14 * 60), forKey: K.startMin)
    }

    static func setIntervalMinutes(_ minutes: Int) {
        d.set(min(max(minutes, 30), 240), forKey: K.intervalMin)
    }

    /// Post one reminder now, with live figures. Called from the post-offload path.
    static func post(totalML: Double, goalCups: Int, title: String?) {
        let text = reminderText(totalML: totalML, goalCups: goalCups)
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title ?? text.title
            content.body = text.body
            content.sound = .default
            content.categoryIdentifier = categoryId
            // A fixed identifier so a fresh reminder REPLACES the previous banner rather than
            // stacking a pile of them through the day.
            center.add(UNNotificationRequest(identifier: "hydration-reminder",
                                             content: content, trigger: nil))
        }
    }
}
