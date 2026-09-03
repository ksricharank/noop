import Foundation
import WhoopStore

/// Memoizes `Repository.widgetAnchor` across the high-frequency live-HR path (#1051-shaped).
///
/// The Live Activity's `$heartRate` / `$connected` `onReceive` closures in `StrandiOSApp` resolve the
/// widget anchor on EVERY live tick (~1-3 Hz). Each `widgetAnchor` call re-derives today's anchor row:
/// two `DateFormatter` formats to build the day keys plus up to two full-history `days.last(where:)`
/// scans that grow with years of stored rows — all on the MainActor, and BEFORE `LiveActivityController`'s
/// own 2 s push throttle, so that throttle never saves it.
///
/// The anchor only changes when `days` changes (tracked by `Repository.refreshSeq`, bumped on every
/// `days` assignment) or when the local/logical day rolls. Keying the memo on `(seq, logicalKey, localKey)`
/// makes it exactly behavior-preserving: a streaming tick reuses the last row, and the anchor is recomputed
/// precisely once per data refresh or day-roll. Same `refreshSeq`-keyed idiom as `todayHistoryWideLoadedSeq`.
///
/// Pure given the `compute` it is handed, so it is unit-tested without a live `Repository` — the twin of
/// Android's `NotifyDayStateCache` (#1051). Held as a `Repository` stored property and only ever touched on
/// the MainActor, so the plain `mutating` cache needs no locking.
struct WidgetAnchorMemo {
    private var cached: (seq: Int, logicalKey: String, localKey: String, row: DailyMetric?)?

    /// Return the anchor for `(seq, logicalKey, localKey)`, recomputing via `compute` only when that key
    /// differs from the last one. `compute` is the pure `Repository.widgetAnchor(days:logicalKey:localKey:)`.
    mutating func resolve(
        days: [DailyMetric],
        seq: Int,
        logicalKey: String,
        localKey: String,
        compute: ([DailyMetric], String, String) -> DailyMetric?
    ) -> DailyMetric? {
        if let cached, cached.seq == seq, cached.logicalKey == logicalKey, cached.localKey == localKey {
            return cached.row
        }
        let row = compute(days, logicalKey, localKey)
        cached = (seq, logicalKey, localKey, row)
        return row
    }
}

/// Memo for the Live Activity's deterministic daily-targets bundle (`Repository.cachedLiveTargets`) —
/// the calm ceiling, the calorie target + today's total, and tonight's sleep need all derive from
/// `days`, so they are keyed and invalidated exactly like the anchor above: recompute on a data
/// refresh (`refreshSeq`) or a day roll, reuse on every streaming tick in between. Same MainActor-only
/// ownership, so the plain `mutating` cache needs no locking.
struct LiveTargetsMemo {
    private var cached: (seq: Int, hydrationSeq: Int, logicalKey: String, localKey: String,
                         value: LiveTargets)?

    /// `hydrationSeq` joins the key (260903) because the targets now CARRY the day's water, and a
    /// hydration write deliberately never bumps `refreshSeq` (#989 — it is not strap data, and a
    /// full data refresh per logged cup would be absurd). Without it in the key, tapping the Today
    /// water row returned the memoized targets unchanged and the number only moved when an
    /// unrelated sync happened to bump `refreshSeq` — the reported "significant lag".
    mutating func resolve(
        seq: Int,
        hydrationSeq: Int,
        logicalKey: String,
        localKey: String,
        compute: () -> LiveTargets
    ) -> LiveTargets {
        if let cached, cached.seq == seq, cached.hydrationSeq == hydrationSeq,
           cached.logicalKey == logicalKey, cached.localKey == localKey {
            return cached.value
        }
        let value = compute()
        cached = (seq, hydrationSeq, logicalKey, localKey, value)
        return value
    }
}
