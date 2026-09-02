import Foundation
import UserNotifications

/// The two target-driven notification automations (260901, maintainer-picked from the automation
/// menu): the MORNING BRIEF (A — the day's numbers arrive as a notification the moment the first
/// post-wake score lands, before the app is ever opened) and TARGET PACING (E — proactive
/// catch-up nudges at user-chosen afternoon/evening check-ins when the day is running behind its
/// targets, deliberately a nudge toward action rather than a status update the widgets already
/// give). Both default OFF, both ride the existing post-offload refresh (no new background work),
/// both post through the OS notification center gated on each feature's own toggle plus system
/// authorization. The wind-down reminder's dynamic sleep-target need (B) lives on the existing
/// `WindDownNudge` — an option on that automation, never a duplicate of it.
///
/// The DECISIONS are pure static functions over plain values, so StrandTests pins when each fires
/// and what it says without UserDefaults, a clock, or a notification center.
enum TargetAutomations {

    // MARK: - Prefs (UserDefaults-backed; UI in AutomationsView)

    enum K {
        static let briefEnabled = "auto.morningBrief.enabled"
        static let briefEarliestMin = "auto.morningBrief.earliestMin"   // default 06:00
        static let briefLastDay = "auto.morningBrief.lastDay"
        static let pacingEnabled = "auto.pacing.enabled"
        static let pacingCheck1Min = "auto.pacing.check1Min"            // default 14:00
        static let pacingCheck2Min = "auto.pacing.check2Min"            // default 18:00
        static let pacingThresholdPct = "auto.pacing.thresholdPct"      // default 60
        static let pacingDay = "auto.pacing.day"
        static let pacingFiredMask = "auto.pacing.firedMask"
    }

    private static var d: UserDefaults { .standard }

    static var briefEnabled: Bool { d.bool(forKey: K.briefEnabled) }
    static var briefEarliestMinute: Int {
        let v = d.object(forKey: K.briefEarliestMin) as? Int ?? 6 * 60
        return min(max(v, 4 * 60), 12 * 60)   // 04:00 (the day-roll) … noon
    }
    static var pacingEnabled: Bool { d.bool(forKey: K.pacingEnabled) }
    static var pacingCheckMinutes: [Int] {
        let c1 = d.object(forKey: K.pacingCheck1Min) as? Int ?? 14 * 60
        let c2 = d.object(forKey: K.pacingCheck2Min) as? Int ?? 18 * 60
        return [c1, c2].map { min(max($0, 9 * 60), 21 * 60) }   // 09:00…21:00, waking hours
    }
    static var pacingThresholdPct: Int {
        let v = d.object(forKey: K.pacingThresholdPct) as? Int ?? 60
        return min(max(v, 30), 90)
    }

    // MARK: - A: morning brief (pure decision + text)

    /// Should the brief fire NOW? Exactly once per local day, only after the earliest-delivery
    /// time, and only once the morning score has actually landed (the anchor row is TODAY's row —
    /// before that the targets are still yesterday's carry, and a brief would restate stale
    /// denominators the user already saw).
    static func briefWanted(enabled: Bool, anchorDay: String?, todayKey: String,
                            minuteOfDay: Int, earliestMinute: Int, lastFiredDay: String?) -> Bool {
        guard enabled else { return false }
        guard anchorDay == todayKey else { return false }
        guard minuteOfDay >= earliestMinute else { return false }
        return lastFiredDay != todayKey
    }

    /// The brief's copy — the same numbers the strip shows, one line. Every piece degrades alone.
    static func briefText(charge: Int?, sessionMinutes: Int?, sessionHrBpm: Int?,
                          restDay: Bool, sleepNeedMin: Int?, stepsTarget: Int?) -> (title: String, body: String) {
        var parts: [String] = []
        if let charge { parts.append("Charge \(charge)") }
        if restDay {
            parts.append("rest day — no workout")
        } else if let m = sessionMinutes {
            parts.append(sessionHrBpm.map { "\(m) min workout @ ~\($0) bpm" } ?? "\(m) min workout")
        }
        if let steps = stepsTarget { parts.append("\(steps) steps") }
        if let need = sleepNeedMin, need > 0 {
            parts.append(String(format: "sleep %dh%02d tonight", need / 60, need % 60))
        }
        return (title: String(localized: "Today's targets"),
                body: parts.isEmpty ? String(localized: "Scored — open NOOP for today's plan.")
                                    : parts.joined(separator: " · "))
    }

