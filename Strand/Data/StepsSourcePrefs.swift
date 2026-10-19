import Foundation

/// Which step count the app should PREFER when both the strap and Apple Health have one (260905).
///
/// Maintainer request: a toggle choosing between the strap's own counter and the Apple Watch's,
/// with the choice applying "consistent everywhere — both the n in the steps n/t as well as the
/// steps tile on the daily page".
///
/// Default is `.strap`, which is the behaviour every build before this one had: the merged
/// `Repository.days` row carries the strap's count, and Apple's is only consulted by the Today
/// tiles as a fallback when the strap banked none. Flipping to `.appleHealth` inverts that
/// precedence at the ONE place Apple steps enter the merged rows, so every reader downstream —
/// the Today tile, the targets strip's numerator, pacing, day quality, the coach — moves together
/// rather than each surface having to know about the preference.
///
/// Deliberately NOT a general "prefer Apple for everything" switch. It covers STEPS only, because
/// steps are the one metric where the two devices measure the same physical thing in the same unit
/// and the wrist-worn phone-paired watch is often the better pedometer. Calories are a different
/// question (NOOP's figure is an HR-derived estimate that also feeds strain), and are left alone.
enum StepsSource: String, CaseIterable, Identifiable {
    case strap
    case appleHealth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .strap:       return String(localized: "Strap")
        case .appleHealth: return String(localized: "Apple Health")
        }
    }
}

enum StepsSourcePrefs {
    static let key = "steps.preferredSource"

    private static var d: UserDefaults { .standard }

    /// The wearer's choice. Absent = `.strap`, matching every prior build.
    static var preferred: StepsSource {
        StepsSource(rawValue: d.string(forKey: key) ?? "") ?? .strap
    }

    /// Posted when the choice changes, so the iOS HealthKit bridge can arm or retire its step
    /// observer. A notification rather than a direct call because the only UI that sets this
    /// (`AutomationsView`) is shared with macOS, where `HealthKitBridge` does not exist — reaching
    /// for it there would need a platform fork in the view for what is a one-line side effect.
    static let didChangeNotification = Notification.Name("noop.stepsSourceDidChange")

    static func setPreferred(_ s: StepsSource) {
        guard s != preferred else { return }
        d.set(s.rawValue, forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// True when Apple Health's count should win a day both sources cover.
    static var prefersAppleHealth: Bool { preferred == .appleHealth }
}
