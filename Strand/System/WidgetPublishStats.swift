import Foundation

/// 260831: what the widget-publish path actually did today — the missing evidence line.
///
/// The report that prompted this: widgets frozen for hours while the strap log showed a completed
/// offload every ~10 minutes. The log could prove data LANDED but nothing on the publish path
/// measured anything, so "did WidgetSnapshot.publish run, did it request a WidgetKit reload, and
/// with what values" was unanswerable — the failure could equally be a publish that never ran
/// (something earlier in refreshAfterCompletedBackfill starving it), a publish deduped as
/// unchanged, or WidgetKit deferring repaints (the OS reload budget). One line separates those.
///
/// ATTEMPTS are counted separately from COMPLETIONS (`begun` vs `finished`): a publish that starts
/// and never finishes is a process death or hang inside the path itself, which completions alone
/// would hide. The glance string carries the last-published numbers so a stale widget can be
/// compared against what the snapshot actually said (WidgetKit deferral shows as a fresh snapshot
/// under a stale widget; a publish problem shows as a stale snapshot).
///
/// DAY-KEYED AND PERSISTED (unlike `HealthSyncStats`, which is process-lifetime): iOS routinely
/// kills and state-restores this app many times a day, so per-process counters would only ever
/// describe the last half hour. Counters reset when the stored local day key changes. Counts,
/// timestamps and already-on-the-widget numbers only — same privacy class as the rest of the
/// header. In `Strand/System/` so StrandTests can reach the pure formatter.
@MainActor
enum WidgetPublishStats {

    private enum K {
        static let day = "wps.day"
        static let fullBegun = "wps.fullBegun"
        static let fullFinished = "wps.fullFinished"
        static let live = "wps.live"
        static let reloads = "wps.reloads"
        static let dedup = "wps.dedup"
        static let lastAt = "wps.lastAt"          // epoch seconds of the last COMPLETED publish
        static let lastGlance = "wps.lastGlance"  // "steps=… cal=… effort=… sleep=…" of that publish
    }

    private static var d: UserDefaults { .standard }

    /// Roll the counters when the local day changes. Called by every record; cheap (one string read).
    private static func rollIfNeeded(now: Date) {
        let today = Self.dayKey(now)
        if d.string(forKey: K.day) != today {
            d.set(today, forKey: K.day)
            for k in [K.fullBegun, K.fullFinished, K.live, K.reloads, K.dedup] { d.set(0, forKey: k) }
            // lastAt/lastGlance deliberately survive the roll: "last publish was yesterday 23:58"
            // is exactly the evidence a frozen morning widget needs.
        }
    }

    private static func bump(_ key: String, now: Date) {
        rollIfNeeded(now: now)
        d.set(d.integer(forKey: key) + 1, forKey: key)
    }

    /// A full publish entered `WidgetSnapshot.publish`.
    static func recordFullBegun(now: Date = Date()) { bump(K.fullBegun, now: now) }

    /// A full publish reached the save/dedup decision. `glance` is the human-readable pair summary
    /// of what was (or would have been) written; `reloadRequested` = the content changed and
    /// WidgetKit was asked for a new timeline.
    static func recordFullFinished(glance: String, reloadRequested: Bool, now: Date = Date()) {
        bump(K.fullFinished, now: now)
        if reloadRequested { d.set(d.integer(forKey: K.reloads) + 1, forKey: K.reloads) }
        else { d.set(d.integer(forKey: K.dedup) + 1, forKey: K.dedup) }
        d.set(now.timeIntervalSince1970, forKey: K.lastAt)
        d.set(glance, forKey: K.lastGlance)
    }

    /// A live-only fast-path publish ran (bpm/battery/bonded only). `reloadRequested` as above.
    static func recordLive(reloadRequested: Bool, now: Date = Date()) {
        bump(K.live, now: now)
        if reloadRequested { d.set(d.integer(forKey: K.reloads) + 1, forKey: K.reloads) }
    }

    /// Test seam: clear everything, including the day key, so a suite starts from zero.
    static func reset() {
        for k in [K.day, K.fullBegun, K.fullFinished, K.live, K.reloads, K.dedup,
                  K.lastAt, K.lastGlance] { d.removeObject(forKey: k) }
    }

    /// One header line, or nothing when no publish ever ran (macOS, fresh installs).
    static func summaryLines(now: Date = Date()) -> [String] {
        rollIfNeeded(now: now)
        let begun = d.integer(forKey: K.fullBegun)
        let live = d.integer(forKey: K.live)
        guard begun > 0 || live > 0 else { return [] }
        let lastAt = d.double(forKey: K.lastAt)
        let last = lastAt > 0 ? Self.clock(Date(timeIntervalSince1970: lastAt)) : "never"
        let glance = d.string(forKey: K.lastGlance) ?? "-"
        return [Self.line(begun: begun,
                          finished: d.integer(forKey: K.fullFinished),
                          live: live,
                          reloads: d.integer(forKey: K.reloads),
                          dedup: d.integer(forKey: K.dedup),
                          last: last, glance: glance)]
    }

    /// Pure formatter (pinned by WidgetPublishStatsTests). `begun > finished` is the starvation /
    /// death-inside-the-path signature; `finished` advancing while a widget stays stale with high
    /// `reloads` points at WidgetKit deferral instead.
    nonisolated static func line(begun: Int, finished: Int, live: Int, reloads: Int, dedup: Int,
                                 last: String, glance: String) -> String {
        "Widget publish today: full=\(finished)/\(begun) live=\(live) reloads=\(reloads) "
            + "dedup=\(dedup) last=\(last) \(glance)"
    }

    private nonisolated static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private nonisolated static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
