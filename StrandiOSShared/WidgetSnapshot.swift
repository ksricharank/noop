import Foundation

/// Small, Codable glance snapshot shared between the iOS app and its widget/Live-Activity extension
/// via an App Group. The app writes it; the widget reads it. Keeping it tiny avoids any cross-process
/// database access — the widget never opens SQLite.
public struct WidgetSnapshot: Codable, Equatable {
    public var recovery: Int?    // Charge (0–100)
    public var bpm: Int?
    public var batteryPct: Int?
    public var bonded: Bool
    public var updated: Date
    // Richer glance fields (#446). All OPTIONAL with nil defaults so a snapshot written by an OLDER app
    // build (which never encoded these keys) still decodes — Codable fills a missing optional with nil.
    public var effort: Int?      // Effort / strain on NOOP's 0–100 axis (ring fill is always this / 100)
    public var rest: Int?        // Rest (sleep_performance) score, 0–100
    public var hrv: Int?         // HRV (ms), whole-number for the glance
    public var restingHr: Int?   // Resting heart rate (bpm)
    // #313 Effort scale for the glance. Pre-formatted at publish time because the widget extension
    // cannot read the app's plain UserDefaults `effort.scale` key (it lives outside the App Group).
    // When nil (older snapshot), the widget falls back to whole-number `effort` on the 0–100 axis.
    public var effortDisplay: String?
    /// True when `effortDisplay` is on WHOOP's 0–21 axis; false/nil means 0–100. Accessibility only.
    public var effortWhoop: Bool?
    /// The last `HrTrace.windowSec` of heart rate, one point per minute, for the trace widget (#1957).
    ///
    /// Folded in by `save()` rather than by the callers that build a snapshot, which is the twin of the
    /// Android store owning it: nothing that publishes had to learn the retention rule. Optional so a
    /// snapshot written by an older build still decodes.
    public var hrSeries: [HrPoint]?
    /// Today's hourly stress curve for the stress widget (#2040), earliest to latest.
    ///
    /// Unlike `hrSeries` this is NOT folded by `save()`. It arrives complete from the publish that
    /// scored the day, so a publish either carries a whole day or says nothing about stress at all, and
    /// the live fast path simply carries the loaded value forward untouched. Optional so a snapshot
    /// written by an older build still decodes.
    public var stressSeries: [StressPoint]?
    /// Local day number `stressSeries` was scored for, or nil when no curve has been published.
    ///
    /// Read back as the staleness check: a curve from any day but today is dropped rather than drawn,
    /// so the widget cannot show yesterday's afternoon under today's date while waiting for the first
    /// scorable hour after midnight.
    public var stressDay: Int?
    // The daily-targets glance trio (260830) — the fields behind the NOOP Targets widget, built for
    // running WITHOUT the Live Activity: the strap streams only overnight, and daytime data arrives
    // as ~15-minute offload bursts, so these are burst-cadence values, not live ones. Same optional
    // + nil-default decode-compatibility rule as `effort` above.
    // HISTORY: an `avgHr` field (mean HR over the freshest burst) led this block for one build
    // (10.6.0.14.9). Removed 260830 same-day by maintainer instruction — HR left the targets
    // surfaces entirely; the Effort n/t pair below took its column. A 14.9 snapshot's stray key
    // simply isn't decoded.
    /// Today's effort TARGET, pre-formatted on the user's chosen scale at publish time (same reason
    /// as `effortDisplay` above: the extension can't read the scale preference). The Effort column's
    /// denominator; `effortDisplay` is its numerator.
    public var effortTargetDisplay: String?
    /// Today's TOTAL calories so far (the raw whole-day HR estimate, resting metabolism included —
    /// `LiveTargets.kcalToday`).
    public var kcal: Int?
    /// Today's TOTAL-calorie target (a full resting day + the prescribed session via Keytel —
    /// `LiveTargets.kcalTargetKcal`). A REST day's target is the resting day alone.
    public var kcalTarget: Int?
    /// Minutes of sleep to target tonight (`LiveTargets.sleepNeedTonightMin`).
    public var sleepNeedMin: Int?
    /// Today's steps so far (the calibrated daily count) and today's step target
    /// (`LiveTargets.stepsToday` / `.stepsTarget`) — the Steps column's two sides.
    public var steps: Int?
    public var stepsTarget: Int?
    /// Today's water, in HALF-cups drunk so far and whole cups targeted (260903). Half-cups because
    /// that is the tracker's own resolution — the notification and the Today row both log half a cup
    /// — and rounding to whole cups at publish time would make a logged half-cup invisible on the
    /// widget until a second one landed. `waterTargetCups` is nil when hydration tracking is off,
    /// which is what makes the face degrade to a dash rather than to a fake zero.
    public var waterHalfCups: Int?
    public var waterTargetCups: Int?

