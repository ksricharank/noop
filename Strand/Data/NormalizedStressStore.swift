import Foundation
import Combine
import WhoopProtocol
import StrandAnalytics

/// Keeps NSS (the Normalized Stress Score, `NormalizedStress`) current, and is the ONE place every
/// surface reads it from: the Stress tab's NSS card, the Today "Stress" card, and the coach's NSS block.
/// One resolver, one clock, so the three can never show different numbers for the same moment.
///
/// CADENCE (maintainer, 261024: "the stress score should update … whenever each light pass runs"):
/// `update` rides the post-offload QUICK pass (`AppModel`, inside the same background assertion), so
/// NSS moves on the strap's sync cadence. Foreground surfaces call `updateIfStale`, which is a no-op
/// within `staleAfter` of the last update. Both are incremental and cheap:
/// - TODAY: 1-minute-stepped windows (each still 5 minutes of data), appended from the last computed
///   window onward. The last five minutes are recomputed every time, so a window that was scored on
///   partial data before a sync landed is scored again on the full five minutes.
/// - HISTORY (the personal model): 5-minute windows per past day, waking hours 06:00–22:00, computed
///   ONCE per day and kept on disk. A fresh install fills its 14 days `backfillDays` at a time (1 in the
///   background, 2 in the foreground), so the one-time cost is spread over the first updates rather than
///   paid in one background wake. Until a pace has an hour of history it is simply unscored.
///
/// Persisted to Application Support (`nss-v1.json`): window features only (pace, mean HR, ln SI, ln
/// RMSSD), never raw samples, never in a backup — it is rebuilt from the raw streams if lost.
@MainActor
final class NormalizedStressStore: ObservableObject {

    static let shared = NormalizedStressStore()

    /// What every surface shows, resolved once per update.
    struct Snapshot: Equatable {
        /// The newest reading today, or nil (nothing scored yet today, or the model is still learning).
        var current: NormalizedStress.Reading?
        /// Today's readings, oldest first (1-minute steps).
        var readings: [NormalizedStress.Reading]
        /// Mean NSS over today's readings.
        var dayMean: Double?
        /// Today's most recent high episode.
        var lastHigh: NormalizedStress.Episode?
        /// How much history the model learned from.
        var modelDays: Int
        var modelWindows: Int
        var modelledPaces: [NormalizedStress.Pace]
        /// Wall-clock second this snapshot was computed.
        var computedAt: Int
        /// The newest window today when it is NEWER than `current` and could not be scored (running, or
        /// a pace with too little history) — so "now" can say why it is showing an older reading.
        var unscoredNow: NormalizedStress.Window?
        /// Daily average NSS by "yyyy-MM-dd", today included — the Stress tab's trend, the Markers
        /// sparkline and the Insights tab's NSS trend all read this one map (261024b).
        var dailyByDay: [String: Double] = [:]

        static let empty = Snapshot(current: nil, readings: [], dayMean: nil, lastHigh: nil,
                                    modelDays: 0, modelWindows: 0, modelledPaces: [], computedAt: 0,
                                    unscoredNow: nil)
    }

    @Published private(set) var snapshot: Snapshot = .empty

    /// Waking hours for the model and for today (the same 06:00–22:00 as `DaytimeStress`).
    static let wakingStartHour = 6
    static let wakingEndHour = 22
    /// A foreground surface re-reads only when the last update is older than this.
    static let staleAfter: TimeInterval = 240

    private struct Persisted: Codable {
        var version = 1
        /// Past days' 5-minute windows, keyed "yyyy-MM-dd". An EMPTY array marks a day already read that
        /// had nothing, so it is not read again.
        var history: [String: [NormalizedStress.Window]] = [:]
        var todayKey = ""
        var today: [NormalizedStress.Window] = []
        /// 261024b: daily average NSS, kept for `dailyHistoryDays` — longer than the 14-day window
        /// history, so a trend outlives the windows it was scored from. Optional so a file written
        /// before it existed still decodes.
        var daily: [String: Double]?
    }

    /// How long daily averages are kept for the trends.
    static let dailyHistoryDays = 400

    private var state: Persisted?
    private var running = false
    private var lastUpdate: Date?

    private init() {}

    /// Update unless one ran within `staleAfter`.
    func updateIfStale(repo: Repository, log: ((String) -> Void)? = nil) async {
        if let last = lastUpdate, Date().timeIntervalSince(last) < Self.staleAfter { return }
        await update(repo: repo, backfillDays: 2, log: log)
    }

    /// Bring today's windows and the model up to date, then publish a new snapshot.
    func update(repo: Repository, backfillDays: Int, log: ((String) -> Void)? = nil) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let started = Date()
        let cal = Calendar.current
        let now = Date()
        let nowTs = Int(now.timeIntervalSince1970)
        let startOfToday = cal.startOfDay(for: now)
        var st = state ?? Self.load() ?? Persisted()

        let todayKey = Repository.localDayKey(now)
        if st.todayKey != todayKey {
            st.todayKey = todayKey
            st.today = []
        }

        // History: fill missing past days, a few per update.
        var filled = 0
        for back in 1...NormalizedStress.modelDays where filled < backfillDays {
            guard let date = cal.date(byAdding: .day, value: -back, to: startOfToday) else { continue }
            let key = Repository.localDayKey(date)
            guard st.history[key] == nil else { continue }
            let from = Int(date.timeIntervalSince1970) + Self.wakingStartHour * 3600
            let to = Int(date.timeIntervalSince1970) + Self.wakingEndHour * 3600
            st.history[key] = await Self.windows(repo: repo, readFrom: from - NormalizedStress.windowSeconds,
                                                 from: from, to: to, step: NormalizedStress.windowSeconds)
            filled += 1
        }
        let keep = Set((1...NormalizedStress.modelDays).compactMap {
            cal.date(byAdding: .day, value: -$0, to: startOfToday).map(Repository.localDayKey)
        })
        st.history = st.history.filter { keep.contains($0.key) }

