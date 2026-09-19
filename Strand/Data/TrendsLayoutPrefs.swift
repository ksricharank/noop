import Foundation

// The Trends tab's cards became arrangeable at 260919, at the maintainer's request that every tab's
// LLM summary be moveable ("make it customizable like the other sections in the liquid UI so that I
// can move it around as needed... Same for all the other tabs too"). Today, Recap and Sleep already
// had this; Trends was the one page whose order was hard-coded.
//
// The range bar is NOT a section: it is the tab's control surface, pinned above the cards exactly as
// Sleep pins its hero and Recap pins its date navigator. A page whose window selector could be
// hidden would have no way to choose a window.

/// One reorderable Trends card. The rawValue is the stable persisted identifier.
enum TrendsSection: String, CaseIterable, Identifiable {
    /// The tab's LLM read of the selected window.
    case insight
    /// The Charge / Effort / Rest trio in pip language.
    case weekInReview
    /// The big recovery-over-time chart.
    case recoveryHero
    /// HRV, resting HR, strain, day quality and rest, as small multiples.
    case smallMultiples
    /// Long-horizon training load (CTL/ATL/TSB).
    case trainingLoad
    /// Every day of the year as a strip.
    case yearStrip
    /// The one-page PDF export row.
    case exportReport

    var id: String { rawValue }

    /// The card's display label in the Arrange sheet.
    var title: String {
        switch self {
        case .insight:        return String(localized: "What the trend says")
        case .weekInReview:   return String(localized: "Week in review")
        case .recoveryHero:   return String(localized: "Charge over time")
        case .smallMultiples: return String(localized: "Metric trends")
        case .trainingLoad:   return String(localized: "Training load")
        case .yearStrip:      return String(localized: "Year strip")
        case .exportReport:   return String(localized: "Export report")
        }
    }

    /// The original hard-coded order — the default when the layout is not customised, so an install
    /// that never opens Arrange sees exactly what it saw before this became arrangeable.
    static let defaultOrder: [TrendsSection] = [
        .insight, .weekInReview, .recoveryHero, .smallMultiples,
        .trainingLoad, .yearStrip, .exportReport,
    ]
}

/// Display-only persistence for the Trends card order and visibility. A direct twin of
/// `SleepLayoutPrefs` and `DayLayoutPrefs` with a `trends.` key namespace — same encode/decode rules,
/// same "unknown rawValues are dropped, missing ones are appended" recovery, so a build that adds a
/// card does not strand a stored layout written before it existed.
enum TrendsLayoutPrefs {
    static let orderKey = "trends.sectionOrder"
    static let hiddenKey = "trends.hiddenSections"

    static func encode(_ sections: [TrendsSection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    /// Decode a stored order, tolerating both drift directions: a rawValue this build does not know
    /// is dropped, and any known card the string omits is appended in its default position. The
    /// result therefore always contains every card exactly once.
    static func decodeOrder(_ raw: String) -> [TrendsSection] {
        let stored = raw.split(separator: ",").compactMap { TrendsSection(rawValue: String($0)) }
        var seen = Set<TrendsSection>()
        var out: [TrendsSection] = []
        for s in stored where !seen.contains(s) { out.append(s); seen.insert(s) }
        for s in TrendsSection.defaultOrder where !seen.contains(s) { out.append(s) }
        return out
    }

    static func encodeHidden(_ sections: [TrendsSection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    static func decodeHidden(_ raw: String) -> Set<TrendsSection> {
        Set(raw.split(separator: ",").compactMap { TrendsSection(rawValue: String($0)) })
    }

    /// The cards to render, in order, minus the hidden set.
    static func visibleOrder(orderRaw: String, hiddenRaw: String) -> [TrendsSection] {
        let hidden = decodeHidden(hiddenRaw)
        return decodeOrder(orderRaw).filter { !hidden.contains($0) }
    }
}