    public init(recovery: Int?, bpm: Int?, batteryPct: Int?, bonded: Bool, updated: Date,
                effort: Int? = nil, rest: Int? = nil, hrv: Int? = nil, restingHr: Int? = nil,
                effortDisplay: String? = nil, effortWhoop: Bool? = nil,
                hrSeries: [HrPoint]? = nil, stressSeries: [StressPoint]? = nil,
                stressDay: Int? = nil,
                effortTargetDisplay: String? = nil, kcal: Int? = nil, kcalTarget: Int? = nil,
                sleepNeedMin: Int? = nil, steps: Int? = nil, stepsTarget: Int? = nil,
                waterHalfCups: Int? = nil, waterTargetCups: Int? = nil) {
        self.recovery = recovery
        self.bpm = bpm
        self.batteryPct = batteryPct
        self.bonded = bonded
        self.updated = updated
        self.effort = effort
        self.rest = rest
        self.hrv = hrv
        self.restingHr = restingHr
        self.effortDisplay = effortDisplay
        self.effortWhoop = effortWhoop
        self.hrSeries = hrSeries
        self.stressSeries = stressSeries
        self.stressDay = stressDay
        self.effortTargetDisplay = effortTargetDisplay
        self.kcal = kcal
        self.kcalTarget = kcalTarget
        self.sleepNeedMin = sleepNeedMin
        self.steps = steps
        self.stepsTarget = stepsTarget
        self.waterHalfCups = waterHalfCups
        self.waterTargetCups = waterTargetCups
    }

    /// The curve to DRAW: what was published, unless it belongs to a day that is over.
    ///
    /// Resolved on read rather than cleared on write, the same discipline `HrTrace.prune` applies to
    /// age: nothing runs at midnight to tidy the App Group, so the check has to happen where the value
    /// is used. Calendar is injectable so a test can cross a rollover without waiting for one.
    public func stressCurve(now: Date = Date(), calendar: Calendar = .current) -> [StressPoint] {
        guard let stressDay, let stressSeries,
              stressDay == WidgetSnapshot.localDayNumber(now, calendar: calendar) else { return [] }
        return stressSeries
    }

    /// Days since the epoch on the LOCAL calendar, corresponding to Kotlin's
    /// `LocalDate.toEpochDay()` built-in.
    ///
    /// Counted by the calendar rather than by dividing the day's start by 86 400. That arithmetic is
    /// wrong on a DST day and measurably so: walking a year of local noons, `Europe/London` produces
    /// ONE day whose number equals the previous day's, because its winter offset is UTC and a
    /// 23-hour day then lands inside the same 86 400-second bucket. On that day the widget would have
    /// read yesterday's curve as today's and drawn it, which is the one thing this number exists to
    /// prevent. The calendar knows how long each local day actually was.
    public static func localDayNumber(_ date: Date, calendar: Calendar = .current) -> Int {
        let epoch = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        return calendar.dateComponents([.day], from: epoch,
                                       to: calendar.startOfDay(for: date)).day ?? 0
    }

    // MARK: - Targets-trio display strings

    // Formatting lives HERE (StrandiOSShared, compiled into both the app and the widget extension)
    // rather than file-private in the widget, so StrandTests can pin it — the widget extension has no
    // test target of its own. Deliberately the same vocabulary as the Live Activity card
    // (NOOPLiveActivity.calText/sleepText): a person running both surfaces should never see the same
    // value spelled two ways.

    /// The Effort glance: today's effort over its target, both pre-formatted on the user's scale
    /// ("3.2/10.7"). Either side degrades alone — no target shows just today's number; no number yet
    /// shows "0/10.7", which a fresh day honestly is. Nil = neither side known.
    public var effortNT: String? {
        switch (effortDisplay, effortTargetDisplay) {
        case let (n?, t?): return "\(n)/\(t)"
        case let (n?, nil): return n
        case let (nil, t?): return "0/\(t)"
        case (nil, nil): return nil
        }
    }

