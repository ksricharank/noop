import Foundation

/// Pure scheduling policy for iOS's best-effort Apple Health write-back refresh.
///
/// The BackgroundTasks framework decides the actual delivery time; this interval is only the earliest
/// time at which NOOP asks to be considered again. Keeping the policy framework-free makes the cadence
/// and authorization gate testable in the macOS-hosted app test target.
enum HealthWritebackSchedulePolicy {
    static let refreshInterval: TimeInterval = 60 * 60

    /// 260928: the floor between ROUTINE post-backfill write-backs. The strap offloads every ~10
    /// minutes and every completion ran a full 14-day rewrite — 168 by 11:20 in the 260928-1120 log
    /// (vs 4 two days earlier), each deleting and re-saving two weeks of sleep sessions, the
    /// 1-minute HR stream, workouts and vitals. The wearer's Battery screen showed the Health app
    /// ingesting that churn all morning. Health is an export mirror, not a live surface: thirty
    /// minutes of staleness costs nothing; six rewrites an hour cost a battery complaint.
    static let minPostBackfillSpacing: TimeInterval = 30 * 60

    /// Whether a routine write-back may run now. A nil `lastWriteBack` (first of the process) and a
    /// BACKWARDS clock both say yes — a negative age must never wedge the export until reboot.
    ///
    /// (Narrowing the routine write WINDOW from 14 days to the 2 an offload can change is the second
    /// lever, deferred: it needs an edit inside `HealthKitBridge.writeBackAfterNewData`, whose fork
    /// delta belongs to feature/health-read-only-sync — editing it from this stack is exactly the
    /// cross-branch conflict the 260928 release cut hit. The spacing floor alone removes the 40×
    /// frequency factor, which is the dominant term.)
    static func shouldWriteBackNow(now: Date, lastWriteBack: Date?) -> Bool {
        guard let lastWriteBack else { return true }
        let age = now.timeIntervalSince(lastWriteBack)
        return age < 0 || age >= minPostBackfillSpacing
    }

    static func shouldSchedule(isAuthorized: Bool) -> Bool {
        isAuthorized
    }

    static func earliestBeginDate(after date: Date) -> Date {
        date.addingTimeInterval(refreshInterval)
    }
}

/// The stamped admission gate the two ROUTINE call sites share. Deliberately a separate, impure
/// companion so `HealthWritebackSchedulePolicy` stays the pure, macOS-testable rule; and deliberately
/// at the CALL SITES rather than inside `writeBackAfterNewData` — that function's fork delta belongs
/// to feature/health-read-only-sync, and editing it from this stack conflicts at every release cut.
/// The explicit foreground `sync()` path never consults this: an app open should always export.
@MainActor
enum HealthWritebackThrottle {
    private(set) static var lastAdmitted: Date?

    /// True when a routine write-back may run now; stamps the admission. A stood-down run is counted
    /// (`writeBack=…×N skipped=M` in the header) so the next log shows the throttle working rather
    /// than the export silently dying. Skipping loses nothing: the next backfill past the floor
    /// writes the same days, fresher.
    static func admit(now: Date = Date()) -> Bool {
        guard HealthWritebackSchedulePolicy.shouldWriteBackNow(now: now, lastWriteBack: lastAdmitted) else {
            HealthSyncStats.recordWriteBackSkipped()
            return false
        }
        lastAdmitted = now
        return true
    }

    /// Test seam.
    static func reset() { lastAdmitted = nil }
}
