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

    public init(recovery: Int?, bpm: Int?, batteryPct: Int?, bonded: Bool, updated: Date,
                effort: Int? = nil, rest: Int? = nil, hrv: Int? = nil, restingHr: Int? = nil,
                effortDisplay: String? = nil, effortWhoop: Bool? = nil,
                effortTargetDisplay: String? = nil, kcal: Int? = nil, kcalTarget: Int? = nil,
                sleepNeedMin: Int? = nil, steps: Int? = nil, stepsTarget: Int? = nil) {
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
        self.effortTargetDisplay = effortTargetDisplay
        self.kcal = kcal
        self.kcalTarget = kcalTarget
        self.sleepNeedMin = sleepNeedMin
        self.steps = steps
        self.stepsTarget = stepsTarget
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

    /// The Steps glance: today over target in thousands ("6.2k/8k") — step counts don't carry glance
    /// meaning below the hundreds, and four raw-digit pairs would not fit a stat row. Same degrade
    /// rules as the Cal pair; a fresh day reads "0/8k".
    public var stepsDisplay: String? {
        switch (steps.map(Self.stepsK), stepsTarget.map(Self.stepsK)) {
        case let (n?, t?): return "\(n)/\(t)"
        case let (n?, nil): return n
        case let (nil, t?): return "0/\(t)"
        case (nil, nil): return nil
        }
    }

    /// Thousands formatting for step counts: below 1,000 raw, else one decimal with a trailing ".0"
    /// dropped ("650", "6.2k", "8k").
    public static func stepsK(_ n: Int) -> String {
        guard n >= 1_000 else { return "\(n)" }
        let s = String(format: "%.1f", Double(n) / 1_000.0)
        return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + "k"
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
                       steps: 6_214, stepsTarget: 8_000)
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

    /// Persist this snapshot into the shared suite.
    public func save() {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: WidgetSnapshot.storageKey)
    }

    /// Whether publishing `next` would change anything the widget actually renders. `updated` is
    /// deliberately excluded: no widget family displays it, and treating a fresh timestamp as content
    /// would defeat deduplication because every otherwise-identical build creates a new date.
    ///
    /// Shared by the full score publish and the live-only fast path so a redundant foreground, repository,
    /// battery, or connection signal does not rewrite App-Group defaults and ask WidgetKit to rebuild an
    /// identical timeline. nil means the app has never published, so the first snapshot always writes.
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
            || previous.effortTargetDisplay != next.effortTargetDisplay
            || previous.kcal != next.kcal
            || previous.kcalTarget != next.kcalTarget
            || previous.sleepNeedMin != next.sleepNeedMin
            || previous.steps != next.steps
            || previous.stepsTarget != next.stepsTarget
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