    /// The Cal glance: TOTAL calories so far over today's total target ("1830/2650"). Either side
    /// degrades alone — no target shows just the count; no count yet shows "0/2650", which right
    /// after midnight honestly is. Nil = neither side known.
    public var calDisplay: String? {
        switch (kcal.map(String.init), kcalTarget.map(String.init)) {
        case let (c?, t?): return "\(c)/\(t)"
        case let (c?, nil): return c
        case let (nil, t?): return "0/\(t)"
        case (nil, nil): return nil
        }
    }

    /// Tonight's sleep target as "8h05" (minutes zero-padded so the glyph count is stable).
    public var sleepDisplay: String? {
        guard let need = sleepNeedMin, need > 0 else { return nil }
        return String(format: "%dh%02d", need / 60, need % 60)
    }

    /// The Water glance: cups drunk over today's cup target ("7/19").
    ///
    /// Deliberately rendered in WHOLE cups even though the tracker stores half-cups. Two reasons, one
    /// of them about battery: a widget cell has no room for "7.5/19" beside three other pairs, and —
    /// more importantly — the rendered string is what `renderedContentChanged` dedups on, so
    /// quantizing here means a half-cup log that does not move the whole-cup figure costs NO
    /// WidgetKit reload request. At the maintainer's ~16-21 cup target that roughly halves the
    /// requests this feature can spend against iOS's daily widget refresh budget (see the
    /// `renderedContentChanged` note on why that budget is the binding constraint).
    ///
    /// Rounds DOWN: a half-cup in hand is not a cup drunk, and the same floor is what the
    /// notification's "cups still to drink" already counts with.
    public var waterDisplay: String? {
        guard let target = waterTargetCups, target > 0 else { return nil }
        return "\((waterHalfCups ?? 0) / 2)/\(target)"
    }

    /// The Steps glance: today over target as FULL counts ("3205/8000") — the in-app strip and the
    /// Live Activity banner have the width for the real number. Same degrade rules as the Cal pair;
    /// a fresh day reads "0/8000".
    public var stepsDisplay: String? {
        pair(steps.map(String.init), stepsTarget.map(String.init))
    }

    // The WIDGET faces (260830, final slotting): abbreviated Steps and Cal — a Lock-Screen /
    // Home-Screen cell simply has no room for two four-digit pairs, and the maintainer confirmed
    // it after trying both ("otherwise there is no space"). The full-count displays above stay for
    // the surfaces that fit them; both spell their pair through the same degrade rules.

    /// Widget-face Steps pair, thousands-abbreviated ("3.2k/8k").
    public var stepsAbbrev: String? {
        pair(steps.map(Self.kAbbrev), stepsTarget.map(Self.kAbbrev))
    }

    /// Widget-face Cal pair, thousands-abbreviated ("1.2k/2.1k").
    public var calAbbrev: String? {
        pair(kcal.map(Self.kAbbrev), kcalTarget.map(Self.kAbbrev))
    }

    /// Thousands formatting: below 1,000 raw, else one decimal with a trailing ".0" dropped
    /// ("650", "3.2k", "8k").
    public static func kAbbrev(_ n: Int) -> String {
        guard n >= 1_000 else { return "\(n)" }
        let s = String(format: "%.1f", Double(n) / 1_000.0)
        return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + "k"
    }

    /// The shared now/target degrade rules: either side alone still renders, a missing numerator
    /// with a live target reads "0/target", and nothing at all reads nil.
    private func pair(_ n: String?, _ t: String?) -> String? {
        switch (n, t) {
        case let (n?, t?): return "\(n)/\(t)"
        case let (n?, nil): return n
        case let (nil, t?): return "0/\(t)"
        case (nil, nil): return nil
        }
    }

