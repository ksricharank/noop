import Foundation
import StrandAnalytics
import WhoopStore

/// Turns a scored day into a stored `day_quality` point.
///
/// Runs once a night has been scored — the same completion moment the morning brief uses — and
/// upserts the score under the computed device id, so Trends reads it back through the ordinary
/// `exploreSeries` path like Rest or Vitality.
///
/// ## Why it re-derives the targets rather than storing them
///
/// The score is only meaningful against the targets the day actually set, and those are a function
/// of that morning's charge, readiness read and profile — not of anything stored per-day. Rather
/// than persist a parallel copy of every target (which would drift from what the app displayed the
/// moment either formula changed), this calls the SAME `Repository.liveTargets` the Today strip and
/// the widgets call, with `todayKey` pointed at the day being scored.
///
/// That is what makes the grade honest: the number the score divides by is the number the wearer was
/// shown. It also means one formula change moves both, which is the property a parallel copy loses.
///
/// Pure static functions over injected values — no store — so the day-selection logic and the input
/// assembly are testable without a database.
///
/// `@MainActor` because `Repository.liveTargets` is: it is a pure static function, but it lives on
/// the main-actor-isolated `Repository`. That is the right constraint to inherit rather than work
/// around — the alternative would be a second copy of the target formulas reachable off the main
/// actor, which is exactly the drift this type exists to avoid. The engine's scoring loop is
/// nonisolated, so the caller hops once per pass and hands the results back; the walk is bounded to
/// the days being scored precisely so that hop is cheap.
@MainActor
enum DayQualityComputer {

    /// The metric-series key. Read back via `exploreSeries(key:source:)`.
    static let metricKey = "day_quality"

    /// How many days of history the load factor's "recent average target" is drawn from.
    ///
    /// 14 rather than 30: the factor asks "was this day demanding *for me lately*", and a fortnight
    /// tracks a training block. A 30-day window would still be averaging in a block the wearer has
    /// already moved on from.
    static let recentTargetWindowDays = 14