        // Today: recompute the last five minutes, append the rest.
        let wakeTs = Int(startOfToday.timeIntervalSince1970) + Self.wakingStartHour * 3600
        let nowMinute = nowTs / 60 * 60
        let resumeFrom = max(wakeTs, (st.today.last?.endTs ?? wakeTs) - NormalizedStress.windowSeconds)
        var added = 0
        if nowMinute > resumeFrom {
            st.today.removeAll { $0.endTs > resumeFrom }
            let fresh = await Self.windows(repo: repo, readFrom: resumeFrom - NormalizedStress.windowSeconds,
                                           from: resumeFrom, to: nowMinute, step: 60)
            added = fresh.count
            st.today += fresh
        }

        // Model and readings.
        let historyDays = st.history.values.filter { !$0.isEmpty }
        let model = NormalizedStress.buildModel(historyDays.flatMap { $0 }, days: historyDays.count)
        let readings = NormalizedStress.readings(st.today, model: model)

        // Daily averages: the 14 history days re-scored against today's model every update (their
        // 5-minute windows, unsmoothed — the mean of an EMA and of its inputs agree), so the days a
        // trend compares share one model; today from its live readings. A day older than the window
        // history keeps the last average it was given.
        var daily = st.daily ?? [:]
        for (key, ws) in st.history where !ws.isEmpty {
            let scores = ws.compactMap { NormalizedStress.score($0, model: model)?.raw }
            if !scores.isEmpty { daily[key] = scores.reduce(0, +) / Double(scores.count) }
        }
        let todayMean = readings.isEmpty ? nil : readings.map(\.nss).reduce(0, +) / Double(readings.count)
        if let todayMean { daily[todayKey] = todayMean }
        if let cutoff = cal.date(byAdding: .day, value: -Self.dailyHistoryDays, to: startOfToday) {
            let cutoffKey = Repository.localDayKey(cutoff)
            daily = daily.filter { $0.key >= cutoffKey }
        }
        st.daily = daily
        snapshot = Snapshot(
            current: readings.last,
            readings: readings,
            dayMean: todayMean,
            lastHigh: NormalizedStress.lastHighEpisode(readings),
            modelDays: model.days, modelWindows: model.windowCount,
            modelledPaces: model.paces.map(\.pace), computedAt: nowTs,
            unscoredNow: st.today.last.flatMap { w in
                w.endTs > (readings.last?.ts ?? Int.min) ? w : nil
            },
            dailyByDay: daily)
        state = st
        lastUpdate = Date()
        Self.save(st)
        log?(Self.logLine(snapshot, added: added, backfilled: filled,
                          ms: Int(Date().timeIntervalSince(started) * 1000), now: nowTs))
    }

    /// The `nss:` strap-log line — the validation record the engine's doc asks for: what was scored,
    /// against how much history, and what it cost.
    nonisolated static func logLine(_ s: Snapshot, added: Int, backfilled: Int, ms: Int, now: Int) -> String {
        let model = "model \(s.modelDays)d/\(s.modelWindows) windows ("
            + (s.modelledPaces.isEmpty ? "no pace yet" : s.modelledPaces.map(\.rawValue).joined(separator: ","))
            + ")"
        let cost = "today +\(added) window(s) · backfilled \(backfilled) day(s) · \(ms) ms"
        guard let c = s.current else { return "nss: no reading · \(model) · \(cost)" }
        func z(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
        return "nss: now \(Int(c.nss.rounded())) (raw \(Int(c.raw.rounded())), \(c.pace.rawValue), "
            + "\(max(0, (now - c.ts) / 60)) min old, hr \(Int(c.hr.rounded())) vs \(Int(c.hrPred.rounded())) usual, "
            + "zHR \(z(c.zHR)) zSI \(z(c.zSI)) zRMSSD \(z(c.zRMSSD)))"
            + " · day \(s.dayMean.map { "\(Int($0.rounded()))" } ?? "—") over \(s.readings.count) min"
            + " · \(model) · \(cost)"
    }

    // MARK: - Reads

    /// Windows ending on every `step` boundary in `(from, to]`, from streams read over `[readFrom, to]`.
    private static func windows(repo: Repository, readFrom: Int, from: Int, to: Int,
                                step: Int) async -> [NormalizedStress.Window] {
        let span = max(0, to - readFrom)
        let hr = await repo.hrSamples(from: readFrom, to: to, limit: span + 600)
        guard hr.count >= NormalizedStress.minWindowHRSamples else { return [] }
        let rr = await repo.rrIntervals(from: readFrom, to: to, limit: span * 3 + 600)
        let steps = await repo.recentStepSamples(from: readFrom, to: to)
        let gravity = await repo.gravitySamplesUnion(from: readFrom, to: to)
        // Pure, store-free work: off the main actor, at a priority that yields to the UI.
        return await runUnescalated {
            NormalizedStress.windows(from: from, to: to, stepSeconds: step,
                                     hr: hr, rr: rr, steps: steps, gravity: gravity)
        }
    }

    // MARK: - Persistence

    private static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nss-v1.json")
    }

    private static func load() -> Persisted? {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(Persisted.self, from: data), p.version == 1 else { return nil }
        return p
    }

    private static func save(_ p: Persisted) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