    /// App Group suite the app and widget both use. Injected from the `APP_GROUP_ID` build setting
    /// (see project.yml) via the `AppGroupIdentifier` Info.plist key, so the value lives in exactly
    /// one place rather than being duplicated here. Must match the `com.apple.security.application-groups`
    /// entitlement on both targets (which also reads `$(APP_GROUP_ID)`). If the entitlement is missing on
    /// either side, `UserDefaults(suiteName:)` returns nil and every consumer (PendingIntents,
    /// WidgetSnapshot.publish, Live Activity) silently no-ops — see `assertGroupProvisioned` for the
    /// debug-time canary. The fallback is the canonical upstream group and only applies if the Info.plist
    /// key is somehow absent (each process reads its OWN bundle, so the app and the widget extension
    /// each carry the key in their generated Info.plist).
    public static let suiteName: String = {
        resolveSuiteName(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }()
    public static let storageKey = "noop.widget.snapshot"

    /// Resolve the App Group the current signature actually grants.
    ///
    /// AltStore / SideStore must make every App Group unique to the user's signing team. During
    /// re-signing they append the team identifier to the group requested by the downloaded app and
    /// publish the resulting, provisioned identifiers in `ALTAppGroups` in each bundle's Info.plist.
    /// Reading only the build-time `AppGroupIdentifier` therefore points at an unprovisioned container
    /// in a sideloaded build, even though the host app and widget extension were both signed correctly.
    ///
    /// Normal Xcode builds don't carry `ALTAppGroups`, so they keep using `AppGroupIdentifier`.
    static func resolveSuiteName(infoDictionary: [String: Any]) -> String {
        let configured = (infoDictionary["AppGroupIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let altGroups = (infoDictionary["ALTAppGroups"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("group.") && !$0.isEmpty } ?? []

        if let configured, !configured.isEmpty,
           let provisioned = altGroups.first(where: {
               $0 == configured || $0.hasPrefix(configured + ".")
           }) {
            return provisioned
        }
        if altGroups.count == 1, let provisioned = altGroups.first {
            return provisioned
        }
        if let configured, !configured.isEmpty {
            return configured
        }
        return "group.com.noopapp.noop"
    }

    /// Debug-only canary: trips on the first run after a misprovisioning so the silent no-op gets
    /// caught immediately rather than masquerading as "widget shows nothing yet." Release builds do
    /// nothing — App Store apps can't crash on a missing entitlement.
    public static func assertGroupProvisioned() {
        assert(UserDefaults(suiteName: suiteName) != nil,
               "App Group '\(suiteName)' not provisioned on this target — check the entitlement.")
    }

    public static var placeholder: WidgetSnapshot {
        // Gallery / pre-publish stand-in: realistic Charge · Effort · Rest on the 0–100 axis so the
        // three-ring Home Screen layouts (and the large grid) preview with filled arcs, not dashes.
        WidgetSnapshot(recovery: 72, bpm: 58, batteryPct: 84, bonded: true, updated: Date(),
                       effort: 38, rest: 81, hrv: 64, restingHr: 52,
                       effortDisplay: "38", effortWhoop: false,
                       effortTargetDisplay: "51", kcal: 1830, kcalTarget: 2650, sleepNeedMin: 495,
                       steps: 6_214, stepsTarget: 8_000,
                       waterHalfCups: 15, waterTargetCups: 19)
    }

    /// Honest runtime state when the app has not published a readable snapshot yet. Unlike
    /// `placeholder`, this is user-visible and must never imply that sample data is real.
    static var unavailable: WidgetSnapshot {
        WidgetSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false, updated: .distantPast)
    }

    /// Read the last-published snapshot from the shared suite, if any.
    public static func load() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return nil }
        return snap
    }

    /// Persist this snapshot into the shared suite, folding the live bpm into the trace on the way.
    ///
    /// The fold happens HERE, not in the callers that build a snapshot, so nothing that publishes has to
    /// know the retention rule — the twin of the Android store owning it. A snapshot with no bpm leaves
    /// the stored trace alone rather than truncating it, so a quiet strap does not erase the history the
    /// widget is drawing.
    public func save() {
        save(previousSeries: WidgetSnapshot.load()?.hrSeries ?? [])
    }

