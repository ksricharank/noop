import Foundation
import SwiftUI

// MARK: - Reorderable Day-quality sections (260908)
//
// The Day tab grew from four blocks to roughly ten: the score, its breakdown, the coach narrative, three
// Insights cards, the week summary, the trend chart, the calendar strip and the settings knobs. A fixed
// wall of that many cards means scrolling past the ones you do not care about every single time, so the
// tab gets the same treatment Sleep and Today already have — reorder and hide, with the default order
// being the sensible one so nothing changes for anyone who never opens the sheet.
//
// Display-only: no metric is computed or stored differently. This decides which already-built cards render
// and in what sequence, exactly as `SleepLayoutPrefs` does.
//
// Deliberately NOT mirrored on Android (yet). `day.sectionOrder` is absent from the `.noopbak` whitelist
// in `BackupSettings.swift`, so an Apple-only key cannot desync a backup/restore — the same reasoning that
// let `SleepSection.restTrend` ship Apple-first. When the Android Day tab is built, mirror this enum
// byte-identically and the saved layouts will read on either OS.
//
// The score card and the date navigator are NOT reorderable — they are the fixed frame of the tab, exactly
// as the Sleep-performance hero and the Today hero are pinned above their arrangeable sections. A tab
// whose subject can be hidden has no subject.

/// One reorderable Day-quality card. The rawValue is the stable persisted identifier — keep it
/// byte-identical to any future Android `DaySection` enum so a backup/restore reads the same layout.
enum DaySection: String, CaseIterable, Identifiable {
    /// The signed score, its two halves, and the per-component breakdown.
    case breakdown
    /// The coach's written read on the day.
    case narrative
    /// Which components moved the score, ranked over the window.
    case attribution
    /// "You were N steps from +M points" — the marginal value of each component, today.
    case counterfactual
    /// Days above zero, and the current run.
    case streaks
    /// The Monday-anchored week summary, browsable back through history.
    case weekSummary
    /// Window selector + the signed bar chart + the like-for-like comparison.
    case trend
    /// Every scored day as a calendar heat strip.
    case calendar
    /// The execution/recovery split, load-factor strength and overshoot ceiling.
    case settings

    var id: String { rawValue }

    /// The card's display label in the Arrange sheet.
    var title: String {
        switch self {
        case .breakdown:      return String(localized: "Score breakdown")
        case .narrative:      return String(localized: "Coach narrative")
        case .attribution:    return String(localized: "What moved the score")
        case .counterfactual: return String(localized: "Closest gains")
        case .streaks:        return String(localized: "Consistency")
        case .weekSummary:    return String(localized: "Week summary")
        case .trend:          return String(localized: "Trend")
        case .calendar:       return String(localized: "Calendar")
        case .settings:       return String(localized: "Scoring settings")
        }
    }

    /// The original, hard-coded card order — the default when the layout isn't customised.
    ///
    /// Reads as the day's story: what the score was, why, what the coach makes of it, what is actually
    /// moving it, what would move it next, then the longer horizons, and the knobs last (a setting is
    /// consulted rarely and belongs below the thing it tunes).
    static let defaultOrder: [DaySection] = [
        .breakdown, .narrative, .attribution, .counterfactual, .streaks,
        .weekSummary, .trend, .calendar, .settings,
    ]
}

/// Display-only persistence for the Day-quality card order and visibility. Direct twin of
/// `SleepLayoutPrefs` with a `day.` key namespace; see that file for the full rationale on why order and
/// visibility are stored separately.
enum DayLayoutPrefs {
    /// UserDefaults key — a comma-joined list of `DaySection` rawValues in display order.
    static let orderKey = "day.sectionOrder"
    /// UserDefaults key — a comma-joined list of explicitly hidden `DaySection` rawValues.
    static let hiddenKey = "day.hiddenSections"

    /// Encode an ordered card list into the stored comma-joined string.
    static func encode(_ sections: [DaySection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    /// Encode the explicit hidden set in stable list order.
    static func encodeHidden(_ sections: [DaySection]) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    /// Decode the stored string into the FULL ordered card list. An empty/unset string yields the default
    /// order. Unknown tokens are ignored, duplicates collapsed, and any known card missing from the saved
    /// order is INSERTED at its default-order position relative to the saved cards — so every card always
    /// renders, and one added in a later app version surfaces where users expect it instead of teleporting
    /// to the bottom of an existing saved order.
    static func decodeOrder(_ raw: String) -> [DaySection] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return DaySection.defaultOrder }
        var saved: [DaySection] = []
        for token in trimmed.split(separator: ",") {
            if let s = DaySection(rawValue: token.trimmingCharacters(in: .whitespaces)), !saved.contains(s) {
                saved.append(s)
            }
        }
        guard !saved.isEmpty else { return DaySection.defaultOrder }
        // Iterate allCases (not defaultOrder) so a future case accidentally left out of defaultOrder can
        // never be silently hidden; a card without a default index sorts after everything. defaultOrder
        // covering allCases is pinned by DayLayoutPrefsTests.
        func defIdx(_ s: DaySection) -> Int {
            DaySection.defaultOrder.firstIndex(of: s) ?? DaySection.defaultOrder.count
        }
        for missing in DaySection.allCases where !saved.contains(missing) {
            let insertAt = saved.firstIndex { defIdx($0) > defIdx(missing) }
            if let insertAt { saved.insert(missing, at: insertAt) } else { saved.append(missing) }
        }
        return saved
    }

    /// Decode explicitly hidden cards. Empty/unset means nothing is hidden. Unknown tokens are ignored and
    /// duplicates collapsed; unlike `decodeOrder`, missing cases are NOT inserted because absence here
    /// means visible (including a card introduced by a future app version).
    static func decodeHidden(_ raw: String) -> [DaySection] {
        var seen = Set<DaySection>()
        var hidden: [DaySection] = []
        for token in raw.split(separator: ",") {
            if let section = DaySection(rawValue: token.trimmingCharacters(in: .whitespaces)),
               seen.insert(section).inserted {
                hidden.append(section)
            }
        }
        return hidden
    }

    /// The cards the Day tab should render, preserving the full saved order while filtering only the
    /// user's explicit hidden set. At least one visible card is enforced by the editor, not the decoder.
    static func visibleOrder(orderRaw: String, hiddenRaw: String) -> [DaySection] {
        let hidden = Set(decodeHidden(hiddenRaw))
        return decodeOrder(orderRaw).filter { !hidden.contains($0) }
    }
}
