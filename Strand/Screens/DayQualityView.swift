import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The Day Quality screen: one finished day's score in full, and the trend it belongs to.
///
/// 260906, maintainer's ask: the Trends card showed only the latest scored day with no way to look
/// back, and the trend items lived far down the page under the shared range selector. This screen is
/// the two halves together — Sleep's per-day browsing above, Trends' rollups below — so a score can be
/// read *and* placed without leaving the page.
///
/// ## What is reused rather than rebuilt
///
/// The score, the two halves, the re-scored component breakdown and the coach narrative are all
/// `DayQualityCard`, driven here by a `dayIndex` this screen owns. The card is unchanged apart from
/// gaining that index, so the compact card still on Trends and this screen cannot drift: there is one
/// implementation of "what a day-quality score looks like", not two.
///
/// ## Why the axis is scored days, not calendar days
///
/// Stepping back moves to the previous day that HAS a score, skipping days the strap missed. A
/// calendar walk would strand the wearer on blank cards with no indication of how far back the next
/// real score sits — and day quality is only defined for a finished, sufficiently-recorded day.
struct DayQualityView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var appModel: AppModel

    /// Stored series, "yyyy-MM-dd" → score. Loaded here rather than passed in so the screen stands on
    /// its own as a tab root (Trends loads its own copy for the chart it still draws).
    @State private var scoresByDay: [String: Double] = [:]
    /// Index back through the SCORED days, newest first. 0 = the most recent scored day.
    @State private var dayIndex = 0
    /// Which window the trend section covers. Local to this screen — the Trends page has its own
    /// selector, and sharing one across two screens would make each surprise the other.
    @State private var window = Self.windows[1]

    // MARK: Arrangeable layout (260908)
    //
    // The tab went from four blocks to nine; a fixed wall of that many means scrolling past the cards
    // you do not care about every time. Same mechanism as Sleep and Today — see `DayLayoutPrefs`.
    @AppStorage(DayLayoutPrefs.orderKey) private var daySectionOrderRaw = ""
    @AppStorage(DayLayoutPrefs.hiddenKey) private var dayHiddenSectionsRaw = ""
    @State private var showDayCustomize = false

    /// Re-scored breakdowns for the days inside the current window, for the attribution card. Loaded
    /// here rather than in the card so ONE pass serves it and the counterfactual card both.
    @State private var windowBreakdowns: [DayQualityScore] = []
    /// The browsed day's own breakdown plus the actuals/targets behind it, for the counterfactual card.
    @State private var browsedBreakdown: DayQualityScore?
    @State private var browsedActuals: [String: Double] = [:]
    @State private var browsedTargets: [String: Double] = [:]

    private var visibleSections: [DaySection] {
        DayLayoutPrefs.visibleOrder(orderRaw: daySectionOrderRaw, hiddenRaw: dayHiddenSectionsRaw)
    }

    /// 260906: day quality now owns the full span, since the Trends page no longer carries it at all
    /// (maintainer: "remove day quality completely from the trends section"). A year is included
    /// because the calendar strip below the chart is worth a long view.
    static let windows: [ScoreTrendSection.Window] = [
        .init(days: 14, label: "14d"), .init(days: 30, label: "30d"),
        .init(days: 90, label: "90d"), .init(days: 365, label: "1y"),
    ]

    /// Scored days, newest first — the axis `dayIndex` walks.
    private var scoredDays: [String] { scoresByDay.keys.sorted().reversed() }
    private var lastIndex: Int { max(scoredDays.count - 1, 0) }

    var body: some View {
        ScreenScaffold(title: "Day quality",
                       subtitle: "How a finished day actually went",
                       onRefresh: { await repo.refresh() }) {
            // The date navigator is the tab's fixed frame — pinned above the arrangeable cards,
            // exactly as Sleep pins its hero and date nav. A tab whose subject can be hidden has no
            // subject.
            navHeader
            dayArrangeAffordance
            ForEach(visibleSections) { section in
                daySectionView(section)
            }
        }
        .sheet(isPresented: $showDayCustomize) {
            DayCustomizationSheet(sectionOrderRaw: $daySectionOrderRaw,
                                  hiddenSectionsRaw: $dayHiddenSectionsRaw)
        }
        .task(id: repo.days.count) { await load() }
        // The Insights inputs. Keyed on the window AND the browsed day, so stepping either re-derives
        // exactly once rather than on every render.
        .task(id: "\(window.days)-\(dayIndex)-\(scoresByDay.count)") { await loadInsights() }
        // A reload can shorten the series while the screen is open; an index left past the end would
        // silently clamp to a different day than the header names. Snap back, like SleepView does.
        .onChangeCompat(of: scoresByDay.count) { _ in
            if dayIndex > lastIndex { dayIndex = 0 }
        }
    }

    // MARK: - Arrangeable sections

    /// One card per `DaySection`. Every branch is a view that already existed or a new Insights card;
    /// this only decides which render and in what order.
    @ViewBuilder
    private func daySectionView(_ section: DaySection) -> some View {
        switch section {
        case .breakdown:
            // The score, its halves, the component breakdown, and the coach narrative in its own
            // collapsible section inside this card.
            DayQualityCard(scoresByDay: scoresByDay, dayIndex: dayIndex)
        case .attribution:
            DayQualityAttributionCard(breakdowns: windowBreakdowns, windowLabel: window.label)
        case .counterfactual:
            if let b = browsedBreakdown {
                DayQualityCounterfactualCard(score: b, actuals: browsedActuals,
                                             targets: browsedTargets, config: DayQualityPrefs.config)
            }
        case .streaks:
            DayQualityStreakCard(valuesByDay: scoresByDay, windowLabel: window.label)
        case .weekSummary, .trend, .calendar:
            // These three are the three halves of `ScoreTrendSection`, which is shared with Sleep so
            // the two tabs cannot drift. It renders as one unit, so it is emitted once — on whichever
            // of the three sits highest in the saved order — rather than being split into three
            // copies of the same view.
            if section == firstTrendSectionInOrder {
                ScoreTrendSection(title: "Day quality trend", valuesByDay: scoresByDay,
                                  windows: Self.windows, window: $window,
                                  // The signed range, explicitly: the section defaults to the 0…106
                                  // rest scale, which would fold the whole negative half onto the
                                  // chart's floor.
                                  valueRange: Double(DayQualityScore.publishedMinimum)
                                      ... Double(DayQualityScore.publishedMaximum),
                                  showsBars: true,
                                  lowLabel: "Depleted", highLabel: "Excellent")
            }
        case .settings:
            DayQualitySettingsCard()
        }
    }

    /// Whichever of the three `ScoreTrendSection` cards sits highest in the saved order — the slot the
    /// combined section renders in. Nil when all three are hidden, which correctly renders nothing.
    private var firstTrendSectionInOrder: DaySection? {
        visibleSections.first { $0 == .weekSummary || $0 == .trend || $0 == .calendar }
    }

    /// The compact "Customize" affordance above the arrangeable cards. Mirrors Sleep's and Today's.
    private var dayArrangeAffordance: some View {
        HStack(spacing: 0) {
            Spacer()
            Button {
                showDayCustomize = true
            } label: {
                Label("Customize", systemImage: "slider.horizontal.3")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Customize the Day tab layout")
        }
    }

    // MARK: - Day navigation

    /// Mirrors `SleepView.nightNavHeader`: older on the left, newer on the right, both disabled at the
    /// ends with the current day named between them.
    @ViewBuilder
    private var navHeader: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
            HStack(spacing: NoopMetrics.cardInnerSpacing) {
                Button { if dayIndex < lastIndex { dayIndex += 1 } } label: {
                    Image(systemName: "chevron.left")
                        .font(StrandFont.headline)
                        .foregroundStyle(dayIndex >= lastIndex ? StrandPalette.textTertiary : StrandPalette.accent)
                }
                .buttonStyle(LiquidPressStyle())
                .disabled(dayIndex >= lastIndex)
                .accessibilityLabel("Previous scored day")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Day quality").strandOverline()
                    Text(dayTitle)
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { if dayIndex > 0 { dayIndex -= 1 } } label: {
                    Image(systemName: "chevron.right")
                        .font(StrandFont.headline)
                        .foregroundStyle(dayIndex == 0 ? StrandPalette.textTertiary : StrandPalette.accent)
                }
                .buttonStyle(LiquidPressStyle())
                .disabled(dayIndex == 0)
                .accessibilityLabel("Next scored day")
            }
            // A greyed-out chevron with no explanation reads as broken (the #614 lesson from Sleep).
            // Say why there is nothing further back.
            if dayIndex >= lastIndex, !scoredDays.isEmpty {
                Text("This is the earliest scored day. Day quality needs a finished day with enough of it recorded.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Yesterday" / "Today" where true, else "Mon 2 Sep".
    private var dayTitle: String {
        guard dayIndex < scoredDays.count, let d = Self.dayParser.date(from: scoredDays[dayIndex]) else {
            return String(localized: "No scored day yet")
        }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return String(localized: "Today") }
        if cal.isDateInYesterday(d) { return String(localized: "Yesterday") }
        return Self.dayFormatter.string(from: d)
    }

    // MARK: - Load

    private func load() async {
        // RE-SCORE FIRST when the stored series was computed under a different formula (260909).
        //
        // Everything below the score card — the trend chart, the week summary, the calendar strip and
        // the streaks — reads the STORED series, while the card itself re-scores the browsed day live.
        // After a formula change those two disagree, and the reported symptom was exactly that: a
        // −22 on the card with the old value still in the week view.
        //
        // The scoring pass is the only writer, and it runs on the engine's schedule — so opening this
        // tab could show the mismatch indefinitely with no way for the wearer to resolve it. Asking
        // for the re-score here closes that: it is idempotent, latched to once per (day, config), and
        // a no-op on every visit after the first, so this costs nothing in the steady state.
        //
        // Deliberately BEFORE the read, and awaited, so the first paint already shows one formula
        // rather than flashing the old numbers and correcting itself.
        if DayQualityPrefs.configChanged {
            await appModel.intelligence.rescoreDayQualityNow()
        }
        let series = await repo.exploreSeries(key: DayQualityComputer.metricKey, source: "my-whoop")
        var byDay: [String: Double] = [:]
        for p in series { byDay[p.day] = p.value }
        scoresByDay = byDay
        if dayIndex > max(byDay.count - 1, 0) { dayIndex = 0 }
    }

    /// Re-derive the Insights inputs: the breakdowns for the window (attribution) and the browsed
    /// day's actuals/targets (counterfactuals).
    ///
    /// One pass serves both cards. The cost is the same target walk `DayQualityCard` already does for
    /// its own breakdown, times the window — bounded by the selector, and keyed so it runs on a
    /// window/day change rather than per render. Nothing is stored: these are display-only reads over
    /// rows already in memory.
    private func loadInsights() async {
        let history = repo.days
        guard !history.isEmpty else {
            windowBreakdowns = []; browsedBreakdown = nil
            browsedActuals = [:]; browsedTargets = [:]
            return
        }
        let profile = repo.liveTargetsProfile?() ?? UserProfile()

        // The scored days inside the current window, newest-last so the attribution reads in order.
        let cutoff = Calendar.current.date(byAdding: .day, value: -window.days, to: Date())
        let windowDays = scoresByDay.keys.sorted().filter { key in
            guard let cutoff, let d = Self.dayParser.date(from: key) else { return true }
            return d >= cutoff
        }

        let browsed = dayIndex < scoredDays.count ? scoredDays[dayIndex] : nil
        // One target walk covering every day either card needs.
        let wanted = Array(Set(windowDays + (browsed.map { [$0] } ?? [])))
        let needed = DayQualityComputer.targetDaysNeeded(toScore: wanted, history: history)
        let targets = DayQualityComputer.targetsByDay(history: history, profile: profile,
                                                      onlyDays: needed)
        let config = DayQualityPrefs.config

        func input(_ day: String) -> DayQualityScore.DayInput? {
            let water = repo.waterCupsAndTarget(forDay: day)
            return DayQualityComputer.input(for: day, history: history, profile: profile,
                                            targetsByDay: targets,
                                            waterCups: water?.cups,
                                            waterTargetCups: water?.target)
        }

        windowBreakdowns = windowDays.compactMap { input($0).flatMap { DayQualityScore.score($0, config: config) } }

        // The browsed day's actuals and targets, keyed by the SAME component labels the scorer emits —
        // the counterfactual card matches on those, so they have to agree exactly.
        guard let browsed, let i = input(browsed) else {
            browsedBreakdown = nil; browsedActuals = [:]; browsedTargets = [:]
            return
        }
        browsedBreakdown = DayQualityScore.score(i, config: config)
        var actuals: [String: Double] = [:]
        var tgts: [String: Double] = [:]
        if let v = i.steps, let t = i.stepsTarget { actuals["Steps"] = Double(v); tgts["Steps"] = Double(t) }
        if let v = i.kcal, let t = i.kcalTarget { actuals["Calories"] = Double(v); tgts["Calories"] = Double(t) }
        if let v = i.effort, let t = i.effortTarget { actuals["Effort"] = Double(v); tgts["Effort"] = Double(t) }
        if let v = i.waterCups, let t = i.waterTargetCups { actuals["Water"] = Double(v); tgts["Water"] = Double(t) }
        if let v = i.sleepMin, let t = i.sleepNeedMin { actuals["Sleep"] = v; tgts["Sleep"] = Double(t) }
        // HRV and resting HR are deliberately omitted: they are scored against a baseline rather than
        // a target the wearer can decide to hit, so "N more ms of HRV" is not an action. The card is
        // for gains within reach, and an autonomic signal is not one of them.
        browsedActuals = actuals
        browsedTargets = tgts
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE d MMM"); return f
    }()
}
