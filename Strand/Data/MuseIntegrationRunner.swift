import Foundation
import WhoopStore
import StrandAnalytics

// MARK: - Gathering and running the integration digest (260920)
//
// `MuseIntegration` is pure: preferences, the cadence rule, the digest text and the file write.
// This is the part that needs the Repository, kept separate so none of that has to be mocked to
// test the parts that decide WHAT gets written.
@MainActor
enum MuseIntegrationRunner {

    /// Gather the last 24 hours and write the digest, if a destination is configured.
    ///
    /// Returns the URL written, or nil when there was nothing to do (disabled, no folder). Throws
    /// only on a real write failure — a missing day or an unscored recap is a normal state the
    /// digest reports in words, not an error.
    @discardableResult
    static func run(repo: Repository,
                    coach: AICoachEngine? = nil,
                    now: Date = Date()) async throws -> URL? {
        guard MuseIntegration.isEnabled, MuseIntegration.hasFolder else { return nil }
        let input = await gather(repo: repo, coach: coach, now: now)
        return try MuseIntegration.write(MuseIntegration.digest(input, generatedAt: now), now: now)
    }

    /// Write regardless of cadence — the "Generate now" button. Same content, same path.
    @discardableResult
    static func runNow(repo: Repository,
                       coach: AICoachEngine? = nil,
                       now: Date = Date()) async throws -> URL {
        let input = await gather(repo: repo, coach: coach, now: now)
        return try MuseIntegration.write(MuseIntegration.digest(input, generatedAt: now), now: now)
    }

    /// Run only if the configured hour has passed and today's digest has not been written.
    /// Called on app foreground; silent on every failure, because a background chore must never
    /// surface an error over whatever the wearer actually opened the app to do. The failure is
    /// recorded in `MuseIntegration.lastError` and shown on the settings screen.
    static func runIfDue(repo: Repository, coach: AICoachEngine? = nil, now: Date = Date()) async {
        guard MuseIntegration.isEnabled, MuseIntegration.hasFolder else { return }
        guard MuseIntegration.isDue(now: now,
                                    lastWrittenMs: MuseIntegration.lastWrittenMs,
                                    hourOfDay: MuseIntegration.hourOfDay,
                                    intervalHours: MuseIntegration.intervalHours) else { return }
        _ = try? await run(repo: repo, coach: coach, now: now)
    }

    // MARK: Gathering

    /// Assemble the digest's inputs from the store.
    ///
    /// The day boundaries matter and are easy to get wrong, so they are stated here once:
    ///   - `todayDay` is the local day the digest is being written on.
    ///   - `recapDay` is the day BEFORE that — the finished day the Recap tab grades.
    ///   - the night row is the one keyed by `todayDay`, because a sleep session is attributed to
    ///     the day it ENDED on. That is the night that concluded `recapDay`, which is exactly the
    ///     relationship `DayQualityComputer.nextDayKey` encodes for scoring.
    static func gather(repo: Repository,
                       coach: AICoachEngine?,
                       now: Date) async -> MuseIntegration.Input {
        let todayDay = Repository.localDayKey(now)
        let recapDay = DayQualityComputer.previousDayKey(todayDay) ?? todayDay

        let history = repo.days
        let todayMetric = history.last(where: { $0.day == todayDay })
        let recapMetric = history.last(where: { $0.day == recapDay })
        // The night that CONCLUDED the recap day is keyed by the following morning.
        let nightMetric = history.last(where: { $0.day == todayDay })

        // Score the recap day the same way the Recap tab does, so the digest and the screen can
        // never disagree about a grade.
        let profile = repo.liveTargetsProfile?() ?? UserProfile()
        let needed = DayQualityComputer.targetDaysNeeded(toScore: [recapDay], history: history)
        let targets = DayQualityComputer.targetsByDay(history: history, profile: profile,
                                                      onlyDays: needed)
        let water = repo.waterCupsAndTarget(forDay: recapDay)
        let scoreInput = DayQualityComputer.input(for: recapDay, history: history, profile: profile,
                                                  targetsByDay: targets,
                                                  waterCups: water?.cups,
                                                  waterTargetCups: water?.target)
        let recapScore = scoreInput.flatMap { DayQualityScore.score($0, config: DayQualityPrefs.config) }

        var input = MuseIntegration.Input(recapDay: recapDay,
                                          recapScore: recapScore,
                                          recapMetric: recapMetric,
                                          nightMetric: nightMetric,
                                          todayMetric: todayMetric,
                                          todayDay: todayDay)

        // Today's four target pairs, exactly as the Today strip and the widgets read them.
        input.todayTargets = repo.liveTargets(forDay: todayDay)
        // Water for the recap day — `LiveTargets` only carries today's.
        input.recapWaterCups = water?.cups
        input.recapWaterTargetCups = water?.target
        // The trailing 30 days for the "my normal range" block. Bounded deliberately: the digest is
        // meant to stay small, and a mean over a month is the comparison a reader actually wants.
        input.recentDays = Array(history.suffix(30))
        // The stored day-quality series, so yesterday's grade can be read against its own run.
        let qualitySeries = await repo.exploreSeries(key: DayQualityComputer.metricKey,
                                                     source: "my-whoop")
        input.recentQualityScores = Dictionary(qualitySeries.map { ($0.day, $0.value) },
                                               uniquingKeysWith: { _, last in last })
        // Training load / sleep debt / baseline z-scores, over a window wide enough for the
        // 42-day chronic term to mean anything. `derivedTrendsBlock` is nonisolated and pure, and
        // self-hedges when the history is thin.
        let trendWindow = Array(history.suffix(90))
        let derived = AICoachEngine.derivedTrendsBlock(days: trendWindow)
        input.derivedTrends = derived.isEmpty ? nil : derived

        // Coach narratives are OPT-IN: each is a provider call, and the digest is useful without
        // them. When they fail they are simply absent — a digest missing a paragraph is fine, a
        // digest that failed to write because a provider was down is not.
        if MuseIntegration.includesCoachNarratives, let coach {
            if let s = recapScore {
                input.coachRecap = await coach.dayQualityNarrative(day: recapDay, score: s)
            }
            if let n = nightMetric {
                input.coachSleep = await coach.sleepNarrative(night: n)
            }
        }
        return input
    }
}
