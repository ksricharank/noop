import SwiftUI
import StrandDesign

// MARK: - Trends card customization (260919)

/// The Trends tab's "Arrange" sheet — reorder / show-hide the analytical cards. A twin of
/// `DayCustomizationSheet` and `SleepCustomizationSheet`, driven by the SAME generic
/// `EditableLayoutList` so the reorder/hide UX is byte-for-byte identical across all four tabs.
///
/// The range bar is deliberately NOT in the list: it is the tab's control surface, pinned above the
/// cards, and a page whose window selector could be hidden would have no way to choose a window.
struct TrendsCustomizationSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let initialDraft: EditableLayoutDraft<TrendsSection>

    @Binding private var sectionOrderRaw: String
    @Binding private var hiddenSectionsRaw: String

    @State private var draft: EditableLayoutDraft<TrendsSection>

    private var isDirty: Bool { draft != initialDraft }

    init(sectionOrderRaw: Binding<String>, hiddenSectionsRaw: Binding<String>) {
        _sectionOrderRaw = sectionOrderRaw
        _hiddenSectionsRaw = hiddenSectionsRaw

        let fullOrder = TrendsLayoutPrefs.decodeOrder(sectionOrderRaw.wrappedValue)
        // `effectiveHidden`, not `decodeHidden`: on an untouched install the per-metric blocks are
        // hidden by default, and seeding this list from the raw stored set would show them here as
        // "Shown" while the page was hiding them.
        let hiddenSet = TrendsLayoutPrefs.effectiveHidden(hiddenRaw: hiddenSectionsRaw.wrappedValue)
        let d = EditableLayoutDraft(
            visible: fullOrder.filter { !hiddenSet.contains($0) },
            hidden: fullOrder.filter { hiddenSet.contains($0) }
        )
        initialDraft = d
        _draft = State(initialValue: d)
    }

    var body: some View {
        NavigationStack {
            EditableLayoutList(
                draft: $draft,
                shownTitle: String(localized: "Shown"),
                hiddenTitle: String(localized: "Hidden"),
                title: \.title,
                subtitle: \.customizationSubtitle,
                icon: \.customizationIcon,
                tint: \.customizationTint,
                configurationLabel: { _ in nil },
                onConfigure: { _ in },
                onReset: {
                    draft = EditableLayoutDraft(
                        visible: TrendsSection.defaultOrder,
                        allItems: TrendsSection.defaultOrder
                    )
                }
            ) {
                EmptyView()
            }
            .navigationTitle("Customize Trends")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .interactiveDismissDisabled(isDirty)
        .tint(StrandPalette.accent)
        #if os(macOS)
        .frame(
            minWidth: NoopMetrics.editorSheetMinWidth,
            minHeight: NoopMetrics.editorSheetMinHeight
        )
        #endif
    }

    private func save() {
        // The FULL order (shown ++ hidden, so a hidden card keeps a stable slot) plus the hidden set.
        sectionOrderRaw = TrendsLayoutPrefs.encode(draft.visible + draft.hidden)
        hiddenSectionsRaw = TrendsLayoutPrefs.encodeHidden(draft.hidden)
        dismiss()
    }
}

// MARK: - Per-card Arrange-sheet metadata (icon + tint), mirroring DaySection's

extension TrendsSection {
    var customizationIcon: String {
        switch self {
        case .insight:        return "sparkles"
        case .weekInReview:   return "square.grid.2x2"
        case .recoveryHero:   return "chart.line.uptrend.xyaxis"
        case .smallMultiples: return "chart.bar"
        case .trainingLoad:   return "figure.run"
        case .yearStrip:      return "calendar.badge.clock"
        case .exportReport:   return "doc.richtext"
        // Per-metric blocks (260920) — each takes the icon its own metric uses elsewhere in the app.
        case .hrvTrend:         return "waveform.path.ecg"
        case .restingHrTrend:   return "heart"
        case .dayQualityTrend:  return "medal"
        case .sleepTrend:       return "bed.double"
        case .effortTrend:      return "flame"
        case .waterTrend:       return "drop"
        case .respiratoryTrend: return "lungs"
        case .allMetrics:       return "chart.xyaxis.line"
        }
    }

    var customizationSubtitle: String {
        switch self {
        case .insight:        return String(localized: "What the coach makes of the window")
        case .weekInReview:   return String(localized: "Charge, Effort and Rest for the week")
        case .recoveryHero:   return String(localized: "Charge over the selected range")
        case .smallMultiples: return String(localized: "HRV, resting HR, effort, rest and day quality")
        case .trainingLoad:   return String(localized: "Chronic and acute load over the full history")
        case .yearStrip:      return String(localized: "Every scored day of the year")
        case .exportReport:   return String(localized: "A shareable one-page PDF")
        // Each names its own window selector, since that is the thing these have and the shared
        // small-multiples grid does not.
        case .hrvTrend:         return String(localized: "HRV alone, with its own window")
        case .restingHrTrend:   return String(localized: "Resting heart rate alone, with its own window")
        case .dayQualityTrend:  return String(localized: "Day quality alone, with its own window")
        case .sleepTrend:       return String(localized: "Sleep score alone, with its own window")
        case .effortTrend:      return String(localized: "Effort alone, with its own window")
        case .waterTrend:       return String(localized: "Water in cups, with its own window")
        case .respiratoryTrend: return String(localized: "Respiratory rate alone, with its own window")
        case .allMetrics:       return String(localized: "Every metric you choose, over the page's window")
        }
    }

    var customizationTint: Color {
        switch self {
        case .insight:        return StrandPalette.accent
        case .weekInReview:   return StrandPalette.chargeColor
        case .recoveryHero:   return StrandPalette.chargeColor
        case .smallMultiples: return StrandPalette.restColor
        case .trainingLoad:   return StrandPalette.effortColor
        case .yearStrip:      return StrandPalette.restBright
        case .exportReport:   return StrandPalette.accent
        case .hrvTrend:         return StrandPalette.metricCyan
        case .restingHrTrend:   return StrandPalette.metricRose
        case .dayQualityTrend:  return StrandPalette.statusPositive
        case .sleepTrend:       return StrandPalette.restColor
        case .effortTrend:      return StrandPalette.effortColor
        case .waterTrend:       return StrandPalette.metricCyan
        case .respiratoryTrend: return StrandPalette.restBright
        case .allMetrics:       return StrandPalette.accent
        }
    }
}
