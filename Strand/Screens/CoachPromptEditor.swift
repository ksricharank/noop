import SwiftUI
import StrandDesign

/// One editable LLM instruction: a collapsible header, a `TextEditor`, and a Reset that is enabled
/// only when an override is actually stored.
///
/// Extracted at 260904, when the fourth prompt arrived. `CoachView` carried three hand-rolled copies
/// of this block (~55 lines each) differing only in their strings and which engine accessors they
/// touched; the day-quality prompt would have been a fourth. Four copies of a text editor is where
/// a divergence becomes inevitable — one gains a fix the others miss.
///
/// Deliberately takes BINDINGS and closures rather than an enum of prompt kinds: the engine's
/// accessors are separate stored properties (`customSystemPrompt`, `customSynthesisPrompt`, …) with
/// no common protocol, and inventing one to satisfy this view would put indirection in the engine to
/// serve the UI. The call site names which prompt it is editing; this view only knows how to edit one.
struct CoachPromptEditor: View {
    /// Plain `String`, not `LocalizedStringKey`: the accessibility labels below interpolate it, and
    /// recovering a key's literal would mean reflecting over it. Call sites pass `String(localized:)`.
    let title: String
    /// Shown when no override is stored — says what this instruction governs.
    let blurb: LocalizedStringKey
    /// Shown when one IS stored, so the state is legible without expanding.
    let customisedBlurb: LocalizedStringKey
    let icon: String
    /// The engine's `custom…Prompt` accessor. Reading gives the effective text (override or default);
    /// writing the default clears the override rather than storing a copy.
    @Binding var text: String
    /// The engine's `hasCustom…Prompt`. Gates Reset and picks the blurb.
    let isCustomised: Bool
    let onReset: () -> Void

    @State private var expanded = false
    /// A local draft so each keystroke does not write through to UserDefaults + `objectWillChange`.
    /// Seeded on expand, flushed on change — the same shape the hand-rolled bars used.
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.toggle()
                    if expanded { draft = text }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .foregroundStyle(isCustomised ? StrandPalette.accent : StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(isCustomised ? customisedBlurb : blurb)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(expanded ? "Collapse \(title)" : "Edit \(title)"))

            if expanded {
                TextEditor(text: $draft)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140, maxHeight: 240)
                    .padding(8)
                    .background(StrandPalette.surfaceInset,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    .onChangeCompat(of: draft) { newValue in text = newValue }
                    .accessibilityLabel(Text("\(title) editor"))

                HStack {
                    Spacer()
                    Button {
                        onReset()
                        draft = text
                    } label: {
                        Label("Reset to default", systemImage: "arrow.uturn.backward")
                            .font(StrandFont.footnote)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    .disabled(!isCustomised)
                    .accessibilityLabel(Text("Reset \(title) to default"))
                }
            }
        }
    }
}
