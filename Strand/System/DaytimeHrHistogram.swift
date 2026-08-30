import Foundation

/// Personal daytime heart-rate histogram — what the calm ceiling is derived FROM (260830).
///
/// The first calm ceiling was "nightly resting-HR median + 25 bpm", and the fixed margin was the
/// weak link: 25 is a guess, identical for everyone, deaf to how THIS user's heart actually spends
/// its days. The strap already streams every daytime beat through `AppModel.ingestHR`, so the
/// ceiling can be read off the user's own distribution instead: bank each accepted daytime sample
/// into a per-bpm histogram, and the ceiling is the 85th percentile of the last week's beats —
/// "elevated" then means "above the level you spend 85% of your waking hours under", no invented
/// margin, self-recalibrating as the week rolls. The RHR+margin form survives only as the
/// cold-start fallback until an hour of daytime beats exists.
///
/// BatteryDiag's counter idiom on purpose: one integer increment per event it measures (the ~1–3 Hz
/// live tick the app is already processing), an in-memory bucket merged into UserDefaults every few
/// minutes, per-local-day keys pruned to the trailing week. Counts only — no timestamps beyond the
/// day key, no payloads. Known limit, stated: only LIVE ticks feed it, so under the -1 duty cycle
/// (stream silenced while locked in daytime) the histogram thins and the fallback carries more days;
/// on any +N / 0 setting the stream is continuous and the histogram is dense.
///
/// In `Strand/` (shared target) so StrandTests can pin the pure math.
@MainActor
enum DaytimeHrHistogram {

    /// Percentile of the week's daytime beats the ceiling sits at.
    static let ceilingPercentile = 0.85
    /// Days of histogram retained (and read) — the week the ceiling describes.
    static let keepDays = 7
    /// Minimum banked beats before the histogram speaks (~1 h of 1 Hz daytime streaming). Below it
    /// the ceiling is nil and the caller falls back — never a percentile of twenty samples.
    static let minSamples = 3600
    /// Sanity clamp on the derived ceiling — wider than the old fallback's (the histogram has real
    /// evidence), but a corrupted store must still not produce a 40 or a 180.
    static let ceilingRange = 65...115
    /// Merge the in-memory bucket into UserDefaults every this many new samples (~2–5 min at live
    /// cadence) — frequent enough that a process kill loses minutes, cheap enough to be free.
    static let flushEvery = 300

    private static let persistKey = "noop.daytimeHr.days"
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Today's not-yet-persisted counts (bpm → count), and the day they belong to. A day roll (or a
    /// process death) is handled by flushing on the roll and merging on read.
    private static var unflushed: [Int: Int] = [:]
    private static var unflushedDay: String?
    private static var sinceFlush = 0

    /// Bank one accepted daytime beat. The caller owns the gates (plausible value, outside the
    /// sleep window) — this only counts.
    static func record(bpm: Int, now: Date = Date()) {
        let day = dayFormatter.string(from: now)
        if let current = unflushedDay, current != day { flush(now: now) }
        unflushedDay = day
        unflushed[bpm, default: 0] += 1
        sinceFlush += 1
        if sinceFlush >= flushEvery { flush(now: now) }
    }

    /// Merge the in-memory bucket into the persisted per-day store and prune to `keepDays`.
    static func flush(now: Date = Date()) {
        guard !unflushed.isEmpty, let day = unflushedDay else { return }
        let persisted = (UserDefaults.standard.dictionary(forKey: persistKey) as? [String: [String: Int]]) ?? [:]
        UserDefaults.standard.set(
            merged(persisted: persisted, adding: unflushed, day: day, keepDays: keepDays),
            forKey: persistKey)
        unflushed = [:]
        sinceFlush = 0
    }

    /// The calm ceiling: the `ceilingPercentile` of the last week's banked daytime beats, clamped —
    /// or nil while fewer than `minSamples` beats exist (cold start, or a -1 duty-cycle install whose
    /// daytime stream is silenced).
    static func calmCeiling(now: Date = Date()) -> Int? {
        var counts = (UserDefaults.standard.dictionary(forKey: persistKey) as? [String: [String: Int]])
            .map { persisted -> [Int: Int] in
                var total: [Int: Int] = [:]
                for (_, dayCounts) in persisted {
                    for (bpmKey, n) in dayCounts {
                        if let bpm = Int(bpmKey) { total[bpm, default: 0] += n }
                    }
                }
                return total
            } ?? [:]
        for (bpm, n) in unflushed { counts[bpm, default: 0] += n }
        guard let p = percentileBpm(counts: counts, p: ceilingPercentile, minSamples: minSamples) else {
            return nil
        }
        return min(max(p, ceilingRange.lowerBound), ceilingRange.upperBound)
    }

    // MARK: - Pure math (pinned by StrandTests)

    /// The bpm at (or just above) cumulative share `p` of a histogram, or nil below `minSamples`
    /// total. Nearest-rank over the sorted bins: deterministic, no interpolation to invent beats
    /// between bins.
    static func percentileBpm(counts: [Int: Int], p: Double, minSamples: Int) -> Int? {
        let total = counts.values.reduce(0, +)
        guard total >= max(minSamples, 1) else { return nil }
        let rank = Int((Double(total) * min(max(p, 0), 1)).rounded(.up))
        var seen = 0
        for (bpm, n) in counts.sorted(by: { $0.key < $1.key }) {
            seen += n
            if seen >= rank { return bpm }
        }
        return counts.keys.max()
    }

    /// Fold `adding` (bpm → count) into `persisted` under `day`, then prune to the newest `keepDays`
    /// day keys. Pure so pruning and the string-keyed round trip are pinned without UserDefaults.
    static func merged(persisted: [String: [String: Int]], adding: [Int: Int],
                       day: String, keepDays: Int) -> [String: [String: Int]] {
        var out = persisted
        var dayCounts = out[day] ?? [:]
        for (bpm, n) in adding { dayCounts["\(bpm)", default: 0] += n }
        out[day] = dayCounts
        let keep = out.keys.sorted(by: >).prefix(max(keepDays, 1))
        return out.filter { keep.contains($0.key) }
    }
}
