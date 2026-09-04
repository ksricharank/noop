import Foundation
import StrandAnalytics

/// The wearer-tunable half of the day-quality score: UserDefaults in, a `DayQualityScore.Config`
/// out.
///
/// Kept separate from the scorer itself, which is pure and lives in `StrandAnalytics` so it can be
/// tested with no app and no defaults. This is the one place that knows the storage keys, so the
/// Trends config panel and the nightly computation can never disagree about what the wearer chose.
///
/// Every getter falls back to the scorer's own default rather than a literal repeated here — the
/// defaults live in exactly one place (`DayQualityScore.Config.default`), so changing one changes
/// both the fresh-install behaviour and the "Reset" button.
enum DayQualityPrefs {

    enum K {
        /// Execution's share of the score, stored 0…100 (an Int percentage is what a slider binds to
        /// cleanly; the scorer wants 0…1).
        static let executionSharePct = "dayquality.executionSharePct"
        /// Load-factor strength, stored 0…100.
        static let loadFactorPct = "dayquality.loadFactorPct"
        /// Overshoot ceiling, stored as a whole percentage of target (125 = 1.25).
        static let overshootCapPct = "dayquality.overshootCapPct"
        /// The local day on which the nightly scoring pass last ran to completion.
        static let lastScoredDay = "dayquality.lastScoredDay"
        /// The config fingerprint that pass used, so changing a knob re-scores rather than waiting
        /// for tomorrow (the wearer expects a slider to move the history it applies to).
        static let lastScoredConfig = "dayquality.lastScoredConfig"
    }

    private static var d: UserDefaults { .standard }

    /// Defaults are read from the scorer, not duplicated. `object(forKey:)` rather than
    /// `integer(forKey:)` because an absent key must mean "use the default", and `integer` cannot
    /// tell absent from a deliberate zero — a distinction that matters for both of these, where 0 is
    /// a legitimate choice (all-recovery scoring, load factor off).
    static var executionSharePct: Int {
        d.object(forKey: K.executionSharePct) as? Int
            ?? Int((DayQualityScore.Config.default.executionShare * 100).rounded())
    }

    static var loadFactorPct: Int {
        d.object(forKey: K.loadFactorPct) as? Int
            ?? Int((DayQualityScore.Config.default.loadFactorStrength * 100).rounded())
    }

    static var overshootCapPct: Int {
        d.object(forKey: K.overshootCapPct) as? Int
            ?? Int((DayQualityScore.Config.default.overshootCap * 100).rounded())
    }

    static func setExecutionSharePct(_ v: Int) { d.set(min(max(v, 0), 100), forKey: K.executionSharePct) }
    static func setLoadFactorPct(_ v: Int) { d.set(min(max(v, 0), 100), forKey: K.loadFactorPct) }
    /// 100 = hard cap at target; 200 = double credit. The scorer clamps to the same range, so a
    /// value written here can never express "meeting the target is worth less than full marks".
    static func setOvershootCapPct(_ v: Int) { d.set(min(max(v, 100), 200), forKey: K.overshootCapPct) }

    /// Drop every override, returning to the shipped defaults.
    static func reset() {
        [K.executionSharePct, K.loadFactorPct, K.overshootCapPct].forEach { d.removeObject(forKey: $0) }
    }

    /// True when the wearer has changed anything — lets the UI show "Reset" only when it would do
    /// something.
    static var isCustomised: Bool {
        [K.executionSharePct, K.loadFactorPct, K.overshootCapPct].contains { d.object(forKey: $0) != nil }
    }

    // MARK: - Once-per-day latch
    //
    // Maintainer requirement (260904): the score is computed ONCE, after the night's sleep is
    // scored and the new targets are set — not continuously. Without a latch the engine's derived
    // block runs it on every full pass, which is several times a day: wasted work on a
    // battery-sensitive path, and a score that could visibly change during the day when the whole
    // point is that it is a closed book.
    //
    // The latch is keyed on the day AND a fingerprint of the config, so the one legitimate reason
    // to re-score early — the wearer moved a slider — still applies to history immediately.

    /// A short, stable fingerprint of the settings that affect the number.
    static var configFingerprint: String {
        "\(executionSharePct)/\(loadFactorPct)/\(overshootCapPct)"
    }

    /// True when tonight's scoring has already run for `day` under the current settings.
    static func alreadyScored(day: String) -> Bool {
        d.string(forKey: K.lastScoredDay) == day
            && d.string(forKey: K.lastScoredConfig) == configFingerprint
    }

    static func markScored(day: String) {
        d.set(day, forKey: K.lastScoredDay)
        d.set(configFingerprint, forKey: K.lastScoredConfig)
    }

    /// The config the nightly computation actually uses. Component weights stay at their defaults:
    /// the two knobs the maintainer asked for are the halves' split and the load factor (plus the
    /// overshoot ceiling), and exposing seven more sliders would make the number harder to reason
    /// about, not easier to tune.
    static var config: DayQualityScore.Config {
        var c = DayQualityScore.Config.default
        c.executionShare = Double(executionSharePct) / 100
        c.loadFactorStrength = Double(loadFactorPct) / 100
        c.overshootCap = Double(overshootCapPct) / 100
        return c
    }
}
