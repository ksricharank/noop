import Foundation

/// Pure decisions for the Apple Health bridge, extracted so they are testable from `StrandTests`
/// (which is hosted in the macOS app and cannot link `HealthKitBridge` — that file is iOS-only).
/// Same sibling-file pattern as the other pure helpers (#665).
enum HealthSyncPolicy {

    /// UserDefaults key for the "Write to Apple Health" switch. **Default ON** — writing back is the
    /// long-standing behaviour, so an existing install is byte-identical until the user flips it.
    ///
    /// Why the switch exists: the write-back is the expensive half of a Health sync, and it feeds a
    /// self-wake loop. The observers are registered with `predicate: nil`, so NOOP's OWN saves wake
    /// them; the anchored delta query then filters NOOP-authored samples out (`notNoopAuthored`, #375)
    /// and finds nothing — a process resume spent to learn that we woke ourselves. A 22.9 h capture on
    /// 10.6.0.4 measured 764 wakes with 608 of them (80%) empty, at an 11 s average for the passes
    /// that did sync — and every pass runs all four writers, of which the heart-rate writer re-deletes
    /// and re-saves a rolling 48 h window (~2,880 samples) whether or not anything changed. Reads are
    /// unaffected by this switch: aggregation happens inside the HealthKit daemon and returns one
    /// value per day bucket, so the read half is cheap and is what the scores actually consume.
    static let writeBackEnabledKey = "noop.health.writeBackEnabled"

    /// The switch, with its default. `object(forKey:)` so an unset key reads as `true` (default ON)
    /// rather than `bool(forKey:)`'s unset-reads-false.
    static func writeBackEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: writeBackEnabledKey) as? Bool) ?? true
    }

    /// Should a fresh process resume a prior Apple Health grant without re-prompting?
    ///
    /// HealthKit never reveals *read* authorization, so the resume historically inferred "the user
    /// granted access before" from *write*/share status alone — observable, but wrong for a read-only
    /// user: all reads on + all writes off resumed nothing, `auth` stayed `.unknown`, and
    /// `enableLiveDelivery()` never ran, so background ingestion was silently dead for exactly the
    /// configuration this switch encourages. The durable, write-independent record of opt-in already
    /// exists: `persistReadTypeSignature()` runs only after a *successful* `requestAuthorization()`,
    /// so a stored signature proves the user completed the Health sheet in some earlier process —
    /// regardless of which checkboxes they left on. Either signal resumes.
    static func shouldResumePriorGrant(anyWriteAuthorized: Bool, hasStoredReadSignature: Bool) -> Bool {
        anyWriteAuthorized || hasStoredReadSignature
    }
}
