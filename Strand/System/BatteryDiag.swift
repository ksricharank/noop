import Foundation

/// Battery attribution counters: what wakes the process, and what the process cost — in the header
/// the reporter already sends.
///
/// The battery question a strap log could not previously answer is WHERE the background hours go.
/// `HealthSyncStats` (#1578) answered it for the HealthKit observer path; this is the same shape for
/// the other two attributions that matter:
///
/// - **BLE notifications**, counted per characteristic. Every notification resumes the process, so
///   with an always-on realtime stream the app effectively never suspends — the 260827 log's build
///   showed ~1–2/s, 24/7, billed by iOS as 5–6 h/day of "background activity". A counter per
///   characteristic is what says whether a change (the locked-stream duty cycle, a firmware quirk
///   that keeps 0x2A37 emitting) actually moved the number, and which channel is responsible.
/// - **Process CPU time**, read ONCE at export via `getrusage` — the number iOS's own battery
///   accounting is closest to. Counters and a single syscall at export: the instrumentation itself
///   costs one integer increment per event it exists to count, so it can never become the drain it
///   measures.
///
/// In `Strand/` rather than `StrandiOS/` on purpose, like `HealthSyncStats`: shared-target, so
/// `StrandTests` can pin the formatting. Counts and durations only — no payloads, no timestamps,
/// same privacy class as the rest of the header. The session counters are process-lifetime; the
/// per-day totals are additionally banked in UserDefaults (today + yesterday only) so a process
/// death no longer erases the day — see `flush()`.
@MainActor
enum BatteryDiag {

    /// Notifications handled, keyed by a short channel label ("hr2A37", "data", "battery", …).
    private(set) static var notifyCounts: [String: Int] = [:]
    /// When the FIRST notification landed, so the line can carry a rate, not just a total. Anchored
    /// on the first record rather than "process launch" deliberately: a lazy `= Date()` static is
    /// initialised on first ACCESS, which was inside the export itself — microseconds AFTER the `now`
    /// it was compared against — so the window read as negative and the whole line silently vanished
    /// from every process's first export (observed in the 260827-2142 log: the CPU sibling printed,
    /// this one did not). nil until something is counted.
    private static var firstNotifyAt: Date?

    static func recordNotify(_ label: String, now: Date = Date()) {
        if firstNotifyAt == nil { firstNotifyAt = now }
        notifyCounts[label, default: 0] += 1
        unflushed[label, default: 0] += 1
    }

    /// 260903: the same count, split by whether the phone was LOCKED when the notification landed.
    ///
    /// A per-channel total cannot answer the battery question it exists for. The 260903-1145 log
    /// showed puffin=35701 today and 102906 yesterday, and the halving is only good news if the
    /// remainder is arriving while the user is actually looking at something. Wakes while LOCKED
    /// are the pure cost — nobody is reading a screen, and each one resumes the process — so they
    /// are the number a duty-cycle change has to move. Counted under the same label with a
    /// ".locked" suffix, so the existing per-channel lines are untouched and the split is additive.
    static func recordNotify(_ label: String, locked: Bool, now: Date = Date()) {
        recordNotify(label, now: now)
        if locked {
            notifyCounts[label + ".locked", default: 0] += 1
            unflushed[label + ".locked", default: 0] += 1
        }
    }

    // MARK: Cross-session persistence
    //
    // Per-process counters alone cannot answer the day question: the process that holds the
    // interesting totals is exactly the one that dies before an export (the 260828-0731 log's
    // overnight session was relaunched at 07:31, so the header could only extrapolate the 30 s
    // launch burst — "224148/h over 0.0h"). So the counters are ALSO banked per local day in
    // UserDefaults, merged on `flush()` — called from the offload-completion path (one small
    // defaults write per sync) and at export — and pruned to today + yesterday.

    /// Counts not yet merged into the persisted day bucket. Separate from `notifyCounts` so the
    /// session line keeps its process-lifetime meaning.
    private static var unflushed: [String: Int] = [:]
    private static let persistKey = "noop.batterydiag.days"
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Merge the since-last-flush counts into today's persisted bucket. Cheap enough for a per-sync
    /// call site: a dictionary merge plus one defaults write, and a no-op when nothing new arrived.
    static func flush(now: Date = Date()) {
        guard !unflushed.isEmpty else { return }
        let persisted = (UserDefaults.standard.dictionary(forKey: persistKey) as? [String: [String: Int]]) ?? [:]
        let day = dayFormatter.string(from: now)
        UserDefaults.standard.set(merged(persisted: persisted, adding: unflushed, day: day),
                                  forKey: persistKey)
        unflushed = [:]
    }

