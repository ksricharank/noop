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
    }

    private static var d: UserDefaults { .standard }

    private static func rollIfNeeded(now: Date) {
        let today = Self.dayKey(now)
        if d.string(forKey: K.day) != today {
            d.set(today, forKey: K.day)
            for k in [K.runs, K.lastMs, K.maxMs] { d.set(0, forKey: k) }
        }
    }

    /// One completed scan took `millis` of wall clock.
    static func record(millis: Int, now: Date = Date()) {
        rollIfNeeded(now: now)
        d.set(d.integer(forKey: K.runs) + 1, forKey: K.runs)
        d.set(max(0, millis), forKey: K.lastMs)
        d.set(max(d.integer(forKey: K.maxMs), max(0, millis)), forKey: K.maxMs)
    }

    /// Test seam.
    static func reset() {
        for k in [K.day, K.runs, K.lastMs, K.maxMs] { d.removeObject(forKey: k) }
    }

    /// One header line, or nothing when the scan never ran (macOS with the feature idle, fresh installs).
    static func summaryLines(now: Date = Date()) -> [String] {
        rollIfNeeded(now: now)
        let runs = d.integer(forKey: K.runs)
        guard runs > 0 else { return [] }
        return [Self.line(runs: runs, lastMs: d.integer(forKey: K.lastMs),
                          maxMs: d.integer(forKey: K.maxMs))]
    }

    /// Pure formatter (pinned by RetroScanStatsTests).
    nonisolated static func line(runs: Int, lastMs: Int, maxMs: Int) -> String {
        "Stress retro-scan today: runs=\(runs) lastMs=\(lastMs) maxMs=\(maxMs)"
    }

    private nonisolated static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
