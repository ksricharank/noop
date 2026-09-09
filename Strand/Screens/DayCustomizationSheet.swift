import SwiftUI
import StrandDesign

// MARK: - Day-quality card customization (260908)

/// The Day tab's "Arrange" sheet — reorder / show-hide the analytical cards. A single-page twin of
/// `SleepCustomizationSheet`, driven by the SAME generic `EditableLayoutList` so the reorder/hide UX is
/// byte-for-byte Today's and Sleep's. Persists via `DayLayoutPrefs`; the render side (`DayQualityView`)
/// reads the same `@AppStorage` keys and re-lays-out on save.
struct DayCustomizationSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let initialDraft: EditableLayoutDraft<DaySection>

    @Binding private var sectionOrderRaw: String
    @Binding private var hiddenSectionsRaw: String

    @State private var draft: EditableLayoutDraft<DaySection>

    private var isDirty: Bool { draft != initialDraft }

    init(sectionOrderRaw: Binding<String>, hiddenSectionsRaw: Binding<String>) {
        _sectionOrderRaw = sectionOrderRaw
        _hiddenSectionsRaw = hiddenSectionsRaw

        let fullOrder = DayLayoutPrefs.decodeOrder(sectionOrderRaw.wrappedValue)
        let hiddenSet = Set(DayLayoutPrefs.decodeHidden(hiddenSectionsRaw.wrappedValue))
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
                        visible: DaySection.defaultOrder,
                        allItems: DaySection.defaultOrder
                    )
                }
            ) {
                EmptyView()
            }
            .navigationTitle("Customize Day")
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
        // Store the FULL order (shown ++ hidden, so a hidden card keeps a stable slot) + the hidden set,
        // matching DayLayoutPrefs.
        sectionOrderRaw = DayLayoutPrefs.encode(draft.visible + draft.hidden)
        hiddenSectionsRaw = DayLayoutPrefs.encodeHidden(draft.hidden)
        dismiss()
    }
}

// MARK: - Per-card Arrange-sheet metadata (icon + tint), mirroring SleepSection's

extension DaySection {
    /// SF Symbol shown beside the card's name in the Arrange sheet.
    var customizationIcon: String {
        switch self {
        case .breakdown:      return "list.bullet.rectangle"
        case .attribution:    return "arrow.up.arrow.down"
        case .counterfactual: return "target"
        case .streaks:        return "flame"
        case .weekSummary:    return "calendar.badge.clock"
        case .trend:          return "chart.bar.xaxis"
        case .calendar:       return "calendar"
        case .settings:       return "slider.horizontal.3"
        }
    }

    /// A one-line "what this card is for", shown under its name. Sleep's sheet passes nil here; Day's
    /// cards are newer and less self-evident from a title alone, so each says what it answers.
    var customizationSubtitle: String? {
        switch self {
        case .breakdown:      return String(localized: "The score, its halves, and every component")
        case .attribution:    return String(localized: "Which components move your score most")
        case .counterfactual: return String(localized: "The gains closest to hand today")
        case .streaks:        return String(localized: "Days above zero, and the current run")
        case .weekSummary:    return String(localized: "One week at a time, browsable")
        case .trend:          return String(localized: "The score over 14 days to a year")
        case .calendar:       return String(localized: "Every scored day as a heat strip")
        case .settings:       return String(localized: "Weighting, load factor and overshoot")
        }
    }

    /// Tint for the card's Arrange-sheet icon. Day-quality is a GRADE on a finished day, so the cards
    /// lean on the charge palette (the score's own colour world) with the accent for the settings entry
    /// and amber for the two cards that name a shortfall.
    var customizationTint: Color {
        switch self {
        case .breakdown:      return StrandPalette.chargeColor
        case .attribution:    return StrandPalette.chargeBright
        case .counterfactual: return StrandPalette.metricAmber
        case .streaks:        return StrandPalette.effortColor
        case .weekSummary:    return StrandPalette.chargeColor
        case .trend:          return StrandPalette.chargeBright
        case .calendar:       return StrandPalette.restColor
        case .settings:       return StrandPalette.accent
        }
    }
}
