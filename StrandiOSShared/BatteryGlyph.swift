import Foundation

/// The level-banded strap-battery glyph, in ONE place.
///
/// The Targets widget drew a hardcoded `battery.50` beside a live percentage, so a full strap and a
/// nearly flat one wore the same half-full icon — the number moved on every sync and the glyph never
/// did, which reads as a broken widget rather than as a design choice.
///
/// SIX steps (maintainer's request, 260919): 0 · 20 · 40 · 60 · 80 · 100. SF Symbols only ships five
/// battery fills, so the sixth step is drawn by `bars`, which the widget renders as its own pips —
/// the symbol name below is the closest fill for anywhere a glyph is wanted instead.
///
/// `TodayView` renders the same battery and shares this file, so the two surfaces cannot disagree
/// about what 40% looks like; a test pins the bands and resolves every name against the system.
public enum BatteryGlyph {

    /// How many of six pips are lit at this charge: 0%→0, 100%→6. Each step is one sixth, so the
    /// boundaries fall at 0 / 16.7 / 33.3 / 50 / 66.7 / 83.3, and only a genuinely empty reading
    /// lights nothing. Clamped, so a strap reporting nonsense still draws something.
    public static let barCount = 6

    public static func bars(forPercent pct: Int?) -> Int {
        guard let pct else { return 0 }
        if pct <= 0 { return 0 }
        if pct >= 100 { return barCount }
        // Ceiling division over the range BELOW full, so any charge at all lights the first pip and
        // the last pip is reserved for a genuinely full strap: with a plain ceiling, 99% lit all six
        // and a nearly-full strap was indistinguishable from a charged one.
        let step = 100.0 / Double(barCount)
        return max(1, min(barCount - 1, Int((Double(pct) / step).rounded(.up))))
    }

    /// SF Symbol for a strap charge percentage, or the no-reading glyph when it is unknown.
    ///
    /// `nil` is NOT rendered as an empty battery: "no reading" and "flat" are different states, and
    /// showing a flat battery for a strap that simply has not reported would be the diagnostic lying.
    ///
    /// `batteryblock.slash` rather than `battery.slash`, which does NOT exist: an unknown SF Symbol
    /// renders as nothing at all and compiles clean, so the first attempt silently dropped the icon
    /// from the header. Every name here is covered by a test that resolves it against the system,
    /// because that failure is invisible in review.
    public static func symbol(forPercent pct: Int?, charging: Bool = false) -> String {
        if charging { return "battery.100.bolt" }
        guard let pct else { return "batteryblock.slash" }
        switch pct {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }
}
