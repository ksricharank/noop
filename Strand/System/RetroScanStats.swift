import Foundation

/// 260831: what the burst-retrospective stress scan (scanOffloadedRRForStress) costs per day.
///
/// The scan is a new every-completed-sync background step (260830), and the instrumentation
/// doctrine is that an unmeasured recurring cost cannot be attributed from a log after the fact —
/// the frozen-widget report initially could not rule the scan out precisely because nothing
/// measured it. Counts + wall-clock only, day-keyed and persisted like `WidgetPublishStats`
/// (iOS kills/restores the app many times a day, so per-process counters describe only the last
/// half hour). One header line, silent until the scan ever runs. In `Strand/System/` so
/// StrandTests can reach the pure formatter.
@MainActor
enum RetroScanStats {

    private enum K {
        static let day = "rss.day"
        static let runs = "rss.runs"
        static let lastMs = "rss.lastMs"
        static let maxMs = "rss.maxMs"
        // 260903 phase split: the 592-second scan in the 260903-1145 log could not be attributed,
        // because one wall-clock number cannot say WHETHER the time went waiting for the store
        // actor (contending with a re-score's throttled reads) or replaying beats on the CPU.
        // These are the worst observed value of each phase, so one bad scan is still visible after
        // 140 fast ones (a mean would bury it).
        static let maxWaitMs = "rss.maxWaitMs"     // awaiting storeHandle + rrIntervals
        static let maxReplayMs = "rss.maxReplayMs" // the pure detector replay
        static let maxBeats = "rss.maxBeats"       // beats in the worst replay
        static let blockedRuns = "rss.blockedRuns" // scans whose store wait alone exceeded 5 s
    }

    /// A store wait longer than this means the scan was QUEUED, not working — the shape that
    /// produced the 9.9-minute outlier. Counted so a single spike is distinguishable from a
    /// pattern.
    static let blockedWaitThresholdMs = 5_000

    private static var d: UserDefaults { .standard }

    private static var allKeys: [String] {
        [K.runs, K.lastMs, K.maxMs, K.maxWaitMs, K.maxReplayMs, K.maxBeats, K.blockedRuns]
    }

    private static func rollIfNeeded(now: Date) {
        let today = Self.dayKey(now)
        if d.string(forKey: K.day) != today {
            d.set(today, forKey: K.day)
            for k in allKeys { d.set(0, forKey: k) }
        }
    }

    /// One completed scan: `millis` of wall clock, of which `waitMs` was spent awaiting the store
    /// (handle + the R-R read) and `replayMs` replaying `beats` through the detector.
    static func record(millis: Int, waitMs: Int = 0, replayMs: Int = 0, beats: Int = 0,
                       now: Date = Date()) {
        rollIfNeeded(now: now)
        d.set(d.integer(forKey: K.runs) + 1, forKey: K.runs)
        d.set(max(0, millis), forKey: K.lastMs)
        d.set(max(d.integer(forKey: K.maxMs), max(0, millis)), forKey: K.maxMs)
        d.set(max(d.integer(forKey: K.maxWaitMs), max(0, waitMs)), forKey: K.maxWaitMs)
        d.set(max(d.integer(forKey: K.maxReplayMs), max(0, replayMs)), forKey: K.maxReplayMs)
        d.set(max(d.integer(forKey: K.maxBeats), max(0, beats)), forKey: K.maxBeats)
        if waitMs >= blockedWaitThresholdMs {
            d.set(d.integer(forKey: K.blockedRuns) + 1, forKey: K.blockedRuns)
        }
    }

    /// Test seam.
    static func reset() {
        for k in allKeys + [K.day] { d.removeObject(forKey: k) }
    }

    /// One header line, or nothing when the scan never ran (macOS with the feature idle, fresh installs).
    static func summaryLines(now: Date = Date()) -> [String] {
        rollIfNeeded(now: now)
        let runs = d.integer(forKey: K.runs)
        guard runs > 0 else { return [] }
        return [Self.line(runs: runs, lastMs: d.integer(forKey: K.lastMs),
                          maxMs: d.integer(forKey: K.maxMs),
                          maxWaitMs: d.integer(forKey: K.maxWaitMs),
                          maxReplayMs: d.integer(forKey: K.maxReplayMs),
                          maxBeats: d.integer(forKey: K.maxBeats),
                          blockedRuns: d.integer(forKey: K.blockedRuns))]
    }

    /// Pure formatter (pinned by RetroScanStatsTests).
    ///
    /// Reading it: `maxWait` ≫ `maxReplay` means the worst scan was QUEUED behind another store
    /// consumer (a re-score's throttled reads — the 260903 shape), and `blocked` says whether that
    /// was one spike or a pattern. `maxReplay` large with a small wait would mean the detector
    /// itself is the cost, which `maxBeats` then sizes.
    nonisolated static func line(runs: Int, lastMs: Int, maxMs: Int,
                                 maxWaitMs: Int, maxReplayMs: Int, maxBeats: Int,
                                 blockedRuns: Int) -> String {
        "Stress retro-scan today: runs=\(runs) lastMs=\(lastMs) maxMs=\(maxMs) "
            + "maxWait=\(maxWaitMs)ms maxReplay=\(maxReplayMs)ms maxBeats=\(maxBeats) "
            + "blocked=\(blockedRuns)"
    }

    private nonisolated static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