    /// As `save()`, for a caller that already holds the stored snapshot.
    ///
    /// The publish path loads `previous` to decide whether anything changed, and `save()` was then
    /// decoding the same App Group blob a second time just to reach the trace. Handing the series in
    /// costs the caller nothing and removes a full JSON decode from every publish.
    public func save(previousSeries: [HrPoint]) {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) else { return }
        var toStore = self
        let previous = previousSeries
        let nowSec = Int64(updated.timeIntervalSince1970)
        toStore.hrSeries = bpm.map { HrTrace.append(previous, ts: nowSec, bpm: $0, nowSec: nowSec) }
            ?? HrTrace.prune(previous, nowSec: nowSec)
        guard let data = try? JSONEncoder().encode(toStore) else { return }
        defaults.set(data, forKey: WidgetSnapshot.storageKey)
    }

    /// Does the TRACE need a point, even though nothing the header renders has changed?
    ///
    /// `renderedContentChanged` compares bpm, not history, so a steady heart — the ordinary case at rest
    /// — produced no publish and therefore no new trace point. The trace would stop advancing while the
    /// strap streamed happily, and pruning would eventually empty it. Android does not have this problem
    /// because its PushGate re-admits an unchanged key once a minute; this is that rule.
    ///
    /// Keyed on the BUCKET rather than elapsed seconds, so it asks for a write exactly when
    /// `HrTrace.append` would actually record one, and never more often.
    static func traceNeedsPoint(previous: WidgetSnapshot?, bpm: Int?, now: Date) -> Bool {
        guard let bpm, bpm > 0 else { return false }
        guard let last = previous?.hrSeries?.last else { return true }
        return Int64(now.timeIntervalSince1970) / HrTrace.bucketSec > last.ts / HrTrace.bucketSec
    }

    /// Whether publishing `next` would change anything the widget actually renders. `updated` is
    /// deliberately excluded: no widget family displays it, and treating a fresh timestamp as content
    /// would defeat deduplication because every otherwise-identical build creates a new date.
    ///
    /// Shared by the full score publish and the live-only fast path so a redundant foreground, repository,
    /// battery, or connection signal does not rewrite App-Group defaults and ask WidgetKit to rebuild an
    /// identical timeline. nil means the app has never published, so the first snapshot always writes.
    /// What the WIDGET EXTENSION did, recorded by the extension into the shared App Group (260905).
    ///
    /// The gap this closes: everything else on the publish path measures what the APP requested.
    /// Nothing measured what WidgetKit actually SERVED. Those are the two halves of "the widget
    /// lags behind the app", and without the second one the diagnosis stops at a guess —
    ///
    ///   * app requested N reloads, extension served ~N timelines → the pipeline works, and a stale
    ///     face means the snapshot itself was stale when read;
    ///   * app requested N, extension served far fewer → iOS is dropping or deferring the requests,
    ///     which is the budget story and is fixed by spending fewer background reloads;
    ///   * extension served timelines on the 15-minute policy only → our reload requests are not
    ///     landing at all, a different bug entirely.
    ///
    /// Deliberately the cheapest thing that can distinguish those: two integers and a timestamp,
    /// written where `getTimeline` already runs, formatted only when the log is exported. The
    /// extension is memory-constrained and killed aggressively, so this must not allocate or block.
    public enum ExtensionStats {
        private static let servedKey = "wps.ext.served"
        private static let servedDayKey = "wps.ext.servedDay"
        private static let lastServedKey = "wps.ext.lastServedAt"
        /// 260906: when the APP last requested a reload, written by the app and read by the
        /// extension. The pair (this, the moment getTimeline runs) is the only way to see the half of
        /// the pipeline the app cannot observe on its own.
        private static let reloadRequestedAtKey = "wps.ext.reloadRequestedAt"
        /// Cumulative and worst-case milliseconds between a reload request and the extension actually
        /// being asked to build. Day-keyed alongside `served`.
        private static let lagSumMsKey = "wps.ext.lagSumMs"
        private static let lagCountKey = "wps.ext.lagCount"
        private static let lagMaxMsKey = "wps.ext.lagMaxMs"

        private static var store: UserDefaults? { UserDefaults(suiteName: WidgetSnapshot.suiteName) }

        /// Called by the APP the moment it asks WidgetKit for a reload.
        ///
        /// 260906. The 260906 log proved our side of the pipeline is healthy — `unseen=0` (we never
        /// sat on a change) and `served=60` against `requested=28` (iOS built MORE timelines than we
        /// asked for) — and yet the faces still visibly trail the app. That leaves exactly two places
        /// the delay can live, and the existing counters cannot tell them apart:
        ///
        ///   1. between our reload request and `getTimeline` running (WidgetKit scheduling), or
        ///   2. between `getTimeline` returning and the system compositing the new view.
        ///
        /// Stamping the request here and measuring against the moment the extension runs settles (1)
        /// directly. A small average with a stale-looking widget then points at (2), which is outside
        /// anything the app controls and would end the search honestly rather than inviting another
        /// speculative fix.
        ///
        /// One `Double` write on a path that already talks to the App Group.
        public static func recordReloadRequested(now: Date = Date()) {
            store?.set(now.timeIntervalSince1970, forKey: reloadRequestedAtKey)
        }

        /// 260906: how many BACKGROUND reloads the app has spent today, written by the app so the
        /// EXTENSION can pace its own `.after` interval against the same budget.
        ///
        /// The extension cannot link the app module, so this rides the App Group the two already
        /// share — the same arrangement `recordTimelineServed` uses in the other direction. Only the
        /// count crosses; the policy that reads it lives in `WidgetReloadBudget`, compiled into both.
        private static let bgSpentKey = "wps.ext.bgSpent"
        private static let bgSpentDayKey = "wps.ext.bgSpentDay"

        /// Called by the app whenever its background-reload spend changes.
        public static func publishBudgetSpend(_ used: Int, dayKey: String) {
            guard let d = store else { return }
            d.set(dayKey, forKey: bgSpentDayKey)
            d.set(used, forKey: bgSpentKey)
        }

        /// Read by the extension. Zero when the stored day is not today — a stale count must not make
        /// the extension think the budget is spent and stretch its interval for a fresh day.
        public static func budgetSpent(dayKey: String) -> Int {
            guard let d = store, d.string(forKey: bgSpentDayKey) == dayKey else { return 0 }
            return d.integer(forKey: bgSpentKey)
        }

        /// The lag stats for the day, or nil when nothing has been measured yet.
        public static func lag(dayKey: String) -> (count: Int, meanMs: Int, maxMs: Int)? {
            guard let d = store, d.string(forKey: servedDayKey) == dayKey else { return nil }
            let n = d.integer(forKey: lagCountKey)
            guard n > 0 else { return nil }
            return (n, d.integer(forKey: lagSumMsKey) / n, d.integer(forKey: lagMaxMsKey))
        }

        /// Called from `getTimeline`. Day-keyed like the app-side counters so the two lines describe
        /// the same window.
        public static func recordTimelineServed(now: Date = Date(), dayKey: String) {
            guard let d = store else { return }
            if d.string(forKey: servedDayKey) != dayKey {
                d.set(dayKey, forKey: servedDayKey)
                d.set(0, forKey: servedKey)
                // The lag accumulators are day-keyed with the counter they sit beside, or a single
                // overnight outlier would follow the mean around for the rest of the week.
                for k in [lagSumMsKey, lagCountKey, lagMaxMsKey] { d.set(0, forKey: k) }
            }
            d.set(d.integer(forKey: servedKey) + 1, forKey: servedKey)
            d.set(now.timeIntervalSince1970, forKey: lastServedKey)
            // 260906: how long WidgetKit took to act on the app's request. Only measured when a
            // request is actually outstanding — WidgetKit also refreshes on its own schedule (the
            // `.after` policy), and timing those against a stale request would invent a lag that
            // nobody waited on. The stamp is consumed so each request is counted at most once.
            let requestedAt = d.double(forKey: reloadRequestedAtKey)
            if requestedAt > 0 {
                let ms = Int((now.timeIntervalSince1970 - requestedAt) * 1000)
                // A negative or absurd value means the clock moved or the stamp outlived its request
                // (a day roll, a restore). Discard rather than bank a number that cannot be true.
                if ms >= 0, ms < 6 * 60 * 60 * 1000 {
                    d.set(d.integer(forKey: lagSumMsKey) + ms, forKey: lagSumMsKey)
                    d.set(d.integer(forKey: lagCountKey) + 1, forKey: lagCountKey)
                    if ms > d.integer(forKey: lagMaxMsKey) { d.set(ms, forKey: lagMaxMsKey) }
                }
                d.removeObject(forKey: reloadRequestedAtKey)
            }
        }

        /// Read back by the app for the log header.
        public static func served(dayKey: String) -> (count: Int, lastAt: Date?) {
            guard let d = store, d.string(forKey: servedDayKey) == dayKey else { return (0, nil) }
            let ts = d.double(forKey: lastServedKey)
            return (d.integer(forKey: servedKey), ts > 0 ? Date(timeIntervalSince1970: ts) : nil)
        }

        public static func reset() {
            guard let d = store else { return }
            for k in [servedKey, servedDayKey, lastServedKey, reloadRequestedAtKey,
                      lagSumMsKey, lagCountKey, lagMaxMsKey,
                      bgSpentKey, bgSpentDayKey] { d.removeObject(forKey: k) }
        }
    }

    /// Fields the dedup compares that NO installed widget face actually renders (260905).
    ///
    /// `sleepDisplay` is the live example: it was on the targets faces until water took Sleep's
    /// fourth cell (260903), and the dedup comparison stayed behind. A night's sleep figure moving
    /// therefore still requests a WidgetKit reload for a repaint nobody can see — and in the
    /// BACKGROUND that is charged against the ~40-70/day budget, so it is spent directly out of the
    /// allowance the visible updates need.
    ///
    /// MEASURED, NOT REMOVED. The instrumentation-first rule applies: this predicts wasted reloads
    /// and the next strap log says how many. Dropping the comparison outright would also be wrong
    /// in one real case — `sleepDisplay` still appears in the glance string, so a snapshot whose
    /// only change is sleep must still be SAVED, just not repainted. That is a different change
    /// from deleting the comparison, and worth making only once the count justifies it.
    ///
    /// Returns true when `next` differs from `previous` ONLY in these fields — i.e. the reload this
    /// publish is about to request cannot change a pixel.
    static func changedOnlyInUnrenderedFields(from previous: WidgetSnapshot?,
                                              to next: WidgetSnapshot) -> Bool {
        guard let previous else { return false }
        guard renderedContentChanged(from: previous, to: next) else { return false }
        // Neutralise the unrendered fields and re-ask: if nothing else moved, the change was
        // invisible. Comparing this way rather than listing the visible fields again means the two
        // can never drift apart — a field added to the dedup is automatically counted as visible
        // until it is explicitly named here.
        var probe = next
        probe.sleepNeedMin = previous.sleepNeedMin   // backs `sleepDisplay`
        return !renderedContentChanged(from: previous, to: probe)
    }

    static func renderedContentChanged(from previous: WidgetSnapshot?, to next: WidgetSnapshot) -> Bool {
        guard let previous else { return true }
        return previous.recovery != next.recovery
            || previous.bpm != next.bpm
            || previous.batteryPct != next.batteryPct
            || previous.bonded != next.bonded
            || previous.effort != next.effort
            || previous.rest != next.rest
            || previous.hrv != next.hrv
            || previous.restingHr != next.restingHr
            || previous.effortDisplay != next.effortDisplay
            || previous.effortWhoop != next.effortWhoop
            // The curve joins the comparison (#2040): a publish that scored a fresh hour and changed
            // nothing else would otherwise be deduped away, and the widget would sit an hour behind
            // until some unrelated field moved. The DAY joins it too, so the first publish after
            // midnight still reaches WidgetKit even when the new day has no scored hour yet.
            || previous.stressSeries != next.stressSeries
            || previous.stressDay != next.stressDay
            || previous.effortTargetDisplay != next.effortTargetDisplay
            // Cal / Steps / Sleep compare at DISPLAY granularity (260831): every snapshot-fed widget
            // face renders the ABBREVIATED pairs ("4.1k/10k") and the "8h30" sleep string — the raw
            // ints are not rendered anywhere the snapshot feeds. Comparing the raw ints requested a
            // WidgetKit reload for changes no face could show (1712→1739 kcal renders identically),
            // and with the background light pass moving these values every ~10-min sync that burned
            // ~90+ reload requests/day against a background budget of roughly 40–70 — so iOS deferred
            // exactly the repaints that DID matter. The displays quantize naturally (steps per 100,
            // cal per 100 above 1k, sleep per minute), keeping requests well inside budget while
            // never skipping a change a face would actually paint.
            || previous.calAbbrev != next.calAbbrev
            || previous.sleepDisplay != next.sleepDisplay
            || previous.stepsAbbrev != next.stepsAbbrev
            // Water compares at display granularity for the same reason, and it matters more here:
            // a cup is logged by a deliberate tap that ALSO triggers a publish, so without the
            // whole-cup quantization every half-cup would spend a reload request.
            || previous.waterDisplay != next.waterDisplay
    }

    /// A live-only update may reuse score fields only within the same local calendar day. At rollover,
    /// the full publisher must resolve `Repository.widgetAnchor` again so yesterday's Charge/Rest cannot
    /// be carried forward indefinitely by a stream of HR updates. Calendar is injectable for deterministic
    /// tests; production uses the user's current calendar and time zone.
    static func liveUpdateRequiresFullBuild(previous: WidgetSnapshot?, now: Date,
                                            calendar: Calendar = .current) -> Bool {
        guard let previous else { return true }
        return !calendar.isDate(previous.updated, inSameDayAs: now)
    }
}
