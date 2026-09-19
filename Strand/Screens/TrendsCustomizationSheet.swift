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
        let hiddenSet = TrendsLayoutPrefs.decodeHidden(hiddenSectionsRaw.wrappedValue)
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
        }
    }
}
