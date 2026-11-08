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
    /// The figures the summary is ABOUT, flattened to a string (261009). When it changes under the same
    /// subject, the text is rewritten; nothing else triggers an automatic rewrite. nil = no data-follow:
    /// the text is written once per subject (the daily insight and the window summary, both keyed on
    /// the local day). Build it from only what the summary reads — a key that moves with unrelated data
    /// is the churn this exists to remove.
    var dataKey: String? = nil
    /// Produces the text. Returns nil on any failure — no provider, no consent, an empty reply —
    /// and the card then says so plainly rather than pretending.
    /// Produces the text from the engine the card owns. Takes it as a parameter so the tab
    /// roots do not have to hold — and therefore observe — the engine themselves.
    let generate: (AICoachEngine) async -> String?
    /// 260922: this tab's last generation outcome (e.g. `\.lastSleepOutcome`), so a FAILED request is
    /// reported as what it was. The card used to show "Set up a coach provider in Settings" for any
    /// nil result — a timed-out or rate-limited request on a fully configured provider included —
    /// which read as a broken connection that was never broken.
    var lastOutcome: ((AICoachEngine) -> String?)? = nil
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
    /// What this tab's "Ask the Coach" should OPEN ON (260920, maintainer request: "if I press it
    /// from the sleep button, the coach when opened should be operating that as a follow up to the
    /// sleep LLM output in the sleep tab").
    ///
    /// Without this, every tab's button opened the same blank chat and the wearer had to re-explain
    /// which reading they were asking about — the summary they were looking at was right there and
    /// the coach could not see it. The card hands over the SUMMARY IT IS SHOWING plus a one-line
    /// framing, so the first turn is already a follow-up.
    ///
    /// Takes the generated text because the seed is only meaningful once there IS a summary; the
    /// button is hidden until then anyway.
    var coachFollowUp: ((String) -> String)? = nil

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
    /// The `dataKey` the shown text was generated FROM (261009).
    @State private var textDataKey: String?
    @State private var inFlight = false
    /// Latest-wins token: a load whose token is no longer current discards its result, so a
    /// superseded generation can never land on top of a newer one.
    @State private var loadToken = 0

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
            .overlay(alignment: .trailing) {
                // Regenerate (260920, maintainer request: the same affordance the Today synthesis
                // already carries, on the other three tabs).
                //
                // An OVERLAY rather than another element inside the disclosure button's label: a
                // Button nested in a Button's label is not independently tappable, so the refresh
                // would have toggled the section instead of regenerating it.
                //
                // Shown only while expanded — a refresh on a collapsed section would spend a
                // provider call on text nobody is looking at, which is the cost the whole
                // generate-on-first-expand design exists to avoid.
                if expanded {
                    Button {
                        Task { await load(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(StrandFont.caption)
                            .foregroundStyle(inFlight ? StrandPalette.textTertiary : StrandPalette.accent)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(inFlight)
                    .accessibilityLabel(Text("Regenerate \(title)"))
                }
            }

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
                    Text(fallbackCopy)
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
                        Button {
                            // Seed the chat with THIS tab's reading so the first turn is a
                            // follow-up, not a cold open. Falls back to a plain open when a caller
                            // supplied no framing, which is the old behaviour.
                            if let text, let coachFollowUp {
                                coach.pendingPrompt = coachFollowUp(text)
                            }
                            router.openCoach()
                        } label: {
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
        // ONE loader, keyed on what the text describes: the subject AND this card's own inputs.
        //
        // 261009 (the "summary updates twice within seconds" report): the 19.5 version re-asked on
        // EVERY `repo.refreshSeq` bump, and that sequence moves on every strap sync — steps, effort,
        // calories — none of which a summary of LAST NIGHT or YESTERDAY reads. So Sleep and Recap were
        // rewritten every ~10 minutes and twice within seconds when two refreshes landed back to back,
        // and the once-a-day insight re-asked through the day, feeding copies of today's headline into
        // its own no-repeat ledger. Each caller now passes `dataKey` built from exactly the figures its
        // summary is about; a change to anything else no longer reaches the provider.
        //
        // `.task(id:)` is what makes it stable: a key change CANCELS the in-flight request and starts
        // again with the current view — subject, generate closure and all — so a burst of changes
        // produces one generation and one visible update, the newest. Also runs on first appear, which
        // is where `startsExpanded` opens the card (applied here, not as the @State initial value,
        // because @State initialisers run once per view identity).
        .task(id: reloadKey) {
            if startsExpanded, text == nil, !expanded { expanded = true }
            guard expanded else { return }
            // Same subject, different inputs = the data under the shown text moved: write it again.
            // A new subject goes through the cache check (stepping back to a night already read).
            let dataMoved = text != nil && textSubject == subject && textDataKey != dataKey
            await load(force: dataMoved)
        }
    }

    /// What the text depends on. A change to it is the only automatic reason to re-ask.
    private var reloadKey: String { subject + "\u{1F}" + (dataKey ?? "") }

    /// `force` bypasses the cache — the Regenerate button's path. Everything else (first expand,
    /// a subject change) keeps the cached text so returning to a tab does not re-spend a call.
    /// What to say when there is no text: the provider's own reason when one is configured (a
    /// timeout, a rate limit, an empty reply), the set-up hint only when there is nothing to call.
    private var fallbackCopy: String {
        guard coach.isConfigured else {
            return String(localized: "No summary available. Set up a coach provider in Settings to get one.")
        }
        if let reason = lastOutcome?(coach), !reason.isEmpty, !reason.hasPrefix("written") {
            return String(localized: "Couldn't write this summary — \(reason). Tap ↻ to try again.")
        }
        return String(localized: "No summary yet. Tap ↻ to write one.")
    }

    private func load(force: Bool = false) async {
        if !force { guard textSubject != subject || text == nil else { return } }
        loadToken += 1
        let mine = loadToken
        inFlight = true
        let produced = await generate(coach)
        // Superseded (a newer key cancelled this task, or a newer load started): drop the result rather
        // than flash it, and leave `inFlight` to the load that is current.
        guard !Task.isCancelled, mine == loadToken else { return }
        inFlight = false
        text = produced
        textSubject = produced == nil ? nil : subject
        textDataKey = produced == nil ? nil : dataKey
    }
}
