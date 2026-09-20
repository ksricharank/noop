import SwiftUI
import StrandDesign

// MARK: - Choosing what the unified Trends card draws (260920)
//
// Two decisions: WHICH metrics, and HOW to draw them. Both live here rather than in the Arrange
// sheet, which decides what sections exist — a different question from how one section is
// configured, and mixing them would put a style picker in a list of cards.
struct MultiMetricConfigSheet: View {
    @Binding var overlayRaw: String
    @Binding var rowsRaw: String
    @Binding var heatmapRaw: String
    @Binding var styleRaw: String
    @Environment(\.dismiss) private var dismiss

    @State private var selected: [MultiMetric] = []
    @State private var style: MultiMetricStyle = .overlay
    /// Which style the on-screen selection belongs to, so a style change writes the edits back to
    /// the style they were made under rather than to the newly-chosen one.
    @State private var previousStyle: MultiMetricStyle = .overlay

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    styleCard
                    metricsCard
                }
                .padding(NoopMetrics.space2)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("All metrics")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { save(); dismiss() }
                }
            }
        }
        .onAppear {
            style = MultiMetricPrefs.decodeStyle(styleRaw)
            selected = load(style)
        }
        // Switching style swaps the whole metric list to THAT style's set (260920). The previous
        // style's edits are saved first, so flicking between them to compare does not discard work
        // — which is the natural thing to do while deciding, and would otherwise silently lose a
        // selection every time.
        .onChangeCompat(of: style) { newStyle in
            save(for: previousStyle)
            previousStyle = newStyle
            selected = load(newStyle)
        }
    }

    private var styleCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("How to draw it", overline: "Style")
                Picker("Style", selection: $style) {
                    ForEach(MultiMetricStyle.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                // The blurb is the point of offering three: "Overlay / Rows / Heatmap" names them
                // without saying which question each answers.
                Text(style.blurb)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var metricsCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("What to show", overline: "Metrics for \(style.title)",
                              trailing: "\(selected.count)")
                ForEach(MultiMetric.allCases) { metric in
                    Button {
                        toggle(metric)
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(metric.color).frame(width: 9, height: 9)
                            Text(metric.title)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer(minLength: 0)
                            Image(systemName: selected.contains(metric)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(metric)
                                                 ? StrandPalette.accent : StrandPalette.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected.contains(metric) ? [.isSelected] : [])
                }
                // Turning the last one off would leave a card that draws nothing, which reads as a
                // fault rather than as a choice. Hiding the whole card is what Arrange is for, and
                // the note says so instead of letting the state be reached and look broken.
                Text("Each style keeps its own list, so switching style above changes what you are editing here. Keep at least one; to remove the card entirely, hide it in Arrange.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toggle(_ metric: MultiMetric) {
        if let i = selected.firstIndex(of: metric) {
            guard selected.count > 1 else { return }
            selected.remove(at: i)
        } else {
            // Appended, so the draw order follows the order they were switched on — the legend and
            // the row stack then read in the order the wearer built.
            selected.append(metric)
        }
    }

    private func load(_ s: MultiMetricStyle) -> [MultiMetric] {
        let raw: String
        switch s {
        case .overlay: raw = overlayRaw
        case .rows:    raw = rowsRaw
        case .heatmap: raw = heatmapRaw
        }
        if !raw.isEmpty { return MultiMetricPrefs.decode(raw, style: s) }
        return MultiMetricPrefs.resolved(style: s)
    }

    private func save(for s: MultiMetricStyle) {
        let encoded = MultiMetricPrefs.encode(selected)
        switch s {
        case .overlay: overlayRaw = encoded
        case .rows:    rowsRaw = encoded
        case .heatmap: heatmapRaw = encoded
        }
    }

    private func save() {
        save(for: style)
        styleRaw = style.rawValue
    }
}
