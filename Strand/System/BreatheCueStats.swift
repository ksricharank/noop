import Foundation

/// 260901: how often the stress auto-nudge actually fires per day — the calibration evidence for
/// the newly user-configurable sensitivity knobs (dip depth / sustain). The maintainer's target is
/// "averages about 5 a day", and no one can dial a threshold toward a frequency nobody measures:
/// this line is what the next exported log gets read against. Day-keyed and persisted like
/// `RetroScanStats` (iOS kills/restores the app many times a day). One header line, silent until
/// a nudge ever fires. In `Strand/System/` so StrandTests can reach the pure formatter.
@MainActor
enum BreatheCueStats {

    private enum K {
        static let day = "bcs.day"
        static let live = "bcs.live"
        static let retro = "bcs.retro"
        static let lastAt = "bcs.lastAt"
    }

    private static var d: UserDefaults { .standard }

    private static func rollIfNeeded(now: Date) {
        let today = Self.dayKey(now)
        if d.string(forKey: K.day) != today {
            d.set(today, forKey: K.day)
            for k in [K.live, K.retro] { d.set(0, forKey: k) }
            d.removeObject(forKey: K.lastAt)
        }
    }

    /// A nudge fired. `retro` marks the burst-retrospective (post-sync replay) path; false = live R-R.
    static func recordFire(retro: Bool, now: Date = Date()) {
        rollIfNeeded(now: now)
        let key = retro ? K.retro : K.live
        d.set(d.integer(forKey: key) + 1, forKey: key)
        d.set(Self.timeKey(now), forKey: K.lastAt)
    }

    /// Test seam.
    static func reset() {
        for k in [K.day, K.live, K.retro, K.lastAt] { d.removeObject(forKey: k) }
    }

    /// One header line, or nothing when no nudge fired today (and the feature idle / macOS).
    static func summaryLines(now: Date = Date()) -> [String] {
        rollIfNeeded(now: now)
        let live = d.integer(forKey: K.live)
        let retro = d.integer(forKey: K.retro)
        guard live + retro > 0 else { return [] }
        return [Self.line(live: live, retro: retro, lastAt: d.string(forKey: K.lastAt))]
    }

    /// Pure formatter (pinned by BreatheCueStatsTests). `lastAt` is "HH:mm:ss" local.
    nonisolated static func line(live: Int, retro: Int, lastAt: String?) -> String {
        "Breathe cues today: fired=\(live + retro) (live=\(live) retro=\(retro))"
            + (lastAt.map { " last=\($0)" } ?? "")
    }

    private nonisolated static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private nonisolated static func timeKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
