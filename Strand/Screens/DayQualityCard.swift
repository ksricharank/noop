import SwiftUI
import MarkdownUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Yesterday's day-quality score, at the top of Trends.
///
/// Deliberately NOT in the daily synthesis. The synthesis is about today — what to do next — and a
/// score for a finished day would compete with it. This is the retrospective half: one number for
/// how yesterday went, the arithmetic behind it, a narrative, and the trend it belongs to.
///
/// ## Where each part comes from
///
/// The **number** is read from the stored `day_quality` series, so the card agrees with the trend
/// chart below it by construction rather than by two code paths happening to match.
///
/// The **breakdown** is re-scored on demand from the same inputs the nightly pass used. Storing the
/// component table alongside the total was the alternative, and it was rejected: a stored breakdown
/// can disagree with a stored total after any formula change, and the re-score is cheap for a single
/// day. If they ever disagree the panel is wrong and the headline is right, which is the safer
/// failure — the headline is what the trend is built from.
///
/// The **narrative** is the coach's, cached per day so it is requested once rather than on every
/// render, and absent rather than apologetic when there is no provider configured.
struct DayQualityCard: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var coach: AICoachEngine
    /// For the "Ask the Coach" link, the same affordance the Today synthesis carries.
    @EnvironmentObject var router: NavRouter

    /// The stored series, keyed "yyyy-MM-dd" → score. Passed in from Trends, which already loads it
    /// for the chart — one read, two surfaces.
    let scoresByDay: [String: Double]

    @State private var showComputation = false
    @State private var showNarrative = false
    /// Re-scored breakdown for the day on show. Built once per (day, config) rather than in `body`.
    @State private var breakdown: DayQualityScore?
    @State private var narrative: String?
    @State private var narrativeDay: String?
    @State private var narrativeInFlight = false

    /// Which scored day to show, as an index back through the scored days — 0 is the most recent, 1
    /// the one before it. Not a calendar offset: unscored days are skipped, so stepping back always
    /// lands on a day that HAS a score rather than on a blank card the wearer has to step past.
    ///
    /// A plain value with a default rather than state, so the compact card on Trends keeps its
    /// existing "latest scored day" behaviour untouched and the detail screen drives the same view
    /// through a binding it owns.
    var dayIndex: Int = 0

    /// Scored days, newest first — the axis `dayIndex` walks.
    private var scoredDays: [String] { scoresByDay.keys.sorted().reversed() }

    /// The day on show. Clamped rather than trapping: the series reloads while the screen is open, so
    /// an index can briefly outrun it.
    private var day: String? {
        guard !scoredDays.isEmpty else { return nil }
        return scoredDays[min(max(0, dayIndex), scoredDays.count - 1)]
    }
    private var score: Int? { day.flatMap { scoresByDay[$0] }.map { Int($0.rounded()) } }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                SectionHeader("Day quality", overline: overline, trailing: dayLabel)
                if let score {
                    headline(score)
                    computationSection
                    narrativeSection
                    coachLink
                } else {
                    // Honest empty state. A score needs a finished day with enough of it recorded,
                    // so a fresh install legitimately has nothing to show yet.
                    Text("No finished day has been scored yet. The first score lands after tonight's sleep is scored.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .task(id: day) { await load() }
    }

    /// "Yesterday" only when the day on show actually IS yesterday. The card can now be pointed at any
    /// scored day, and a hard-coded "Yesterday" over a day three weeks back would be a plain lie —
    /// the same stale-label class of bug as the synthesis strip. Older days name their weekday instead.
    private var overline: LocalizedStringKey {
        let band = score.map { " · \(DayQualityScore.band($0))" } ?? ""
        return LocalizedStringKey(relativeDayName + band)
    }

    /// "Yesterday" / "Today" where those are true, else the weekday ("Monday").
    private var relativeDayName: String {
        guard let day, let d = Self.dayParser.date(from: day) else { return String(localized: "Yesterday") }
        let cal = Calendar.current
        if cal.isDateInYesterday(d) { return String(localized: "Yesterday") }
        if cal.isDateInToday(d) { return String(localized: "Today") }
        return d.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))
    }

    /// "Mon 2 Sep" — the day being summarised, so the card cannot be mistaken for a live number.
    private var dayLabel: String? {
        guard let day, let d = Self.dayParser.date(from: day) else { return nil }
        return Self.dayFormatter.string(from: d)
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE d MMM"); return f
    }()

    // MARK: - Headline

    private func headline(_ score: Int) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text("\(score)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(tint(for: score))
                .monospacedDigit()
            Text("/ 100")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            if let b = breakdown {
                // The two halves, so the headline is decomposable at a glance without expanding
                // anything: "did the work" vs "absorbed it" is the whole reason the score has halves.
                VStack(alignment: .trailing, spacing: 2) {
                    halfLabel("Execution", b.executionPoints)
                    halfLabel("Recovery", b.recoveryPoints)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Day quality"))
        .accessibilityValue(Text("\(score) out of 100, \(DayQualityScore.band(score))"))
    }

    private func halfLabel(_ name: LocalizedStringKey, _ points: Double) -> some View {
        HStack(spacing: 4) {
            Text(name).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text("\(Int(points.rounded()))")
                .font(StrandFont.caption).monospacedDigit()
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    /// Colour by band, using the existing domain palette rather than a new scale.
    private func tint(for score: Int) -> Color {
        switch score {
        case 75...: return StrandPalette.chargeColor
        case 60..<75: return StrandPalette.restColor
        case 45..<60: return StrandPalette.metricAmber
        default: return StrandPalette.textSecondary
        }
    }

    // MARK: - How it was computed (collapsible)

    private var computationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showComputation.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showComputation ? "chevron.down" : "chevron.right")
                        .font(StrandFont.caption)
                    Text("How this was computed").font(StrandFont.caption)
                }
                .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showComputation ? "Collapse the computation" : "Expand the computation")

            if showComputation {
                if let b = breakdown {
                    ForEach(b.components, id: \.label) { c in
                        componentRow(c)
                    }
                    if b.loadFactor != 1.0 {
                        // Only shown when it actually moved the number — a ×1.00 line is noise.
                        Text(loadFactorLine(b.loadFactor))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !b.missing.isEmpty {
                        // What the score could NOT see. Stated rather than silently renormalised
                        // away, so a day with a missing night is legible as such.
                        Text("Not recorded: \(b.missing.joined(separator: ", ")) — the score is out of what was measured.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("The breakdown needs this day's stored numbers, which aren't loaded.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    /// One component: what it was, what it hit, and what it contributed.
    private func componentRow(_ c: DayQualityScore.Component) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(c.label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 74, alignment: .leading)
            Text(c.detail)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            // Points earned out of the points available — the arithmetic, not a re-derivation.
            Text("\(fmt(c.points))/\(fmt(c.weight))")
                .font(StrandFont.caption).monospacedDigit()
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(c.label))
        .accessibilityValue(Text("\(c.detail). \(fmt(c.points)) of \(fmt(c.weight)) points."))
    }

    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }

    private func loadFactorLine(_ f: Double) -> String {
        let pct = Int(((f - 1) * 100).rounded())
        return pct > 0
            ? "Yesterday's targets were harder than your recent average, so the execution half was scaled up \(pct)%."
            : "Yesterday's targets were easier than your recent average, so the execution half was scaled down \(abs(pct))%."
    }

    // MARK: - Narrative (collapsible)

    private var narrativeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(StrandPalette.hairline)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showNarrative.toggle() }
                if showNarrative { Task { await loadNarrative() } }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showNarrative ? "chevron.down" : "chevron.right")
                        .font(StrandFont.caption)
                    Text("What it means").font(StrandFont.caption)
                    if narrativeInFlight {
                        ProgressView().controlSize(.mini)
                    }
                }
                .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showNarrative ? "Collapse the summary" : "Expand the summary")

            if showNarrative {
                if let narrative {
                    // MARKDOWN, not plain Text (260904). The coach replies in GitHub-flavored
                    // Markdown — overwhelmingly bold, sometimes a list — and a plain `Text` renders
                    // `**like this**` as literal asterisks. Every other coach surface (the Today
                    // synthesis, the Q&A bubbles) already uses MarkdownUI; this card was the one
                    // that did not, so it was the one showing raw syntax.
                    //
                    // `.strandSynthesis` rather than `.strand`: same footnote-scale secondary tone
                    // this card already used, so only the FORMATTING changes, not the type size.
                    Markdown(narrative)
                        .markdownTheme(.strandSynthesis)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !narrativeInFlight {
                    // No provider, no consent, or the call failed. The card says so plainly rather
                    // than pretending — every other part of it still works.
                    Text("No summary available. Set up a coach provider in Settings to get one.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "Ask the Coach", mirroring the Today synthesis's affordance (260904, maintainer request).
    ///
    /// Worth having here specifically because the coach now receives the day-quality HISTORY — the
    /// recent run plus both 7-day averages — so a question asked from this card lands in a
    /// conversation that can already see the trend the card is showing.
    private var coachLink: some View {
        HStack {
            Spacer()
            Button {
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

    // MARK: - Loading

    /// Re-score the day on show, for the breakdown panel. Cheap (one day, one target walk) and
    /// keyed on the day, so it runs on appearance and on a day roll — never per render.
    private func load() async {
        guard let day else { breakdown = nil; return }
        let history = repo.days
        guard !history.isEmpty else { return }
        let profile = repo.liveTargetsProfile?() ?? UserProfile()
        let needed = DayQualityComputer.targetDaysNeeded(toScore: [day], history: history)
        let targets = DayQualityComputer.targetsByDay(history: history, profile: profile,
                                                      onlyDays: needed)
        let water = repo.waterCupsAndTarget(forDay: day)
        guard let input = DayQualityComputer.input(for: day, history: history, profile: profile,
                                                  targetsByDay: targets,
                                                  waterCups: water?.cups,
                                                  waterTargetCups: water?.target) else { return }
        breakdown = DayQualityScore.score(input, config: DayQualityPrefs.config)
    }

    /// One coach call per day, cached in `@State`. Requested only when the section is opened — a
    /// narrative nobody expanded is a network call and a token spend for nothing.
    private func loadNarrative() async {
        guard let day, let breakdown else { return }
        guard narrativeDay != day || narrative == nil else { return }
        guard !narrativeInFlight else { return }
        narrativeInFlight = true
        defer { narrativeInFlight = false }
        let text = await coach.dayQualityNarrative(day: day, score: breakdown)
        narrative = text
        narrativeDay = text == nil ? nil : day
    }
}
