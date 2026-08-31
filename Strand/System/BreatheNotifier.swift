import Foundation
import UserNotifications

/// Surfaces the stress check-in's auto-nudge as a SCREEN notification alongside the strap's
/// confirming buzz (260830, maintainer request): with the Live Activity retired from daily use, the
/// buzz alone says "something", and only the phone can say "take a deep breath". Same shape as
/// `IllnessNotifier`: ask for permission at the moment the user flips the toggle, post
/// status-checked (never a surprise second system prompt), honest and non-clinical.
///
/// No rate limit of its own — the detector's event form (`StressOnsetDetector.evaluate`) already
/// carries the de-dup, sustain, quiet-hours and rate-limit gates, and this posts ONLY on a fired
/// nudge. A fixed identifier means a fresh nudge replaces the previous banner rather than stacking.
enum BreatheNotifier {
    /// Ask up front (called when the user enables the screen notification or the auto-nudge) so the
    /// system dialog appears at a predictable moment, not mid-dip.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post the breathe prompt. Fires only from an auto-nudge the detector already gated.
    static func post() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Take a deep breath")
            content.body = String(localized: "Your beat-to-beat variability dipped well below your own baseline while you were still — a one-minute guided breath is ready in NOOP.")
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "stress-breathe",
                                             content: content, trigger: nil))
        }
    }
}
