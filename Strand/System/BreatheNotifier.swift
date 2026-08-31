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
    /// `minutesAgo` marks a BURST-RETROSPECTIVE detection (the dip was found in just-synced data, up
    /// to one sync cadence after it happened) — the copy then says so, because "take a deep breath"
    /// must never imply a right-now reading the app didn't have.
    static func post(minutesAgo: Int? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Take a deep breath")
            var body = String(localized: "Your beat-to-beat variability dipped well below your own baseline while you were still — a one-minute guided breath is ready in NOOP.")
            if let minutesAgo, minutesAgo > 0 {
                body += " " + String(localized: "Detected on your last strap sync, about \(minutesAgo) min ago.")
            }
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "stress-breathe",
                                             content: content, trigger: nil))
        }
    }
}