    /// Pure merge + prune: add `counts` into `day`'s bucket and keep only the `keepDays` newest day
    /// keys (the header prints today + yesterday; anything older is dead weight in the plist).
    static func merged(persisted: [String: [String: Int]], adding counts: [String: Int],
                       day: String, keepDays: Int = 2) -> [String: [String: Int]] {
        var out = persisted
        out[day, default: [:]].merge(counts, uniquingKeysWith: +)
        for stale in out.keys.sorted(by: >).dropFirst(keepDays) {
            out.removeValue(forKey: stale)
        }
        return out
    }

    /// Test seam — the counters are process-lifetime, so a suite needs a way back to zero.
    static func reset() {
        notifyCounts = [:]
        firstNotifyAt = nil
        unflushed = [:]
    }

    /// The header lines, or nothing when no notification arrived this session (a log exported before
    /// the strap ever connected) — silent-when-unused, like the Health line, so such a log is unchanged.
    static func summaryLines(now: Date = Date()) -> [String] {
        var lines: [String] = []
        if let since = firstNotifyAt,
           let n = Self.formatNotifyLine(counts: notifyCounts,
                                         seconds: now.timeIntervalSince(since)) {
            lines.append(n)
        }
        // The persisted per-day totals — the numbers that survive a relaunch. Flush first so this
        // export's own counts are included; print today then yesterday, silent when a day is empty.
        flush(now: now)
        let persisted = (UserDefaults.standard.dictionary(forKey: persistKey) as? [String: [String: Int]]) ?? [:]
        let today = dayFormatter.string(from: now)
        let yesterday = dayFormatter.string(from: now.addingTimeInterval(-86_400))
        for (label, day) in [("today", today), ("yesterday", yesterday)] {
            if let counts = persisted[day], let line = formatDayLine(label: label, counts: counts) {
                lines.append(line)
            }
        }
        if let c = Self.cpuLine() { lines.append(c) }
        #if os(iOS)
        if let m = UserDefaults.standard.string(forKey: MetricKitDiagSummaryKey) {
            lines.append(m)
        }
        #endif
        return lines
    }

    /// Pure formatter, busiest channel first, with the per-hour rate that makes the number comparable
    /// across logs of different lengths. Nil when nothing was counted or the clock is unusable.
    /// `seconds == 0` is a VALID input — an export moments after the first notification — floored to
    /// one second for the rate, never dropped: dropping short windows is the shape of the bug above.
    static func formatNotifyLine(counts: [String: Int], seconds: TimeInterval) -> String? {
        guard !counts.isEmpty, seconds >= 0, seconds.isFinite else { return nil }
        let span = max(seconds, 1)
        let total = counts.values.reduce(0, +)
        let parts = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { "\($0.key)=\($0.value)" }
        // Under ten minutes, an hourly extrapolation is noise dressed as a rate — the 260828-0731
        // header turned a 30 s launch-time offload burst into "224148/h". Short windows report the
        // honest span in seconds and no rate; the persisted per-day lines carry the real day totals.
        guard span >= 600 else {
            return "BLE wakes: " + parts.joined(separator: " ")
                + String(format: " — %d total over %.0fs (window too short for a rate)", total, span)
        }
        let perHour = Double(total) / (span / 3600)
        return "BLE wakes: " + parts.joined(separator: " ")
            + String(format: " — %d total, %.0f/h over %.1fh", total, perHour, span / 3600)
    }

    /// Pure formatter for one persisted day bucket — same channel ordering as the session line.
    /// Nil when the bucket is empty (a day with no strap contact stays silent).
    static func formatDayLine(label: String, counts: [String: Int]) -> String? {
        guard !counts.isEmpty else { return nil }
        let total = counts.values.reduce(0, +)
        let parts = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { "\($0.key)=\($0.value)" }
        return "BLE wakes \(label): " + parts.joined(separator: " ") + " — \(total) total"
    }

    /// Process CPU consumed since launch, user+system — one `getrusage` call, made only here.
    static func cpuLine() -> String? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return String(format: "CPU this app session: user=%.1fs sys=%.1fs", user, sys)
    }
}

/// Where `MetricKitDiag` (iOS-only) parks its once-a-day summary for the header to read. Defined here,
/// outside the `#if`, so the header assembly compiles on both platforms without reaching into an
/// iOS-only type.
let MetricKitDiagSummaryKey = "noop.metrickit.lastDaily"
