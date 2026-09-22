import Foundation

/// #1578: what the HealthKit observer path actually cost this session.
///
/// The battery question that prompted this — "is Apple Health sync draining the phone?" — could not be
/// answered from an exported log, because nothing on that path measured anything. The optimisation that
/// came with it (coalescing observer wakes) is itself unmeasured for the same reason, so it cannot be
/// evaluated after the fact either. This is the missing half: counts and a duration, in the header the
/// reporter already sends.
///
/// Deliberately counts WAKES separately from SYNCS. Coalescing reduces the work per wake, not the number
/// of wakes — iOS still resumes the process for every observer notification, and if that resume is the
/// dominant cost then this ratio is what says so. A log showing many wakes and few syncs means the
/// coalescing is working AND that the remaining cost is the wake itself, which would call for a different
/// fix (fewer observers, or dropping background delivery for the chatty types) rather than more of this
/// one.
///
/// In `Strand/` rather than `StrandiOS/` on purpose: this is shared-target, so `StrandTests` can reach it.
/// A type placed beside `HealthKitBridge` would be testable by nothing.
///
/// Counts and milliseconds only — no sample values, no timestamps, same privacy class as the rest of the
/// header. Process-lifetime, never persisted.
@MainActor
enum HealthSyncStats {

    /// Observer notifications handled, whether or not they led to a sync.
    private(set) static var wakes = 0
    /// Wakes that ran a full sync.
    private(set) static var syncs = 0
    /// Wakes that stood down because a recent sync already covered their window.
    private(set) static var coalesced = 0
    /// Wakes that found no new samples at all (a spurious notification).
    private(set) static var emptyWakes = 0
    /// Cumulative wall time inside `sync()`, milliseconds.
    private(set) static var syncMillis = 0

    static func recordWake() { wakes += 1 }
    static func recordEmptyWake() { emptyWakes += 1 }
    static func recordCoalesced() { coalesced += 1 }
    static func recordSync(millis: Int) { syncs += 1; syncMillis += max(0, millis) }

    /// 260906: WHERE a sync's wall time goes, split three ways.
    ///
    /// The 260906-2052 log read `wakes=252 synced=27 coalesced=32 empty=168 avgSyncMs=27233` — 27
    /// SECONDS per sync, which looks alarming beside everything else in the header. But `syncMillis`
    /// is WALL time, and a sync is mostly `await`: sixteen sequential HealthKit statistics queries,
    /// then a write-back, then a repo refresh. Wall time spent parked on an `await` is not battery.
    ///
    /// So the total cannot pick the fix. Three candidates, and they call for opposite changes:
    ///   * the READS dominate — sixteen serial queries would be worth gathering concurrently;
    ///   * the WRITE-BACK dominates — that is our own HealthKit writes, and the lever is writing less
    ///     often rather than reading faster;
    ///   * the REFRESH dominates — the cost is not HealthKit at all, it is the repo pass the sync
    ///     triggers, and it belongs with the re-score work instead.
    ///
    /// Measured before changed, on a path that was already timing itself. Nothing is optimised on the
    /// strength of the aggregate number, which is exactly the trap the instrumentation-first rule
    /// exists to stop: sixteen serial awaits LOOK like the answer, and may well be the answer, but
    /// "looks like" is how a speculative fix gets shipped and measured a week later.
    private(set) static var readMillis = 0
    private(set) static var writeBackMillis = 0
    private(set) static var refreshMillis = 0

    /// How many write-backs the `writeBackMillis` total is made of (260919).
    ///
    /// It used to be divided by `syncs`, which counts only FULL syncs through `sync()` — and the
    /// dominant write-back path is not that one. `writeBackAfterNewData()` runs after every
    /// completed strap backfill, ~37 times in the motivating log against `syncs=2`, and carried no
    /// instrumentation at all. So the header's "writeBack=4s" was the cost of two write-backs
    /// divided by two syncs, presented beside a number of runs it had not measured, and the
    /// question it exists to answer — what enabling Apple Health writes actually costs — could not
    /// be answered from it either way.
    ///
    /// Its own counter, incremented wherever a write-back is timed, so the divisor matches the
    /// numerator whichever path ran.
    private(set) static var writeBacks = 0

    static func recordReadPhase(millis: Int) { readMillis += max(0, millis) }
    static func recordWriteBackPhase(millis: Int) {
        writeBacks += 1
        writeBackMillis += max(0, millis)
    }
    static func recordRefreshPhase(millis: Int) { refreshMillis += max(0, millis) }

    /// Test seam — the counters are process-lifetime, so a suite needs a way back to zero.
    static func reset() {
        wakes = 0; syncs = 0; coalesced = 0; emptyWakes = 0; syncMillis = 0
        readMillis = 0; writeBackMillis = 0; refreshMillis = 0; writeBacks = 0
    }

    /// The phase split, or "" until something has been measured.
    ///
    /// Absent rather than zeros: a `reads=0s` printed before any sync has run would read as "the
    /// reads are free", which is a claim the counter has not earned.
    static var phaseSuffix: String {
        let total = readMillis + writeBackMillis + refreshMillis
        guard total > 0 else { return "" }
        // writeBack is averaged over its OWN run count and says so — it does not ride the sync
        // cadence (see `writeBacks`). reads/refresh remain per-sync, which is the path they run on.
        return " · per sync: reads=\(ms(readMillis)) refresh=\(ms(refreshMillis))"
            + " · writeBack=\(per(writeBackMillis, over: writeBacks))×\(writeBacks)"
            + " (wall time, mostly await — not CPU)"
    }

    /// Milliseconds as a per-sync average, in whole seconds when large enough to matter.
    private static func ms(_ totalMillis: Int) -> String { per(totalMillis, over: syncs) }

    /// Milliseconds averaged over an explicit run count. A zero count reads "—", never "0ms": no
    /// measurement and a measurement of nothing are different claims, and the second is the one
    /// that would be believed.
    private static func per(_ totalMillis: Int, over runs: Int) -> String {
        guard runs > 0 else { return "—" }
        let each = totalMillis / runs
        return each >= 1000 ? "\(each / 1000)s" : "\(each)ms"
    }

    /// One header line, or nothing at all when the observer path never ran this session.
    ///
    /// Silent-when-unused matters: most logs come from people whose Health sync is off or unauthorized,
    /// and a line of zeros in every one of those would be noise that trains readers to skip the block.
    static func summaryLines() -> [String] {
        guard wakes > 0 else { return [] }
        let avg = syncs > 0 ? syncMillis / syncs : 0
        return ["Health sync: wakes=\(wakes) synced=\(syncs) coalesced=\(coalesced) "
                + "empty=\(emptyWakes) avgSyncMs=\(avg)"
                + phaseSuffix]
    }
}
