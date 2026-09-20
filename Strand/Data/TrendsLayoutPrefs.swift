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

    // Per-metric trend blocks (260920). Each is a full `ScoreTrendSection` for ONE signal —
    // window selector, chart, comparison footer and calendar strip — the same component the Sleep
    // and Recap tabs already use, pointed at a different series.
    //
    // They exist so the maintainer can retire `smallMultiples`: that card renders five charts in
    // one body and stayed slow to scroll, while these are independently hideable, so the page costs
    // exactly the metrics actually wanted rather than all five at once. Charge already had its own
    // block (`recoveryHero`); this gives the other signals parity with it.
    //
    // NOT in `defaultOrder`: an existing layout and a fresh install both render exactly as before
    // until these are switched on in Arrange. Adding a case to `allCases` alone cannot change what
    // anyone already sees.
    case hrvTrend
    case restingHrTrend
    case dayQualityTrend
    case sleepTrend
    case effortTrend
    case waterTrend
    case respiratoryTrend

    /// The unified card (260920): every selected metric over the page's window, in one of three
    /// styles. The maintainer's ask was to be able to retire every other widget on this page in
    /// favour of it, so it is the one section that is SHOWN by default among the 260920 additions.
    case allMetrics

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
        case .hrvTrend:         return String(localized: "HRV trend")
        case .restingHrTrend:   return String(localized: "Resting HR trend")
        case .dayQualityTrend:  return String(localized: "Day quality trend")
        case .sleepTrend:       return String(localized: "Sleep trend")
        case .effortTrend:      return String(localized: "Effort trend")
        case .waterTrend:       return String(localized: "Water trend")
        case .respiratoryTrend: return String(localized: "Respiratory trend")
        case .allMetrics:       return String(localized: "All metrics")
        }
    }

    /// The original hard-coded order — the default when the layout is not customised, so an install
    /// that never opens Arrange sees exactly what it saw before this became arrangeable.
    static let defaultOrder: [TrendsSection] = [
        .insight, .weekInReview, .recoveryHero, .smallMultiples,
        .trainingLoad, .yearStrip, .exportReport,
    ]

    /// Every card, in a STABLE order — `defaultOrder` first, then the per-metric blocks.
    ///
    /// `decodeOrder` appends from here rather than from `defaultOrder`, because a card absent from
    /// `defaultOrder` would otherwise never be appended at all and would be unreachable in the
    /// Arrange sheet — invisible on the page AND impossible to switch on, which is exactly the
    /// stranding `TrendsLayoutPrefsTests` exists to catch. It caught it.
    ///
    /// NOT `allCases`: a CaseIterable's order is source order, which is stable today but is not a
    /// contract anyone maintains deliberately. Writing the sequence out means a reordered enum
    /// cannot silently shuffle a wearer's appended cards.
    static let canonicalOrder: [TrendsSection] = defaultOrder + [
        .allMetrics,
        .hrvTrend, .restingHrTrend, .dayQualityTrend,
        .sleepTrend, .effortTrend, .waterTrend, .respiratoryTrend,
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
        for s in TrendsSection.canonicalOrder where !seen.contains(s) { out.append(s) }
        return out
    }

    static func encodeHidden(_ sections: [TrendsSection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    static func decodeHidden(_ raw: String) -> Set<TrendsSection> {
        Set(raw.split(separator: ",").compactMap { TrendsSection(rawValue: String($0)) })
    }

    /// The cards to render, in order, minus the hidden set.
    /// Cards that are OFF until switched on (260920): the seven per-metric blocks.
    ///
    /// They must be reachable in the Arrange sheet — hence `canonicalOrder` — but must not appear
    /// on the page uninvited. Seven extra full trend sections arriving on upgrade would be the
    /// opposite of the ask, which was to REMOVE chart load from this page.
    static let defaultHidden: Set<TrendsSection> = [
        .hrvTrend, .restingHrTrend, .dayQualityTrend,
        .sleepTrend, .effortTrend, .waterTrend, .respiratoryTrend,
    ]

    /// The hidden set actually in force. THE single definition, used by both the page and the
    /// Arrange sheet — if the two computed this differently the sheet would list a card as "Shown"
    /// that the page was hiding, which reads as the setting being broken.
    ///
    /// An untouched install (empty `hiddenRaw`) gets `defaultHidden`. Once Arrange has been saved,
    /// the stored set is authoritative and the defaults stop applying, which is what lets a card be
    /// switched on and stay on.
    static func effectiveHidden(hiddenRaw: String) -> Set<TrendsSection> {
        hiddenRaw.isEmpty ? defaultHidden : decodeHidden(hiddenRaw)
    }

    static func visibleOrder(orderRaw: String, hiddenRaw: String) -> [TrendsSection] {
        let hidden = effectiveHidden(hiddenRaw: hiddenRaw)
        return decodeOrder(orderRaw).filter { !hidden.contains($0) }
    }
}
