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
/// same privacy class as the rest of the header. Process-lifetime, never persisted.
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
    }

    /// Test seam — the counters are process-lifetime, so a suite needs a way back to zero.
    static func reset() {
        notifyCounts = [:]
        firstNotifyAt = nil
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
        let perHour = Double(total) / (span / 3600)
        return "BLE wakes: " + parts.joined(separator: " ")
            + String(format: " — %d total, %.0f/h over %.1fh", total, perHour, span / 3600)
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
