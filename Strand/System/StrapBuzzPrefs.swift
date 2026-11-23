import Foundation

/// How the strap buzzes for NOOP's notifications (261122, fork): the waveform and how many times it
/// repeats. Read by `BLEManager` when it builds a 5/MG buzz, so one setting moves every buzz the app
/// sends; the count applies to the notification buzz (`buzzStrapOnce`), the in-session cues keep
/// their own counts.
enum StrapBuzzPrefs {
    static let styleKey = "auto.wristBuzz.style"
    static let countKey = "auto.wristBuzz.count"

    /// The default count: what the notification buzz has always asked for.
    static let defaultCount = 3
    static let countRange = 1...8

    /// The waveform played for each buzz. Only `standard` is hardware-confirmed. The others read the
    /// strap's eight effect slots as a DRV2605-style sequencer (library effect ids; 152 = a 240 ms
    /// pause) — an unvalidated hypothesis, so each is offered for testing on the wrist with the Test
    /// buzz button. Strength is already at the top of that library's buzz range (47 = buzz 100%); the
    /// only levers for feeling it more are a longer pulse and more repeats.
    ///
    /// 261123: on the wrist, `pulsing` (effect 52) played ×6 as intended but ×8 left the strap
    /// buzzing until a Restart strap, and a 5/MG has no stop command NOOP can send. So each
    /// experimental style is capped at `maxCount` repeats: pulsing at the 6 that worked, the
    /// untested long/longest at 2.
    enum Style: String, CaseIterable, Identifiable {
        case standard, long, longest, pulsing

        var id: String { rawValue }

        var effects: [UInt8] {
            switch self {
            case .standard: return [47, 152]   // buzz 100%, 240 ms pause — the shipped, confirmed pair
            case .long:     return [15, 152]   // 750 ms alert
            case .longest:  return [16, 152]   // 1000 ms alert
            case .pulsing:  return [52, 152]   // pulsing strong
            }
        }

        /// The most repeats this style may play. Only the confirmed waveform gets the full range.
        var maxCount: Int {
            switch self {
            case .standard:      return StrapBuzzPrefs.countRange.upperBound
            case .pulsing:       return 6   // ×6 ended on its own on the wrist; ×8 did not
            case .long, .longest: return 2
            }
        }

        var label: String {
            switch self {
            case .standard: return String(localized: "Standard")
            case .long:     return String(localized: "Long (experimental)")
            case .longest:  return String(localized: "Longest (experimental)")
            case .pulsing:  return String(localized: "Pulsing (experimental)")
            }
        }
    }

    static var style: Style {
        get { UserDefaults.standard.string(forKey: styleKey).flatMap(Style.init(rawValue:)) ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: styleKey) }
    }

    /// The stored count, held to the current style's cap.
    static var count: Int {
        get {
            let v = UserDefaults.standard.object(forKey: countKey) as? Int ?? defaultCount
            return cappedLoops(v)
        }
        set { UserDefaults.standard.set(min(max(newValue, countRange.lowerBound), countRange.upperBound),
                                        forKey: countKey) }
    }

    /// Any buzz's repeat count held to 1...the current style's cap. Applied where every 5/MG buzz is
    /// built, so an in-session cue asking for more repeats can't run an experimental waveform long.
    static func cappedLoops(_ requested: Int) -> Int {
        min(max(requested, countRange.lowerBound), style.maxCount)
    }
}

/// One way for any notifier to buzz the strap with the notification it just posted (261122, fork):
/// "the app doesn't buzz the device for all notifications". The notifiers are static types with no
/// link to the strap, so `AppModel` installs the handler (its `buzzForNudgeIfEnabled`, which applies
/// the per-cue switch and needs a bonded link). Call it only after the notification actually posted.
enum NotificationBuzz {
    @MainActor static var handler: ((TargetAutomations.BuzzCue) -> Void)?

    static func posted(_ cue: TargetAutomations.BuzzCue) {
        Task { @MainActor in handler?(cue) }
    }
}
