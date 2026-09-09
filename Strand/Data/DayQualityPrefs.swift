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
        /// Overshoot ceiling, stored as a whole percentage of the normal→target distance
        /// (170 = 1.7). Namespaced `v3` deliberately: build 332 stored 125 here under the old
        /// meaning, and a stale 125 silently caps the scale's ceiling at 77 instead of 100. A stored
        /// preference that changes meaning needs a new key, not a migration guess — the old value was
        /// a valid answer to a different question.
        static let overshootCapPct = "dayquality.v3.overshootCapPct"
        /// The absolute "normal day" the score's zero sits on, one key per component, in the
        /// component's own units. Absent means "use the shipped default".
        static let normalSteps = "dayquality.normal.steps"
        static let normalKcal = "dayquality.normal.kcal"
        static let normalEffort = "dayquality.normal.effort"
        static let normalWaterCups = "dayquality.normal.waterCups"
        static let normalSleepMin = "dayquality.normal.sleepMin"
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

    // MARK: - The normal-day anchor (260909)
    //
    // Read as Ints because that is what a stepper binds to cleanly, and clamped on READ so a corrupt
    // or hand-edited preference cannot produce a nonsense zero point. Each falls back to the shipped
    // default rather than to a literal, so the two cannot drift.

    static var normalSteps: Int {
        clamp(d.object(forKey: K.normalSteps) as? Int
              ?? Int(DayQualityScore.NormalDay.default.steps), 0, 20_000)
    }
    static var normalKcal: Int {
        clamp(d.object(forKey: K.normalKcal) as? Int
              ?? Int(DayQualityScore.NormalDay.default.kcal), 0, 6000)
    }
    static var normalEffort: Int {
        clamp(d.object(forKey: K.normalEffort) as? Int
              ?? Int(DayQualityScore.NormalDay.default.effort), 0, 100)
    }
    static var normalWaterCups: Int {
        clamp(d.object(forKey: K.normalWaterCups) as? Int
              ?? Int(DayQualityScore.NormalDay.default.waterCups), 0, 40)
    }
    /// Stored in MINUTES; the UI presents hours.
    static var normalSleepMin: Int {
        clamp(d.object(forKey: K.normalSleepMin) as? Int
              ?? Int(DayQualityScore.NormalDay.default.sleepMin), 0, 900)
    }

    static func setNormalSteps(_ v: Int) { d.set(clamp(v, 0, 20_000), forKey: K.normalSteps) }
    static func setNormalKcal(_ v: Int) { d.set(clamp(v, 0, 6000), forKey: K.normalKcal) }
    static func setNormalEffort(_ v: Int) { d.set(clamp(v, 0, 100), forKey: K.normalEffort) }
    static func setNormalWaterCups(_ v: Int) { d.set(clamp(v, 0, 40), forKey: K.normalWaterCups) }
    static func setNormalSleepMin(_ v: Int) { d.set(clamp(v, 0, 900), forKey: K.normalSleepMin) }

    /// True when the normal-day anchor differs from the shipped default.
    static var normalDayIsCustomised: Bool {
        normalDay != .default
    }

    /// Restore the shipped anchor.
    static func resetNormalDay() {
        for key in [K.normalSteps, K.normalKcal, K.normalEffort, K.normalWaterCups, K.normalSleepMin] {
            d.removeObject(forKey: key)
        }
    }

    /// The anchor as the scorer wants it.
    static var normalDay: DayQualityScore.NormalDay {
        DayQualityScore.NormalDay(steps: Double(normalSteps), kcal: Double(normalKcal),
                                  effort: Double(normalEffort), waterCups: Double(normalWaterCups),
                                  sleepMin: Double(normalSleepMin))
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }

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

    /// The scoring SCALE's version, bumped whenever the published number means something different
    /// for identical inputs.
    ///
    /// 260908: `v2` was the first signed scale (derived origin, spread across components); `v3` is the
    /// absolute-anchor scale that replaced it after the field cards showed the offset dominating the
    /// achievement. Both required re-deriving every stored day. This rides in the fingerprint so the existing
    /// "the formula changed, so re-score history" path re-derives every stored day on first launch —
    /// exactly the mechanism a moved slider already uses, and the reason no bespoke migration is
    /// needed. Without it the series would mix scales: 47 days of 0–100 values under the same metric
    /// key as the new signed ones, which would corrupt the chart, the week-in-review comparison and
    /// the calendar strip while looking like real data.
    ///
    /// Bump this — never reuse a version — when a scale change lands. Re-deriving is safe because a
    /// finished day's INPUTS are immutable: the recomputation reads the same stored rows and simply
    /// applies the current formula, so it is idempotent and a rollback re-derives back.
    static let scaleVersion = "v3"

    /// A short, stable fingerprint of the settings that affect the number, plus the scale they are
    /// expressed on.
    static var configFingerprint: String {
        // The normal-day anchor is PART of the formula, so it belongs here: without it, tuning the
        // zero point would change every future score while leaving history on the old anchor, and the
        // trend would mix two definitions of zero with nothing on screen to say so. Omitting an input
        // from this string is exactly how the 260908 migration silently failed.
        "\(scaleVersion)/\(executionSharePct)/\(loadFactorPct)/\(overshootCapPct)"
            + "/\(normalSteps),\(normalKcal),\(normalEffort),\(normalWaterCups),\(normalSleepMin)"
    }

    /// True when tonight's scoring has already run for `day` under the current settings.
    static func alreadyScored(day: String) -> Bool {
        d.string(forKey: K.lastScoredDay) == day && !configChanged
    }

    /// True when the settings differ from those the last scoring pass used.
    ///
    /// This is the ONLY thing that justifies re-scoring history: a finished day's inputs are fixed,
    /// so its score can only change because the formula's weighting did. The nightly pass is
    /// otherwise incremental — one new day per day (see `DayQualityComputer.daysToScore`).
    static var configChanged: Bool {
        // An absent fingerprint means no pass has ever recorded one: treat that as "changed" so a
        // first run backfills rather than assuming the stored series is complete.
        d.string(forKey: K.lastScoredConfig) != configFingerprint
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
        // Was MISSING (260909): the scoring pass built its config here and never applied the anchor,
        // so a tuned normal day moved the card (which reads the anchor directly) and not the stored
        // series. Every input the scorer takes has to come through this one builder, or the two
        // surfaces compute different numbers from the same day.
        c.normalDay = normalDay
        return c
    }
}
