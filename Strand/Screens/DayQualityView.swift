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

    /// Stored series, "yyyy-MM-dd" → score. Loaded here rather than passed in so the screen stands on
    /// its own as a tab root (Trends loads its own copy for the chart it still draws).
    @State private var scoresByDay: [String: Double] = [:]
    /// Index back through the SCORED days, newest first. 0 = the most recent scored day.
    @State private var dayIndex = 0
    /// Which window the trend section covers. Local to this screen — the Trends page has its own
    /// selector, and sharing one across two screens would make each surprise the other.
    @State private var window = Self.windows[1]

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
            navHeader
            // The score itself, the breakdown and the narrative — the existing card, pointed at the
            // browsed day.
            DayQualityCard(scoresByDay: scoresByDay, dayIndex: dayIndex)
            // The trend section carries the window selector, the chart, the week-in-review and the
            // calendar strip — all of it shared with the Sleep tab so the two cannot drift.
            ScoreTrendSection(title: "Day quality trend", valuesByDay: scoresByDay,
                              windows: Self.windows, window: $window,
                              // The signed range, explicitly: the section defaults to the 0…106 rest
                              // scale, which would fold the whole negative half onto the chart's floor.
                              valueRange: Double(DayQualityScore.publishedMinimum)
                                  ... Double(DayQualityScore.publishedMaximum),
                              showsBars: true,
                              lowLabel: "Depleted", highLabel: "Excellent")
            DayQualitySettingsCard()
        }
        .task(id: repo.days.count) { await load() }
        // A reload can shorten the series while the screen is open; an index left past the end would
        // silently clamp to a different day than the header names. Snap back, like SleepView does.
        .onChangeCompat(of: scoresByDay.count) { _ in
            if dayIndex > lastIndex { dayIndex = 0 }
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
        let series = await repo.exploreSeries(key: DayQualityComputer.metricKey, source: "my-whoop")
        var byDay: [String: Double] = [:]
        for p in series { byDay[p.day] = p.value }
        scoresByDay = byDay
        if dayIndex > max(byDay.count - 1, 0) { dayIndex = 0 }
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE d MMM"); return f
    }()
}
