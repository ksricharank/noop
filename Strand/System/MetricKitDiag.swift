#if os(iOS) && canImport(MetricKit)
import Foundation
import MetricKit

/// Logs Apple's OWN daily battery accounting into the strap log — the ground truth the Battery
/// screen's "background activity" hours are built from, at zero collection cost.
///
/// iOS records per-app CPU time and foreground/background wall time for every app all the time;
/// `MXMetricManager` merely hands the previous day's totals to any subscriber, at most once every
/// 24 h. So this costs nothing between deliveries and nothing extra during them — the OS was
/// collecting anyway. It is the arbiter the in-process counters (`BatteryDiag`) get compared
/// against: our counters say what woke us and what we think we spent; this says what iOS billed.
///
/// The payload arrives on a background queue whenever iOS feels like it, typically shortly after
/// midnight — often in a launch this process never sees. So the summary is parked in UserDefaults
/// and printed by the NEXT export's header rather than appended to the live log, exactly like the
/// stored Health read-signature: durable, one line, overwritten daily.
final class MetricKitDiag: NSObject, MXMetricManagerSubscriber {
    private static let shared = MetricKitDiag()

    /// Idempotent; call once at launch. The manager holds the subscriber weakly, hence the retained
    /// singleton.
    static func start() {
        MXMetricManager.shared.add(shared)
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        // The most recent day wins; the header shows one line, not a history.
        guard let p = payloads.last else { return }
        var parts: [String] = []
        if let cpu = p.cpuMetrics {
            parts.append(String(format: "cpu=%.0fs",
                                cpu.cumulativeCPUTime.converted(to: .seconds).value))
        }
        if let t = p.applicationTimeMetrics {
            parts.append(String(format: "fg=%.0fm",
                                t.cumulativeForegroundTime.converted(to: .minutes).value))
            parts.append(String(format: "bg=%.0fm",
                                t.cumulativeBackgroundTime.converted(to: .minutes).value))
        }
        guard !parts.isEmpty else { return }
        let df = DateFormatter()
        df.dateFormat = "MM-dd"
        df.timeZone = .current
        let line = "MetricKit (iOS's own daily bill, \(df.string(from: p.timeStampBegin))): "
            + parts.joined(separator: " ")
        // UserDefaults is thread-safe; no hop needed from MetricKit's delivery queue.
        UserDefaults.standard.set(line, forKey: MetricKitDiagSummaryKey)
    }
}
#endif
