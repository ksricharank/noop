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
        static let pacingIntervalHours = "auto.pacing.intervalHours"    // default 2
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
    /// Check-in cadence: nudge-eligible at the top of every N hours through the waking window.
    static var pacingIntervalHours: Int {
        let v = d.object(forKey: K.pacingIntervalHours) as? Int ?? 2
        return min(max(v, 1), 6)
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

    /// The waking window steps and effort prorate over. The START is the day's ACTUAL wake — the
    /// end of the scored night's main sleep, falling back to the quiet-hours end until the night
    /// is scored (the caller resolves it; see `AppModel.pacingWakeMinute`) — because a fixed clock
    /// start misprices every early or late morning. The END is midnight, not the quiet-hours
    /// start: the maintainer walks late, and quiet hours (22:00–07:00) are a BLE window, not a
    /// claim about when movement stops. Calories are different: most of that target is resting
    /// burn accruing around the clock, so cal prorates over the full 24 h from local midnight.
    static let pacingDayEndMinute = 24 * 60
    /// Sanity bounds on the resolved wake minute (a mis-scored night must not produce a 2:00 or
    /// 15:00 "wake" that poisons every pace all day).
    static func clampWakeMinute(_ m: Int) -> Int { min(max(m, 4 * 60), 12 * 60) }

    struct PacingNudge: Equatable {
        let checkpointIndex: Int
        let title: String
        let body: String
        /// The lagging targets behind this nudge, for the coach-written title (260902). Carried on
        /// the decision rather than re-derived at the call site, so the line the model is asked to
        /// motivate and the rows the user reads can never describe different numbers.
        var behind: [BehindItem] = []
    }

    struct BehindItem: Equatable {
        let label: String
        let actual: Int
        let pace: Int
        let goal: Int
    }

    /// The check-in instants for a cadence: every `intervalHours` hours FROM THE WAKE ("check me
    /// every 2 hours from when I got up"). Exclusive of the window end — a midnight checkpoint
    /// could never fire (the day rolls first).
    static func checkpointMinutes(intervalHours: Int, dayStartMinute: Int) -> [Int] {
        let step = max(1, intervalHours) * 60
        return Array(stride(from: dayStartMinute + step, to: pacingDayEndMinute, by: step))
    }

    /// Evaluate the pacing check-ins. `firedMask` is a bitmask of checkpoint indices already
    /// handled today (fired OR evaluated-and-on-pace — one evaluation per checkpoint per day, so a
    /// nudge can't re-fire off every later sync). Returns the nudge to post (at most one — the
    /// LATEST due checkpoint, so a phone that slept through several evaluates today's pace once,
    /// against now) plus the updated mask; a checkpoint that is due but ON pace is consumed
    /// silently.
    ///
    /// "Behind" is the pace itself (260901 rewire, compacted 260902 to the maintainer's format):
    /// each target prorated linearly to NOW — steps and effort over the waking window, calories
    /// over the 24 h clock (see the window doc above) — no preset slack. One line per lagging
    /// target, `actual/pace/goal`, with a trailing catch-up number where one exists: the walk
    /// minutes that close the step deficit, or the still-open workout's minutes.
    static func pacingDecision(enabled: Bool, minuteOfDay: Int, intervalHours: Int,
                               dayStartMinute: Int,
                               firedMask: Int,
                               steps: Int?, stepsTarget: Int?,
                               kcalToday: Int?, kcalTarget: Int?,
                               effortToday: Int?, effortTarget: Int?,
                               sessionMinutes: Int?) -> (nudge: PacingNudge?, newMask: Int) {
        guard enabled else { return (nil, firedMask) }
        let checkMinutes = checkpointMinutes(intervalHours: intervalHours, dayStartMinute: dayStartMinute)
        var mask = firedMask
        var due: Int?
        for (i, checkMin) in checkMinutes.enumerated() where minuteOfDay >= checkMin && mask & (1 << i) == 0 {
            mask |= (1 << i)   // every passed checkpoint is consumed; only the latest is evaluated
            due = i
        }
        guard due != nil else { return (nil, mask) }
        let wakingFraction = min(1.0, max(0.0, Double(minuteOfDay - dayStartMinute)
                                               / Double(max(60, pacingDayEndMinute - dayStartMinute))))
        let clockFraction = min(1.0, max(0.0, Double(minuteOfDay) / Double(24 * 60)))
        var lines: [String] = []
        var behind: [BehindItem] = []
        if let target = stepsTarget, target > 0 {
            let pace = Int(Double(target) * wakingFraction)
            let actual = steps ?? 0
            if actual < pace {
                // Trailing number = walk minutes that close the DEFICIT (~100 steps/min).
                let walkMin = max(5, (pace - actual) / 100)
                lines.append("Steps \(actual)/\(pace)/\(target)  \(walkMin)")
                behind.append(BehindItem(label: "Steps", actual: actual, pace: pace, goal: target))
            }
        }
        if let target = kcalTarget, target > 0 {
            let pace = Int(Double(target) * clockFraction)
            let actual = kcalToday ?? 0
            if actual < pace {
                // Trailing number = walk minutes closing the kcal deficit, at the brisk-walk rule
                // of thumb (~4 kcal/min for an average adult). Coarse on purpose — a hint, not a
                // prescription; the honest per-user number would need the Keytel chain per line.
                let walkMin = max(5, (pace - actual) / 4)
                lines.append("Cal \(actual)/\(pace)/\(target)  \(walkMin)")
                behind.append(BehindItem(label: "Calories", actual: actual, pace: pace, goal: target))
            }
        }
        if let target = effortTarget, target > 0 {
            let pace = Int(Double(target) * wakingFraction)
            let actual = effortToday ?? 0
            if actual < pace {
                // Trailing number = the prescribed workout's minutes (doing it closes the gap).
                let workout = sessionMinutes.map { "  \($0)" } ?? ""
                lines.append("Effort \(actual)/\(pace)/\(target)\(workout)")
                behind.append(BehindItem(label: "Effort", actual: actual, pace: pace, goal: target))
            }
        }
        // On pace: consumed silently. Deliberately NOT an "on pace" notification — the widgets
        // already say so, and a nudge that fires when nothing is wanted is the fastest way to get
        // notifications muted. The encouraging voice lives in the coach TITLE of a real nudge (and
        // in the water reminder, which keeps firing past its goal by design).
        guard !lines.isEmpty else { return (nil, mask) }
        return (PacingNudge(checkpointIndex: due!,
                            title: String(localized: "Behind pace"),
                            body: lines.joined(separator: "\n"),
                            behind: behind), mask)
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