    /// Assemble one day's scorer input from the stored rows.
    ///
    /// `day` is the day being graded; `history` must contain it plus enough preceding days for the
    /// baselines (the caller passes the engine's full working set). Returns nil when the day has no
    /// row at all — there is nothing to grade, which is different from a day that scored badly.
    /// `targetsByDay` comes from `targetsByDay(history:profile:)`, built ONCE by the caller and
    /// reused across every day being scored — see that function on why it is not derived here.
    /// The day AFTER `day`, as a `yyyy-MM-dd` key — the row that carries the night CONCLUDING `day`.
    ///
    /// 260906, maintainer: "the day quality score seems to use yesterday night's sleep instead of
    /// tonight's sleep (which I count as part of yesterday — i.e., the sleep is the conclusion of the
    /// day)". Correct, and the mismatch was real: a sleep session is attributed to the day its END
    /// falls on (`AnalyticsEngine.analyzeDay`), so row D holds the night D-1→D — the night that
    /// PRECEDED day D's waking hours. Grading day D's steps/effort/calories against that night graded
    /// the work against the sleep that came before it.
    ///
    /// Nil when the key cannot be parsed, which fails the recovery half closed (absent, not wrong).
    static func nextDayKey(_ day: String) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: day),
              let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: d) else {
            return nil
        }
        return f.string(from: next)
    }

    static func input(for day: String,
                      history: [DailyMetric],
                      profile: UserProfile,
                      targetsByDay: [String: Int],
                      waterCups: Int?,
                      waterTargetCups: Int?) -> DayQualityScore.DayInput? {
        guard let row = history.last(where: { $0.day == day }) else { return nil }
        // The recovery half reads the CONCLUDING night — sleep, HRV and resting HR together, because
        // all three are measured during that same night. Splitting them across two nights would make
        // the half incoherent: it would grade the sleep after the day against the autonomic response
        // to the day before it.
        //
        // Nil when tomorrow's row has not landed yet. Every recovery component then reports ABSENT
        // and the weights renormalise over the execution half (the scorer's rule 2), rather than the
        // day being scored against the wrong night.
        let nightRow = nextDayKey(day).flatMap { key in history.last(where: { $0.day == key }) }

        // The targets AS THE DAY SET THEM. `liveTargets` reads the trailing history for its
        // readiness evaluation, so the slice must END at the day being graded — feeding it the full
        // history would grade a past day against a readiness read that includes days after it.
        let upToDay = history.filter { $0.day <= day }
        let charge = row.recovery.map { Int($0.rounded()) }
        let restScore = restScoreFor(day: day, history: upToDay)
        let targets = Repository.liveTargets(days: upToDay, charge: charge, restScore: restScore,
                                             profile: profile, todayKey: day,
                                             waterTodayML: nil, waterEnabled: false)

        // Baselines for the autonomic half: the wearer's own recent central tendency, EXCLUDING the
        // night being graded so a night cannot be its own yardstick (which would flatten every score
        // to the baseline value and make the whole recovery half inert).
        //
        // `< day` is what does that, and it still does after the 260906 shift: the graded night now
        // lives on row `day + 1`, which this bound excludes along with the day itself. Note the
        // baseline window and the graded night are deliberately drawn from DIFFERENT rows now — the
        // baseline is every night up to and including the one that opened the day, the graded value
        // is the one that closed it.
        let prior = upToDay.filter { $0.day < day }
        let hrvBaseline = median(prior.compactMap { $0.avgHrv })
        let rhrBaseline = median(prior.compactMap { $0.restingHr }.map(Double.init))

        return DayQualityScore.DayInput(
            steps: row.steps,
            stepsTarget: targets.stepsTarget,
            kcal: row.activeKcalEst.map { Int($0.rounded()) },
            kcalTarget: targets.kcalTargetKcal,
            effort: row.strain.map { Int($0.rounded()) },
            effortTarget: targets.effortTarget,
            waterCups: waterCups,
            waterTargetCups: waterTargetCups,
            sleepMin: nightRow?.totalSleepMin,
            sleepNeedMin: targets.sleepNeedTonightMin,
            hrv: nightRow?.avgHrv,
            hrvBaseline: hrvBaseline,
            restingHr: nightRow?.restingHr,
            restingHrBaseline: rhrBaseline,
            recentAvgEffortTarget: recentAvgEffortTarget(before: day, targetsByDay: targetsByDay)
        )
    }

    /// Mean of the effort TARGETS over the trailing window — the load factor's yardstick.
    ///
    /// Takes a PRE-BUILT table rather than re-deriving, and that is a performance requirement, not a
    /// style choice. `Repository.liveTargets` runs `ReadinessEngine.evaluate`, which sorts the whole
    /// history; its memo is keyed on a fingerprint of the exact row set it was handed, with capacity
    /// 16. Deriving a target per day from a per-day history SLICE therefore misses the cache every
    /// time and thrashes it — a full-history sort per day of the window, per day scored, on a
    /// background pass. `targetsByDay` computes each day once in a single ascending walk.
    ///
    /// Nil when the window holds too little to average, which leaves the load factor inert rather
    /// than guessing. Three days is the floor: below that a "recent average" is one or two days
    /// wearing a mean, and the factor would swing on a single outlier.
    static func recentAvgEffortTarget(before day: String, targetsByDay: [String: Int]) -> Double? {
        let window = targetsByDay.keys.filter { $0 < day }.sorted().suffix(recentTargetWindowDays)
        guard window.count >= 3 else { return nil }
        let targets = window.compactMap { targetsByDay[$0] }.map(Double.init)
        guard !targets.isEmpty else { return nil }
        return targets.reduce(0, +) / Double(targets.count)
    }

    /// Every day's effort target, computed in ONE ascending pass over the history.
    ///
    /// The history is sorted once and the slice grows by one row per step, so `liveTargets` is
    /// called exactly once per day rather than once per (day, window-member) pair. This is the only
    /// place that walks the history for targets; both the score and the load factor read the result.
    /// Bounded by `onlyDays` so the walk is proportional to what is being scored, not to the whole
    /// history: a wearer with two years of rows must not pay a per-row `liveTargets` call every
    /// night. The slice handed to `liveTargets` still ENDS at the day being priced (readiness must
    /// not see the future), and still starts at the beginning of history, because the readiness read
    /// legitimately draws on the trailing baselines.
    static func targetsByDay(history: [DailyMetric], profile: UserProfile,
                             onlyDays: Set<String>) -> [String: Int] {
        guard !onlyDays.isEmpty else { return [:] }
        let sorted = history.sorted { $0.day < $1.day }
        var out: [String: Int] = [:]
        for i in sorted.indices where onlyDays.contains(sorted[i].day) {
            let upTo = Array(sorted[...i])
            let row = sorted[i]
            let t = Repository.liveTargets(days: upTo,
                                           charge: row.recovery.map { Int($0.rounded()) },
                                           restScore: restScoreFor(day: row.day, history: upTo),
                                           profile: profile, todayKey: row.day)
            if let target = t.effortTarget { out[row.day] = target }
        }
        return out
    }

    /// The days `targetsByDay` must price to score `days`: each of them, plus the trailing window
    /// each one's load factor averages over.
    static func targetDaysNeeded(toScore days: [String], history: [DailyMetric]) -> Set<String> {
        let all = history.map(\.day).sorted()
        var needed = Set(days)
        for day in days {
            let prior = all.filter { $0 < day }.suffix(recentTargetWindowDays)
            needed.formUnion(prior)
        }
        return needed
    }

    /// Rest score for a day, from the stored efficiency composite when present.
    ///
    /// `liveTargets` uses it only to shade the sleep need, so a nil here costs a small adjustment
    /// rather than the target — which is why it is derived cheaply from the row rather than pulling
    /// the whole `sleep_performance` series into this path.
    static func restScoreFor(day: String, history: [DailyMetric]) -> Int? {
        guard let row = history.last(where: { $0.day == day }), let eff = row.efficiency else {
            return nil
        }
        // Efficiency is stored as either a fraction or a percentage depending on the import path
        // (#949's bimodality, same as the coach context's skin temp). Normalise before rounding.
        let pct = eff > 1.5 ? eff : eff * 100
        guard pct > 0, pct <= 100 else { return nil }
        return Int(pct.rounded())
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    /// Which days to score on this pass: the finished days that DON'T already have a score.
    ///
    /// Only days STRICTLY BEFORE today: the score is a closed book about a finished day, and a
    /// partial today would publish a low number at breakfast and revise it by bedtime — the exact
    /// churn the "computed at the end of a night" requirement exists to avoid.
    ///
    /// INCREMENTAL (260904, maintainer: "I don't want the backfill to run every day. it should just
    /// be a one time thing… and then a new score is computed each day?"). Exactly that: the first
    /// pass finds every finished day unscored and backfills the history; from then on it finds one
    /// new day per day. `alreadyScored` is the set of days the stored series already holds.
    ///
    /// Re-scoring everything was the previous behaviour, and while the once-per-day latch kept it
    /// off the hot path, it still re-derived months of targets nightly for values that cannot change
    /// — a finished day's inputs are fixed. The one case that DOES need a full re-score is a config
    /// change, and that is handled where it belongs: `rescoreAll` forces it, driven by the latch's
    /// config fingerprint rather than by re-deriving unconditionally.
    /// 260906: a day is scorable only once the night that CONCLUDES it has landed — that night lives
    /// on the FOLLOWING day's row, so `day + 1` must be present in the history. In practice the newest
    /// score is therefore the day before yesterday rather than yesterday, which is the accepted cost of
    /// grading a day against the sleep that closed it (maintainer's call: publish complete, not early).
    ///
    /// This keeps the scorer's rule 3 intact — nothing is published until it is complete — rather than
    /// emitting a recovery-less score at breakfast and revising it the next morning. A day whose
    /// concluding night never arrives (the strap was off) simply stays unscored until it does; it is
    /// not scored on execution alone, because a score missing half its inputs is not comparable with
    /// the series around it.
    static func daysToScore(scoredDays: [String], todayKey: String,
                            alreadyScored: Set<String> = [], rescoreAll: Bool = false) -> [String] {
        let available = Set(scoredDays)
        let finished = available.filter { day in
            guard day < todayKey else { return false }
            guard let next = nextDayKey(day) else { return false }
            return available.contains(next)
        }
        return (rescoreAll ? finished : finished.subtracting(alreadyScored)).sorted()
    }
}
