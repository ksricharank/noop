import SwiftUI
import StrandDesign
import MarkdownUI

/// The per-tab LLM summary (260919, maintainer request: "each tab with an LLM section, that is true
/// to the purpose of the tab").
///
/// Today already had the synthesis and Recap had "What it means"; Trends and Sleep had nothing. One
/// card serves all the collapsible ones so the four surfaces cannot drift apart in behaviour — the
/// lens each one applies is a PROMPT difference, not a UI difference.
///
/// Collapsed by default and generating only on first expand, deliberately: a narrative nobody opened
/// is a provider call, a token spend and a battery cost for text that was never read. Cached per
/// `subject` so re-expanding, or returning to the tab, does not re-ask.
struct TabInsightCard: View {
    /// What the section is called on this tab — "What the trend says", "What last night says".
    let title: String
    /// Identifies WHAT is being summarised (a day key, a window, a night). A change here is what
    /// makes the card re-ask; an unchanged subject re-shows the cached text.
    let subject: String
    /// Produces the text. Returns nil on any failure — no provider, no consent, an empty reply —
    /// and the card then says so plainly rather than pretending.
    let generate: () async -> String?
    /// Whether the section starts open. Recap's does (260919, maintainer request): it is the tab's
    /// headline read, and a section that has to be opened to be seen is one that is not read.
    ///
    /// Opening by default means GENERATING by default, which is the cost — a provider call on every
    /// visit to that tab. Worth it where the summary is the point of the screen; not worth it on a
    /// tab the wearer opens to look at a chart, which is why it is opt-in rather than the default.
    var startsExpanded: Bool = false
    /// Shown under the text when set — "Ask the Coach", carrying this tab's subject into the chat.
    var onAskCoach: (() -> Void)? = nil

    @State private var expanded = false
    @State private var text: String?
    @State private var textSubject: String?
    @State private var inFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                if expanded { Task { await load() } }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(StrandFont.caption)
                    Text(title).font(StrandFont.caption)
                    if inFlight { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(StrandPalette.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse \(title)" : "Expand \(title)")

            if expanded {
                if let text {
                    // MARKDOWN, not plain Text: the coach replies in GitHub-flavored Markdown, and a
                    // plain `Text` renders `**like this**` as literal asterisks — the bug #260904
                    // fixed on the Recap card. Same theme, so the four surfaces read alike.
                    Markdown(text)
                        .markdownTheme(.strandSynthesis)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !inFlight {
                    Text("No summary available. Set up a coach provider in Settings to get one.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // "Ask the Coach", mirroring the affordance the Today synthesis and the Recap card
                // already carry. Offered only once there is something to ask ABOUT — a link under an
                // empty section would open a chat with no shared context.
                if let onAskCoach, text != nil {
                    HStack {
                        Spacer()
                        Button(action: onAskCoach) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles").font(StrandFont.caption)
                                Text("Ask the Coach").font(StrandFont.caption.weight(.semibold))
                            }
                            .foregroundStyle(StrandPalette.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Opens the AI Coach chat"))
                    }
                    .padding(.top, 2)
                }
            }
        }
        .task {
            // Applied here rather than as the @State initial value: @State initialisers run once per
            // view identity, and this card is rebuilt as tabs and subjects change. Guarded on
            // `text == nil` so returning to the tab does not re-open a section the wearer collapsed.
            if startsExpanded, text == nil, !expanded {
                expanded = true
                await load()
            }
        }
        // A subject change while the card is OPEN must re-ask — otherwise stepping to another night
        // or another window leaves the previous answer sitting under the new numbers, which is the
        // stale-synthesis bug in miniature.
        .onChangeCompat(of: subject) { _ in
            guard expanded else { return }
            Task { await load() }
        }
    }

    private func load() async {
        guard textSubject != subject || text == nil else { return }
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        let produced = await generate()
        text = produced
        textSubject = produced == nil ? nil : subject
    }
}
