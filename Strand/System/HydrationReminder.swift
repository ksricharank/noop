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

    /// Whole cups from a millilitre figure, rounded to nearest (the maintainer asked for rounded
    /// cups, not decimals): 237 ml = 1 cup, the same `HydrationGoal.cupML` the +Cup button logs.
    static func cups(fromML ml: Double) -> Int {
        Int((ml / Double(HydrationGoal.cupML)).rounded())
    }

    /// The reminder's copy: today's cup goal, cups drunk, cups left. `left` never goes negative —
    /// past the goal it congratulates instead of nagging, since the reminder keeps firing until the
    /// day's last slot and a "-2 cups left" would read as a bug.
    static func reminderText(totalML: Double, goalML: Int) -> (title: String, body: String) {
        let drunk = cups(fromML: totalML)
        let goal = max(1, cups(fromML: Double(goalML)))
        let left = max(0, goal - drunk)
        let title = String(localized: "Water break")
        // Past the goal the reminders KEEP coming to the day's last slot (the maintainer's call:
        // hydration is not a finish line), so the over-goal copy has to encourage rather than
        // nag — a "-2 cups left" would read as a bug, and "nothing left to do" is wrong.
        if left == 0 {
            return (title, String(format: String(localized: "%d of %d cups — you're there, keep sipping"),
                                  drunk, goal))
        }
        return (title, String(format: String(localized: "%d of %d cups — %d to go"), drunk, goal, left))
    }

    /// The status line handed to the coach for a written title (260903) — the same figures the body
    /// states, in the plain-language shape `AICoach.notificationTitle` expects.
    static func coachStatus(totalML: Double, goalML: Int) -> String {
        let drunk = cups(fromML: totalML)
        let goal = max(1, cups(fromML: Double(goalML)))
        if drunk >= goal {
            return "Water: \(drunk) of \(goal) cups today — I have already hit my target"
        }
        return "Water: \(drunk) of \(goal) cups today — \(goal - drunk) cups still to drink"
    }

    // MARK: - Notification category + actions

    static let categoryId = "noop.hydration.reminder"
    static let logCupActionId = "noop.hydration.logCup"
    static let logHalfCupActionId = "noop.hydration.logHalfCup"
    static let requestIdPrefix = "hydration-reminder-"

    /// The action shown when the banner is expanded (long-press on the Lock Screen, or swipe →
    /// tap). `.authenticationRequired` is deliberately NOT set: logging a cup is trivial and
    /// harmless, and requiring Face ID for it would defeat the point of a one-gesture log. Tapping
    /// the notification BODY instead opens the app (iOS reserves that gesture) — the app then
    /// routes to the hydration screen.
    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryId,
            // Full cup first: it is the common case, and iOS shows the first action closest to
            // the thumb when the banner is expanded.
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

    private static var pendingIds: [String] {
        // Cover the widest possible grid (30-minute interval from 04:00) so a re-schedule always
        // clears every id a previous setting could have created.
        stride(from: 0, through: lastSlotMinute, by: 30).map { "\(requestIdPrefix)\($0)" }
    }

    // MARK: - Scheduling

    /// Enable/disable, mirroring `WindDownNudge.setEnabled`: ask for permission at the moment of
    /// intent, schedule on grant, and never leave the toggle on when the OS said no.
    static func setEnabled(_ on: Bool, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard on else {
            d.set(false, forKey: K.enabled)
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: pendingIds)
            Task { @MainActor in completion?(false) }
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in
                    d.set(true, forKey: K.enabled)
                    schedule()
                    completion?(true)
                }
            case .notDetermined:
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        Task { @MainActor in
                            d.set(granted, forKey: K.enabled)
                            if granted { schedule() }
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
        if isEnabled { schedule() }
    }

    static func setIntervalMinutes(_ minutes: Int) {
        d.set(min(max(minutes, 30), 240), forKey: K.intervalMin)
        if isEnabled { schedule() }
    }

    /// (Re)schedule the day's repeating slots. Always clears the full id space first, so an edit
    /// replaces rather than stacks.
    static func schedule() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: pendingIds)
        center.setNotificationCategories([category])
        guard isEnabled else { return }
        // The copy is rebuilt at fire time from a snapshot the app refreshes on every hydration
        // change / sync (see `HydrationReminder.refreshSnapshot`). A repeating calendar trigger
        // cannot compute its body at fire time, so the snapshot is the honest compromise: the cups
        // shown are as of the app's last update, and the action re-reads live state when tapped.
        let (title, body) = snapshotText()
        for slot in slotMinutes(startMinute: startMinute, intervalMinutes: intervalMinutes) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = categoryId
            var comps = DateComponents()
            comps.hour = slot / 60
            comps.minute = slot % 60
            center.add(UNNotificationRequest(
                identifier: "\(requestIdPrefix)\(slot)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
        }
    }

    // MARK: - Snapshot (so a fired reminder can state today's cups)

    private static let snapTotalKey = "hydration.reminder.snapTotalML"
    private static let snapGoalKey = "hydration.reminder.snapGoalML"
    private static let snapDayKey = "hydration.reminder.snapDay"

    /// Record today's hydration figures for the next fired reminder to describe, and re-arm the
    /// pending requests so their copy is current. Called whenever the tracker changes or a sync
    /// lands. A day roll resets the drunk figure to 0 so the morning's first reminder is honest.
    static func refreshSnapshot(totalML: Double, goalML: Int, dayKey: String) {
        let sameDay = d.string(forKey: snapDayKey) == dayKey
        let prevTotal = sameDay ? d.double(forKey: snapTotalKey) : -1
        let prevGoal = sameDay ? d.integer(forKey: snapGoalKey) : -1
        d.set(dayKey, forKey: snapDayKey)
        d.set(totalML, forKey: snapTotalKey)
        d.set(goalML, forKey: snapGoalKey)
        // Only re-arm when the copy would actually change — rescheduling ~17 requests on every
        // hydration read would be needless churn.
        guard isEnabled, cups(fromML: prevTotal) != cups(fromML: totalML) || prevGoal != goalML else { return }
        schedule()
    }

    /// A coach-written title to use for the next scheduled reminders, cached at schedule time.
    ///
    /// The reminders fire from repeating CALENDAR triggers with no app running, so nothing can
    /// generate copy at fire time. The honest shape is therefore: the app asks the coach for a
    /// title whenever it re-arms the slots (a cup logged, a sync, a settings edit) and caches it
    /// beside the figures; a fired reminder shows that. Absent or stale (a different day), the
    /// static "Water break" is used.
    private static let coachTitleKey = "hydration.reminder.coachTitle"
    private static let coachTitleDayKey = "hydration.reminder.coachTitleDay"

    static func cacheCoachTitle(_ title: String?, dayKey: String) {
        if let title, !title.isEmpty {
            d.set(title, forKey: coachTitleKey)
            d.set(dayKey, forKey: coachTitleDayKey)
        } else {
            d.removeObject(forKey: coachTitleKey)
            d.removeObject(forKey: coachTitleDayKey)
        }
    }

    private static func cachedCoachTitle() -> String? {
        guard d.string(forKey: coachTitleDayKey) == Repository.localDayKey(Date()) else { return nil }
        let t = d.string(forKey: coachTitleKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }

    private static func snapshotText() -> (String, String) {
        let today = Repository.localDayKey(Date())
        guard d.string(forKey: snapDayKey) == today else {
            // No figures for today yet (fresh day, app not opened): state the goal only.
            let goal = max(1, cups(fromML: Double(d.integer(forKey: snapGoalKey))))
            return (String(localized: "Water break"),
                    String(format: String(localized: "%d cups today — time for one"), goal))
        }
        let text = reminderText(totalML: d.double(forKey: snapTotalKey),
                                goalML: d.integer(forKey: snapGoalKey))
        return (cachedCoachTitle() ?? text.title, text.body)
    }
}
