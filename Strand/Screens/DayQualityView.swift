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
        // Read, then verify the stored series against what the scorer produces NOW (260909).
        //
        // Everything below the score card — the trend chart, the week summary, the calendar strip and
        // the streaks — reads this stored series, while the card itself re-scores the browsed day
        // live. After a formula change those two disagree, which is exactly what was reported three
        // times: a correct current day above a chart of values from a retired formula.
        //
        // Two earlier attempts failed, both because they asked an INDIRECT question. The first gated
        // on `DayQualityPrefs.configChanged` — a latch that records a pass RAN, not that the values
        // are current. The second guessed from the shape of the series, and its 20-day threshold sat
        // above the real 14-day window while a single negative day defeated its other test.
        //
        // This asks the question directly: re-score the days and compare. The comparison cannot go
        // stale, cannot be defeated by the data happening to look plausible, and needs no threshold.
        var byDay = await readSeries()
        if let disagreement = await liveScoresForRepairCheck(stored: byDay),
           Self.storedDisagreesWithLive(stored: byDay, live: disagreement) {
            await appModel.intelligence.rescoreDayQualityNow(force: true)
            byDay = await readSeries()
        }
        scoresByDay = byDay
        if dayIndex > max(byDay.count - 1, 0) { dayIndex = 0 }
    }

    /// Re-score the stored days to compare against, or nil when there is nothing to check.
    ///
    /// Bounded to the most recent `repairCheckDays` scored days rather than the whole history: the
    /// check only needs to find ONE disagreement to trigger a full forced re-score, so walking
    /// further is wasted work on a path that runs when the tab opens.
    private func liveScoresForRepairCheck(stored: [String: Double]) async -> [String: Int]? {
        let history = repo.days
        guard !history.isEmpty, !stored.isEmpty else { return nil }
        let recent = Array(stored.keys.sorted().suffix(Self.repairCheckDays))
        guard !recent.isEmpty else { return nil }
        let profile = repo.liveTargetsProfile?() ?? UserProfile()
        let needed = DayQualityComputer.targetDaysNeeded(toScore: recent, history: history)
        let targets = DayQualityComputer.targetsByDay(history: history, profile: profile,
                                                      onlyDays: needed)
        let config = DayQualityPrefs.config
        var out: [String: Int] = [:]
        for day in recent {
            let water = repo.waterCupsAndTarget(forDay: day)
            guard let input = DayQualityComputer.input(for: day, history: history, profile: profile,
                                                       targetsByDay: targets,
                                                       waterCups: water?.cups,
                                                       waterTargetCups: water?.target),
                  let scored = DayQualityScore.score(input, config: config) else { continue }
            out[day] = scored.total
        }
        return out.isEmpty ? nil : out
    }

    /// How many recent days the repair check re-scores. Small on purpose — one disagreement is enough
    /// to trigger the full re-derivation, so this is a detector, not the repair itself.
    static let repairCheckDays = 5

    private func readSeries() async -> [String: Double] {
        let series = await repo.exploreSeries(key: DayQualityComputer.metricKey, source: "my-whoop")
        var byDay: [String: Double] = [:]
        for p in series { byDay[p.day] = p.value }
        return byDay
    }

    /// True when a stored score DISAGREES with what the current scorer produces for the same day.
    ///
    /// This replaced a heuristic that never fired on the reported data (260909), and the failure is
    /// worth recording because the shape of it is instructive. The heuristic asked whether the series
    /// "looked like" an old scale — nothing at or below zero across 20+ days, or a value out of range
    /// — and it was tested against a 25-day synthetic fixture. The real series was 14 days, under the
    /// gate, and contained one negative day, which defeated the other tell. So it was green on a
    /// fixture I invented and silent on the data it existed for.
    ///
    /// The direct comparison has no such gap: re-score the day and see whether the stored number
    /// matches. That is not a guess about provenance, it is the actual question — and the view
    /// already computes these breakdowns for the Insights cards, so it costs nothing extra.
    ///
    /// Tolerance is 1 point, for rounding only. Anything larger means the stored value came from a
    /// different formula, a different config, or a different anchor — all of which are reasons to
    /// rewrite it.
    static func storedDisagreesWithLive(stored: [String: Double],
                                        live: [String: Int]) -> Bool {
        for (day, liveValue) in live {
            guard let storedValue = stored[day] else { continue }
            if abs(storedValue - Double(liveValue)) > 1.0 { return true }
        }
        return false
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
