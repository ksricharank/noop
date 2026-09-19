import Foundation

/// The level-banded strap-battery glyph, in ONE place.
///
/// The widgets drew a hardcoded `battery.50` beside a live percentage, so a full strap and a nearly
/// flat one wore the same half-full icon — the number moved and the glyph never did, which reads as
/// a broken widget rather than as a design choice. `TodayView` already had the banding; it just was
/// not reachable from the widget extension, which shares `StrandiOSShared` and not `Strand`.
///
/// Bands match `TodayView.symbol(_:)` exactly, and a test pins them to each other: two surfaces
/// disagreeing about what 40% looks like is precisely the class of drift this file exists to stop.
public enum BatteryGlyph {

    /// SF Symbol for a strap charge percentage, or the no-reading glyph when it is unknown.
    ///
    /// `nil` is NOT rendered as an empty battery: "no reading" and "flat" are different states, and
    /// showing a flat battery for a strap that simply has not reported would be the diagnostic lying.
    ///
    /// `batteryblock.slash` rather than `battery.slash`, which does NOT exist: an unknown SF Symbol
    /// renders as nothing at all and compiles clean, so the first attempt silently dropped the icon
    /// from the footer whenever the strap had not reported. Every name here is covered by a test that
    /// resolves it against the system, because that failure is invisible in review.
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
