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
        // 260905: the fg/bg split. WidgetKit reloads requested from the BACKGROUND are charged
        // against a daily budget (~40-70 by the estimate in `renderedContentChanged`), while
        // foreground-initiated ones are exempt. The existing `reloads` total therefore cannot
        // answer the question that matters — "are we out of budget?" — because a day of 53
        // foreground reloads is healthy and a day of 53 background ones is starving.
        static let reloadsBg = "wps.reloadsBg"
        static let dedupBg = "wps.dedupBg"
        /// Background reloads whose ONLY changed field was one the widget faces do not show. A
        /// non-zero count here is directly actionable: it is budget spent on repaints nobody sees.
        static let reloadsBgUnseen = "wps.reloadsBgUnseen"
        /// Publishes that ran in the background at all, reload or not — the denominator for the two
        /// above, and the number a reduction effort would be trying to move.
        static let publishesBg = "wps.publishesBg"
        /// The first and last background reload of the day, so a log shows WHEN the budget went. A
        /// morning cluster followed by silence is the deferral signature.
        static let firstBgReloadAt = "wps.firstBgReloadAt"
        static let lastBgReloadAt = "wps.lastBgReloadAt"
        static let lastAt = "wps.lastAt"          // epoch seconds of the last COMPLETED publish
        static let lastGlance = "wps.lastGlance"  // "steps=… cal=… effort=… sleep=…" of that publish
    }

    private static var d: UserDefaults { .standard }

    /// Roll the counters when the local day changes. Called by every record; cheap (one string read).
    private static func rollIfNeeded(now: Date) {
        let today = Self.dayKey(now)
        if d.string(forKey: K.day) != today {
            d.set(today, forKey: K.day)
            for k in [K.fullBegun, K.fullFinished, K.live, K.reloads, K.dedup,
                      K.reloadsBg, K.dedupBg, K.reloadsBgUnseen, K.publishesBg] { d.set(0, forKey: k) }
            for k in [K.firstBgReloadAt, K.lastBgReloadAt] { d.removeObject(forKey: k) }
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
    static func recordFullFinished(glance: String, reloadRequested: Bool, now: Date = Date(),
                                   inBackground: Bool = false, unseenOnly: Bool = false) {
        bump(K.fullFinished, now: now)
        if reloadRequested { d.set(d.integer(forKey: K.reloads) + 1, forKey: K.reloads) }
        else { d.set(d.integer(forKey: K.dedup) + 1, forKey: K.dedup) }
        recordSceneSplit(reloadRequested: reloadRequested, inBackground: inBackground,
                         unseenOnly: unseenOnly, now: now)
        d.set(now.timeIntervalSince1970, forKey: K.lastAt)
        d.set(glance, forKey: K.lastGlance)
    }

    /// The fg/bg bookkeeping shared by the full and live paths.
    private static func recordSceneSplit(reloadRequested: Bool, inBackground: Bool,
                                         unseenOnly: Bool, now: Date) {
        guard inBackground else { return }
        d.set(d.integer(forKey: K.publishesBg) + 1, forKey: K.publishesBg)
        guard reloadRequested else {
            d.set(d.integer(forKey: K.dedupBg) + 1, forKey: K.dedupBg)
            return
        }
        d.set(d.integer(forKey: K.reloadsBg) + 1, forKey: K.reloadsBg)
        if unseenOnly { d.set(d.integer(forKey: K.reloadsBgUnseen) + 1, forKey: K.reloadsBgUnseen) }
        if d.double(forKey: K.firstBgReloadAt) == 0 {
            d.set(now.timeIntervalSince1970, forKey: K.firstBgReloadAt)
        }
        d.set(now.timeIntervalSince1970, forKey: K.lastBgReloadAt)
    }

    /// A live-only fast-path publish ran (bpm/battery/bonded only). `reloadRequested` as above.
    static func recordLive(reloadRequested: Bool, now: Date = Date(), inBackground: Bool = false) {
        bump(K.live, now: now)
        if reloadRequested { d.set(d.integer(forKey: K.reloads) + 1, forKey: K.reloads) }
        // `unseenOnly` is never true here: the live path only writes bpm / battery / bonded, all of
        // which the faces do render.
        recordSceneSplit(reloadRequested: reloadRequested, inBackground: inBackground,
                         unseenOnly: false, now: now)
    }

    /// Test seam: clear everything, including the day key, so a suite starts from zero.
    static func reset() {
        for k in [K.day, K.fullBegun, K.fullFinished, K.live, K.reloads, K.dedup,
                  K.lastAt, K.lastGlance, K.reloadsBg, K.dedupBg, K.reloadsBgUnseen,
                  K.publishesBg, K.firstBgReloadAt, K.lastBgReloadAt] { d.removeObject(forKey: k) }
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
        // The extension's own counter is iOS-only (`WidgetSnapshot` is excluded from the macOS
        // target, which has no widgets to serve).
        #if os(iOS)
        let served = WidgetSnapshot.ExtensionStats.served(dayKey: Self.dayKey(now))
        #else
        let served: (count: Int, lastAt: Date?) = (0, nil)
        #endif
        let firstBg = d.double(forKey: K.firstBgReloadAt)
        let lastBg = d.double(forKey: K.lastBgReloadAt)
        return [Self.line(begun: begun,
                          finished: d.integer(forKey: K.fullFinished),
                          live: live,
                          reloads: d.integer(forKey: K.reloads),
                          dedup: d.integer(forKey: K.dedup),
                          last: last, glance: glance),
                Self.backgroundLine(
                    publishesBg: d.integer(forKey: K.publishesBg),
                    reloadsBg: d.integer(forKey: K.reloadsBg),
                    dedupBg: d.integer(forKey: K.dedupBg),
                    unseenBg: d.integer(forKey: K.reloadsBgUnseen),
                    firstBg: firstBg > 0 ? Self.clock(Date(timeIntervalSince1970: firstBg)) : nil,
                    lastBg: lastBg > 0 ? Self.clock(Date(timeIntervalSince1970: lastBg)) : nil),
                Self.servedLine(requested: d.integer(forKey: K.reloads), served: served.count,
                                lastServed: served.lastAt.map(Self.clock))]
            .filter { !$0.isEmpty }
    }

    /// Pure formatter (pinned by WidgetPublishStatsTests). `begun > finished` is the starvation /
    /// death-inside-the-path signature; `finished` advancing while a widget stays stale with high
    /// `reloads` points at WidgetKit deferral instead.
    nonisolated static func line(begun: Int, finished: Int, live: Int, reloads: Int, dedup: Int,
                                 last: String, glance: String) -> String {
        "Widget publish today: full=\(finished)/\(begun) live=\(live) reloads=\(reloads) "
            + "dedup=\(dedup) last=\(last) \(glance)"
    }

    /// The background half, which is the one with a budget (260905).
    ///
    /// `reloads` in the line above is a TOTAL and cannot answer "are we out of budget?" — a day of
    /// 53 foreground reloads is healthy and a day of 53 background ones is starving, because only
    /// background-initiated WidgetKit reloads are charged. This splits them, and adds the two
    /// numbers a reduction effort would need:
    ///
    ///   * `unseen` — background reloads whose only changed field is not on any widget face. Budget
    ///     spent on repaints nobody can see; directly removable.
    ///   * `first`/`last` — when the day's background reloads happened. A cluster that stops early
    ///     is the deferral signature: the budget was spent by mid-morning and every later request
    ///     was dropped, which is exactly what "the widget lags behind the app" looks like.
    ///
    /// Reads as "none" rather than being omitted when nothing ran in the background: the ABSENCE of
    /// background publishes is itself an answer (it would mean the gating, not the budget, is what
    /// keeps the widget stale), and a missing line cannot say that.
    nonisolated static func backgroundLine(publishesBg: Int, reloadsBg: Int, dedupBg: Int,
                                           unseenBg: Int, firstBg: String?, lastBg: String?) -> String {
        guard publishesBg > 0 else {
            return "Widget background: none today (every publish ran in the foreground)"
        }
        let window = (firstBg != nil && lastBg != nil) ? " window=\(firstBg!)-\(lastBg!)" : ""
        return "Widget background: publishes=\(publishesBg) reloads=\(reloadsBg) "
            + "dedup=\(dedupBg) unseen=\(unseenBg)\(window) "
            + "(only background reloads are charged against the OS budget, ~40-70/day)"
    }

    /// Requested vs SERVED — the two halves of the widget pipeline (260905).
    ///
    /// `requested` is what this app asked WidgetKit for; `served` is how many times the widget
    /// extension was actually asked to build a timeline. Reading them together is what makes the
    /// stale-widget question answerable:
    ///
    ///   * served >= requested — the pipeline is delivering; a stale face means the snapshot was
    ///     stale when it was read, so look upstream at the publish inputs.
    ///   * served much lower — iOS is dropping or deferring the reload requests, which is the
    ///     budget story, and the fix is to spend fewer background reloads (see `unseen`).
    ///   * served ~= the 15-minute policy's count (about 96/day) with requested high — our reloads
    ///     are not landing at all, which is a different bug from budget exhaustion.
    ///
    /// Note the extension is a separate process that iOS may never launch; a zero here with a live
    /// widget on screen is itself the finding.
    nonisolated static func servedLine(requested: Int, served: Int, lastServed: String?) -> String {
        #if !os(iOS)
        return ""   // no widgets on macOS; an always-zero line would read as a fault
        #else
        let last = lastServed.map { " last=\($0)" } ?? ""
        return "Widget timelines: requested=\(requested) served=\(served)\(last) "
            + "(served counts what the widget extension was actually asked to build)"
        #endif
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
