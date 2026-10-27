import Foundation
import UserNotifications
import StrandAnalytics

/// A notification when NSS reaches the high band (261026, maintainer: "I want a notification when NSS
/// exceeds 67"). 67 is the Stress screen's HIGH cut (NSS × 3/100 ≥ 2), the top gridline on the NSS chart.
///
/// Evaluated on every `NormalizedStressStore.update`, so it moves on the strap's sync cadence like the
/// score itself; the reading is the smoothed one every surface shows, so the banner can never quote a
/// number the Stress tab does not. Exercise and its recovery are never scored (261025), so a workout
/// cannot set this off. Gates, in `decide` (pure, pinned by `NSSNotifierTests`):
/// - FRESH only: a reading more than `maxAgeSeconds` old (the last one before a workout or a strap gap)
///   neither fires nor re-arms — a banner must be about now.
/// - ONE per high stretch: firing disarms it, and it re-arms only once NSS drops below `rearmBelow`, so
///   a reading wobbling around 67 does not buzz on every sync.
/// - At most one per `cooldownSeconds` even across stretches.
/// Tapping it opens the Stress tab (`NotificationPresenter.onNSSHighTapped`). On by default; the switch
/// is on the Stress tab's "How NSS works" card. Fork-only: no Kotlin twin.
enum NSSNotifier {
    static let categoryId = "nss-high"
    static let threshold = 67.0
    static let rearmBelow = 60.0
    static let cooldownSeconds = 3_600
    static let maxAgeSeconds = 15 * 60

    static let enabledKey = "nss.notifyHigh"
    private static let armedKey = "nss.notifyArmed"
    private static let lastFiredKey = "nss.notifyLastFired"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Whether to post now, and the armed state to keep. Pure.
    static func decide(nss: Double?, readingTs: Int?, now: Int, armed: Bool,
                       lastFired: Int?) -> (post: Bool, armed: Bool) {
        guard let nss, let ts = readingTs, now - ts <= maxAgeSeconds else { return (false, armed) }
        if nss < rearmBelow { return (false, true) }
        guard armed, nss >= threshold else { return (false, armed) }
        if let last = lastFired, now - last < cooldownSeconds { return (false, armed) }
        return (true, false)
    }

    /// Run the gates against the snapshot just published, post when they say so, and return a log line
    /// when it posted (nil otherwise).
    @MainActor
    static func evaluate(_ s: NormalizedStressStore.Snapshot, now: Int) -> String? {
        guard enabled else { return nil }
        let d = UserDefaults.standard
        let armed = d.object(forKey: armedKey) as? Bool ?? true
        let last = d.object(forKey: lastFiredKey) as? Int
        let decision = decide(nss: s.current?.nss, readingTs: s.current?.ts, now: now, armed: armed,
                              lastFired: last)
        if decision.armed != armed { d.set(decision.armed, forKey: armedKey) }
        guard decision.post, let c = s.current else { return nil }
        d.set(now, forKey: lastFiredKey)
        post(title: title(c), body: body(c, typical: s.typical, now: now))
        return "nss: high notification posted (NSS \(Int(c.nss.rounded())), \(max(0, (now - c.ts) / 60)) min old)"
    }

    static func title(_ c: NormalizedStress.Reading) -> String {
        String(localized: "Stress is high — NSS \(Int(c.nss.rounded()))")
    }

    static func body(_ c: NormalizedStress.Reading, typical: Double?, now: Int) -> String {
        var out = NSSCard.explanation(c, unscoredNow: nil)
        if let typical { out += " " + String(localized: "Your typical is \(Int(typical.rounded())).") }
        let age = (now - c.ts) / 60
        if age >= 5 { out += " " + String(localized: "From your last strap sync, \(age) min ago.") }
        return out + " " + String(localized: "A few slow breaths can bring it down.")
    }

    private static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = categoryId
            // A fixed identifier: a new high replaces the last banner rather than stacking.
            center.add(UNNotificationRequest(identifier: categoryId, content: content, trigger: nil))
        }
    }
}
