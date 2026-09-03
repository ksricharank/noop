import Foundation
import UserNotifications
import StrandAnalytics

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
    var hydrationActionSink: ((Int, @escaping () -> Void) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let amount: Int?
        switch response.actionIdentifier {
        case HydrationReminder.logCupActionId: amount = HydrationGoal.cupML
        case HydrationReminder.logHalfCupActionId: amount = HydrationGoal.halfCupML
        default: amount = nil
        }
        guard let amount, let sink = hydrationActionSink else {
            completionHandler()
            return
        }
        sink(amount, completionHandler)
    }
}
