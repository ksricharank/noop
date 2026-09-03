import Foundation
import UserNotifications

/// Foreground presentation delegate for the app's local notifications (wind-down nudge, smart-alarm
/// backup, battery/illness alerts).
///
/// Without a `UNUserNotificationCenterDelegate`, iOS/macOS suppress a notification's banner while the
/// app is in the FOREGROUND (the default). A user testing a reminder with the app open would see
/// nothing and conclude notifications are broken. Returning banner + sound + list here makes them
/// visible whether the app is open or not — matching what the user expects from a reminder.
///
/// Cross-platform (iOS + macOS). Register once at launch:
/// `UNUserNotificationCenter.current().delegate = NotificationPresenter.shared`.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationPresenter()

    private override init() { super.init() }

    /// K5: wired by the app root (`StrandApp` on macOS, `StrandiOSApp` on iOS) at launch to route a
    /// tapped scheduled morning-brief notification to the Coach screen via `NavRouter.openCoach()`. nil
    /// is a safe no-op (the tap is simply not routed) rather than a crash if this ever fires before the
    /// root has wired it.
    var onCoachBriefTapped: (() -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// The hook that gives a notification an ACTION (260902, the hydration reminder's "Logged a
    /// cup"). iOS delivers a response only for a tapped action button or a tapped body — a
    /// swipe-away/dismiss is never reported, which is exactly the wanted behaviour here: ignoring
    /// the reminder logs nothing.
    ///
    /// The cup is written through the EXISTING hydration tracker (`Repository.logHydration`), the
    /// same call the app's own +Cup button makes, so the notification can never diverge from the
    /// Today card. `hydrationActionSink` is installed by the app at launch; when it is nil (a
    /// response arriving before the model exists) the tap is dropped rather than queued — one
    /// missed cup is a smaller wrong than a phantom one logged minutes later against the wrong day.
    var hydrationActionSink: ((@escaping () -> Void) -> Void)?

    /// Handle a tap on a delivered notification. Only the scheduled morning-brief category (K5) routes
    /// anywhere; every other notification (wind-down, smart-alarm, battery/illness) just opens the app
    /// to wherever it was, matching the pre-K5 behaviour.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // A scheduled morning-brief tap routes to Coach. It does not consume the response, so the
        // hydration-action check below still runs for any other category.
        if response.notification.request.content.categoryIdentifier == CoachBriefScheduler.notificationCategoryId {
            onCoachBriefTapped?()
        }
        guard response.actionIdentifier == HydrationReminder.logCupActionId,
              let sink = hydrationActionSink else {
            completionHandler()
            return
        }
        sink(completionHandler)
    }
}
