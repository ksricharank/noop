import Foundation
import SwiftUI
import StrandDesign

// MARK: - The unified Trends widget's preferences (260920)
//
// The maintainer, after installing the per-metric blocks of 18.9: "for the trends page, I don't
// like any of the widgets honestly - I just want a single new widget that shows trends over a range
// selected in the window selector that shows all the key metrics (this should be separately
// configurable) in one widget".
//
// So: ONE card, the page's own window selector, a configurable metric set, and a choice of how to
// draw them. Three styles ship rather than one because the maintainer asked to decide in the
// selector rather than up front — and because each genuinely answers a different question.

/// A signal the unified card can draw.
enum MultiMetric: String, CaseIterable, Identifiable {
    case charge
    case hrv
    case restingHr
    case effort
    case sleep
    case dayQuality
    case steps
    case respiratory
    case water

    var id: String { rawValue }

    var title: String {
        switch self {
        case .charge:      return String(localized: "Charge")
        case .hrv:         return "HRV"
        case .restingHr:   return String(localized: "Resting HR")
        case .effort:      return String(localized: "Effort")
        case .sleep:       return String(localized: "Sleep")
        case .dayQuality:  return String(localized: "Day quality")
        case .steps:       return String(localized: "Steps")
        case .respiratory: return String(localized: "Respiratory")
        case .water:       return String(localized: "Water")
        }
    }

    /// The unit shown beside a value. Empty where the number carries no unit.
    var unit: String {
        switch self {
        case .charge:      return "%"
        case .hrv:         return "ms"
        case .restingHr:   return "bpm"
        case .effort:      return ""
        case .sleep:       return "%"
        case .dayQuality:  return ""
        case .steps:       return ""
        case .respiratory: return "rpm"
        case .water:       return String(localized: "cups")
        }
    }

    /// Each metric keeps the colour it already carries elsewhere in the app, so a line in this card
    /// and the same metric's own block read as one thing.
    var color: Color {
        switch self {
        case .charge:      return StrandPalette.chargeColor
        case .hrv:         return StrandPalette.metricCyan
        case .restingHr:   return StrandPalette.metricRose
        case .effort:      return StrandPalette.effortColor
        case .sleep:       return StrandPalette.restLine
        case .dayQuality:  return StrandPalette.statusPositive
        case .steps:       return StrandPalette.metricAmber
        case .respiratory: return StrandPalette.accent
        case .water:       return StrandPalette.metricCyan
        }
    }

    /// Whether HIGHER is better. Drives the heatmap's colour direction — a resting-HR day above
    /// baseline is a worse day, and shading it the same green as a high-HRV day would invert the
    /// only thing that view is for.
    var higherIsBetter: Bool {
        switch self {
        case .restingHr, .respiratory: return false
        default: return true
        }
    }

    /// Kept for callers that want "a sensible set" without naming a style; the per-style defaults
    /// live on `MultiMetricPrefs.defaultSelection(for:)`.
    static let defaultSelection: [MultiMetric] = [.charge, .hrv, .restingHr, .sleep, .effort]
}

/// How the unified card draws its metrics.
enum MultiMetricStyle: String, CaseIterable, Identifiable {
    /// Every metric on one set of axes, each scaled 0–100% against its own observed range.
    case overlay
    /// One short strip per metric, stacked, sharing the x-axis and keeping real values.
    case rows
    /// Metrics as rows, days as columns, each cell shaded by deviation from baseline.
    case heatmap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overlay: return String(localized: "Overlay")
        case .rows:    return String(localized: "Rows")
        case .heatmap: return String(localized: "Heatmap")
        }
    }

    /// What the style is FOR, in one line — shown under the picker, because "overlay vs rows" says
    /// nothing about which question each answers.
    var blurb: String {
        switch self {
        case .overlay:
            return String(localized: "Every metric on one axis, each scaled to its own range. Best for spotting that two signals moved together.")
        case .rows:
            return String(localized: "One strip per metric with its real values, days lined up. Best for reading actual numbers while still comparing days.")
        case .heatmap:
            return String(localized: "A grid of days, shaded by how far each sits from your baseline. Best for finding the days where everything was off.")
        }
    }
}

/// Persistence for the unified card. Same encode/decode shape as the layout prefs — a comma-joined
/// list of rawValues, unknown tokens dropped, so a build that adds a metric cannot strand a stored
/// selection written before it existed.
enum MultiMetricPrefs {
    /// PER-STYLE selections (260920, maintainer: "for each of the three visualizations, I want the
    /// option to independently pick the key metrics").
    ///
    /// The three styles genuinely want different sets. An overlay is readable with four or five
    /// signals and becomes a thicket past that; a heatmap is fine with every metric at once, since
    /// each gets its own row; rows sit in between, bounded by height rather than legibility. One
    /// shared selection would force the smallest of those limits on all three.
    ///
    /// Keyed by style rawValue, so adding a style cannot collide with an existing stored set.
    static func selectionKey(for style: MultiMetricStyle) -> String {
        "trends.multiMetricSelection.\(style.rawValue)"
    }

    /// The pre-260920 single-selection key. Still READ as the seed for a style that has never been
    /// configured, so a wearer who had already picked a set does not find it reset by this change.
    static let legacySelectionKey = "trends.multiMetricSelection"
    static let styleKey = "trends.multiMetricStyle"

    /// The default set for a style, chosen for what that style can carry legibly.
    static func defaultSelection(for style: MultiMetricStyle) -> [MultiMetric] {
        switch style {
        case .overlay:
            // Five lines on one axis is about the ceiling before colours stop being separable.
            return [.charge, .hrv, .restingHr, .sleep, .effort]
        case .rows:
            // Each row owns its own scale and ~38pt, so a couple more is still readable.
            return [.charge, .hrv, .restingHr, .sleep, .effort, .steps]
        case .heatmap:
            // A row per metric costs 16pt and no legibility, so this one starts with everything.
            return MultiMetric.allCases
        }
    }

    static func encode(_ metrics: [MultiMetric]) -> String {
        metrics.map(\.rawValue).joined(separator: ",")
    }

    /// An empty/unset string yields the style's default; an explicitly EMPTY selection is not
    /// expressible, deliberately — a card drawing nothing would read as broken rather than as
    /// configured, and hiding the card is what the Arrange sheet is for.
    static func decode(_ raw: String, style: MultiMetricStyle = .overlay) -> [MultiMetric] {
        let parsed = raw.split(separator: ",").compactMap { MultiMetric(rawValue: String($0)) }
        var seen = Set<MultiMetric>()
        let deduped = parsed.filter { seen.insert($0).inserted }
        return deduped.isEmpty ? defaultSelection(for: style) : deduped
    }

    /// The selection in force for a style, resolving the three sources in order: that style's own
    /// stored set, then the pre-per-style key (so an existing choice carries over once), then the
    /// style's default.
    static func resolved(style: MultiMetricStyle,
                         defaults: UserDefaults = .standard) -> [MultiMetric] {
        if let own = defaults.string(forKey: selectionKey(for: style)), !own.isEmpty {
            return decode(own, style: style)
        }
        if let legacy = defaults.string(forKey: legacySelectionKey), !legacy.isEmpty {
            return decode(legacy, style: style)
        }
        return defaultSelection(for: style)
    }

    static func decodeStyle(_ raw: String) -> MultiMetricStyle {
        MultiMetricStyle(rawValue: raw) ?? .overlay
    }
}
