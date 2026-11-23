import SwiftUI
import StrandDesign

// MARK: - Choosing what one unified card draws, and in what order (260920)
//
// Edits ONE card's metric list — the row stack and the heatmap each present their own copy of this
// sheet, because they are separate sections with separate selections.
//
// Order matters and is the wearer's: the row stack renders top-to-bottom in this order and the
// heatmap row-by-row, so "put sleep under charge" is a layout decision only they can make.
struct MultiMetricConfigSheet: View {
    let style: MultiMetricStyle
    @Binding var selectionRaw: String
    @Environment(\.dismiss) private var dismiss

    /// Shown metrics, in draw order.
    @State private var selected: [MultiMetric] = []
    /// Everything else, so the list can show both without a second data source.
    @State private var available: [MultiMetric] = []
    // `EditMode` is iOS-only. On macOS a List's rows reorder by drag without it, so the guard is
    // the whole difference rather than a behavioural one.
    #if os(iOS)
    @State private var editMode: EditMode = .active
    #endif

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(selected) { metric in
                        row(metric, shown: true)
                    }
                    .onMove(perform: move)
                    .onDelete(perform: hide)
                } header: {
                    Text("Shown — drag to reorder")
                } footer: {
                    Text(style == .rows
                         ? "Strips are drawn in this order, top to bottom."
                         : "Heatmap rows are drawn in this order, top to bottom.")
                }

                if !available.isEmpty {
                    Section("Hidden") {
                        ForEach(available) { metric in
                            Button { show(metric) } label: { row(metric, shown: false) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            #if os(iOS)
            .environment(\.editMode, $editMode)
            #endif
            .navigationTitle(style.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(); dismiss() }
                }
            }
        }
        .onAppear(perform: load)
    }

    private func row(_ metric: MultiMetric, shown: Bool) -> some View {
        HStack(spacing: 10) {
            Circle().fill(metric.color).frame(width: 9, height: 9)
            Text(metric.title)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 0)
            if !shown {
                Image(systemName: "plus.circle")
                    .foregroundStyle(StrandPalette.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private func load() {
        selected = MultiMetricPrefs.resolved(style: style)
        if !selectionRaw.isEmpty {
            selected = MultiMetricPrefs.decode(selectionRaw, style: style)
        }
        available = MultiMetric.allCases.filter { !selected.contains($0) }
    }

    private func move(from source: IndexSet, to destination: Int) {
        selected.move(fromOffsets: source, toOffset: destination)
    }

    /// Removing the last metric is refused: a card drawing nothing reads as broken rather than as
    /// configured, and hiding the whole card is what Arrange is for.
    private func hide(at offsets: IndexSet) {
        guard selected.count - offsets.count >= 1 else { return }
        let removed = offsets.map { selected[$0] }
        selected.remove(atOffsets: offsets)
        available.append(contentsOf: removed)
        available.sort { a, b in
            (MultiMetric.allCases.firstIndex(of: a) ?? 0) < (MultiMetric.allCases.firstIndex(of: b) ?? 0)
        }
    }

    /// Appended rather than inserted at its enum position, so a metric switched on lands where the
    /// wearer will look for it — at the end of the list they are building — and can then be dragged.
    private func show(_ metric: MultiMetric) {
        guard let i = available.firstIndex(of: metric) else { return }
        available.remove(at: i)
        selected.append(metric)
    }

    private func save() {
        selectionRaw = MultiMetricPrefs.encode(selected)
    }
}
