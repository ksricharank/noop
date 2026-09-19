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
    /// Produces the text from the engine the card owns. Takes it as a parameter so the tab
    /// roots do not have to hold — and therefore observe — the engine themselves.
    let generate: (AICoachEngine) async -> String?
    /// Whether the section starts open. Recap's does (260919, maintainer request): it is the tab's
    /// headline read, and a section that has to be opened to be seen is one that is not read.
    ///
    /// Opening by default means GENERATING by default, which is the cost — a provider call on every
    /// visit to that tab. Worth it where the summary is the point of the screen; not worth it on a
    /// tab the wearer opens to look at a chart, which is why it is opt-in rather than the default.
    var startsExpanded: Bool = false
    /// Whether to offer "Ask the Coach" under the text. The card opens the chat itself through the
    /// router it owns, so a caller does not have to hold one to show the link.
    var showsAskCoach: Bool = false

    /// The coach engine, owned HERE rather than by the tab root (260919).
    ///
    /// `@EnvironmentObject` subscribes to the whole object's `objectWillChange`, and
    /// `AICoachEngine` has 32 `@Published` properties — one of which, `synthesisRefreshing`,
    /// toggles while a summary generates. Held on a tab root, every one of those re-evaluated a
    /// ~2000-line body, which is the choppy scrolling reported on 260919. The tab roots never read
    /// the engine in their bodies at all; they only captured it for the `generate` closure. Same
    /// leaf-scoping SleepView already applies to LiveState and AppModel.
    @EnvironmentObject private var coach: AICoachEngine
    /// Owned here for the same reason as `coach`: the Ask-the-Coach button is the only consumer,
    /// and a tab root holding it would subscribe the whole body to every navigation publish.
    @EnvironmentObject private var router: NavRouter

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
                if showsAskCoach, text != nil {
                    HStack {
                        Spacer()
                        Button { router.openCoach() } label: {
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
        let produced = await generate(coach)
        text = produced
        textSubject = produced == nil ? nil : subject
    }
}