    // MARK: - E: target pacing (pure decision + text)

    /// The waking window pace is prorated over — a plain, stated assumption (steps and calories
    /// accrue between these hours), not a model.
    static let pacingDayStartMinute = 8 * 60
    static let pacingDayEndMinute = 22 * 60

    struct PacingNudge: Equatable {
        let checkpointIndex: Int
        let title: String
        let body: String
    }

    /// Evaluate the pacing check-ins. `firedMask` is a bitmask of checkpoint indices already
    /// handled today (fired OR evaluated-and-on-pace — one evaluation per checkpoint per day, so a
    /// nudge can't re-fire off every later sync). Returns the nudge to post (at most one — the
    /// earliest due checkpoint) plus the updated mask; a checkpoint that is due but ON pace is
    /// consumed silently.
    static func pacingDecision(enabled: Bool, minuteOfDay: Int, checkMinutes: [Int],
                               firedMask: Int, thresholdPct: Int,
                               steps: Int?, stepsTarget: Int?,
                               effortToday: Int?, effortTarget: Int?,
                               sessionMinutes: Int?) -> (nudge: PacingNudge?, newMask: Int) {
        guard enabled else { return (nil, firedMask) }
        var mask = firedMask
        for (i, checkMin) in checkMinutes.enumerated() {
            guard minuteOfDay >= checkMin, mask & (1 << i) == 0 else { continue }
            mask |= (1 << i)
            // Prorate the step target over the waking window: by `checkMin`, `fraction` of the
            // day's movement time has passed, so being under `threshold%` of the prorated target
            // is "behind pace" — the deliberate slack means a lunch walk still counts as on-pace.
            let fraction = min(1.0, max(0.0, Double(minuteOfDay - pacingDayStartMinute)
                                             / Double(pacingDayEndMinute - pacingDayStartMinute)))
            var lines: [String] = []
            if let target = stepsTarget, target > 0 {
                let expected = Int(Double(target) * fraction)
                let actual = steps ?? 0
                if expected > 0, actual < expected * thresholdPct / 100 {
                    // ~100 steps/min of ordinary walking — a concrete, doable catch-up ask.
                    let remaining = target - actual
                    let walkMin = max(5, remaining / 100)
                    lines.append("\(actual) of \(target) steps — about \(walkMin) min of walking to get there")
                }
            }
            if let target = effortTarget, target > 0, let m = sessionMinutes {
                let actual = effortToday ?? 0
                if actual < target * thresholdPct / 100 {
                    lines.append("your \(m) min workout is still open (effort \(actual) of \(target))")
                }
            }
            guard !lines.isEmpty else { return (nil, mask) }   // on pace: consume silently
            return (PacingNudge(checkpointIndex: i,
                                title: String(localized: "Pace check"),
                                body: lines.joined(separator: " · ")), mask)
        }
        return (nil, mask)
    }

    // MARK: - Day-keyed fire bookkeeping

    static func briefLastFiredDay() -> String? { d.string(forKey: K.briefLastDay) }
    static func markBriefFired(day: String) { d.set(day, forKey: K.briefLastDay) }

    static func pacingFiredMask(today: String) -> Int {
        guard d.string(forKey: K.pacingDay) == today else { return 0 }
        return d.integer(forKey: K.pacingFiredMask)
    }
    static func setPacingFiredMask(_ mask: Int, today: String) {
        d.set(today, forKey: K.pacingDay)
        d.set(mask, forKey: K.pacingFiredMask)
    }

    // MARK: - Posting

    /// Ask for notification permission at the moment of intent (the BreatheNotifier idiom) —
    /// called when either toggle is switched on.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post one automation notification. Gated on OS authorization only — the caller's own toggle
    /// is the feature gate (deliberately NOT the wrist-alerts master: these are phone
    /// notifications a user without wrist buzzes must still receive). A fixed identifier per
    /// automation means a fresh alert replaces the previous one rather than stacking.
    static func post(identifier: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
}
