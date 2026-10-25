import Foundation
import WhoopProtocol

/// NSS — the Normalized Stress Score (fork, 261024). A 0–100 live read of how much harder my heart is
/// working, and how much less variable it is, than the activity I am doing right now explains.
///
/// WHY IT EXISTS. The Stress tab's two 0–3 scores cannot see stress while I am moving: the daily score
/// is a once-a-night read of resting HR and HRV, and the daytime timeline masks every ambulatory hour
/// and scores the rest against TODAY's own calm hours, an hour at a time, so it runs flat. The
/// maintainer asked for one number that moves through the day, walks included. The method is the
/// ambulatory-psychophysiology idea usually called "additional heart rate": physical activity explains
/// most of a heart-rate or HRV change, and what is left over after subtracting what this activity alone
/// should cause is the stress-like part.
///
/// THE METHOD (261024; the baseline and scale re-cut 261024d at the maintainer's ask):
/// 1. A CALM REFERENCE PER PACE. From the last `baselineDays` days of waking-hour data (default 21, the
///    long pass's window; the wearer can change it on the Stress tab), every 5-minute window gets a
///    `Pace` (strap locomotion ticks per minute, and wrist motion for movement without steps) and three
///    observations: mean HR, ln Baevsky SI, ln RMSSD. Per pace, the reference is my CALMEST typical
///    state — the 10th percentile of HR and SI, the 90th of RMSSD — not the median. The maintainer's
///    reasoning: even if most of the window was stressful, the calmest tenth is still calm, so stress
///    cannot become the baseline. A low PERCENTILE rather than the minimum, because the single lowest
///    window is usually a sensor glitch or a doze, and everything would read as stressed against it.
///    The spread is a robust SD (1.4826 × MAD around the pace's median).
/// 2. RESIDUALS over a rolling 5-minute window, as z's against that spread, above the calm reference:
///    zHR = (HR − HR_calm) / sd, zSI = (ln SI − ln SI_calm) / sd, zRMSSD = (ln RMSSD_calm − ln RMSSD) / sd.
/// 3. COMBINE: E = 0.40·zHR + 0.35·zSI + 0.25·zRMSSD (a missing HRV term dropped and the weights
///    renormalised, so heart rate alone still scores); NSS = 20 × E, clamped to 0–100; smoothed by an
///    EMA (α = 0.2 per 1-minute step, reset after a 10-minute gap). Each z is clamped to ±5.
///
/// SCALE (a FIXED scale, deliberately not stretched to the window — the maintainer first asked for
/// 0 = the window's low, 100 = its high, 50 = its average, and took this instead once it was shown that
/// a stretched scale would map a stressful fortnight onto "50, normal" and a calm one's wobble onto 100):
/// 0 = my calm state at this pace; each 20 points = one typical swing above it; 100 = five swings.
/// What is NORMAL for me is reported beside it, not pinned to a number: my TYPICAL is the median NSS of
/// the window's history, and "UNUSUAL FOR ME" is its 95th percentile, held for `unusualMinMinutes`
/// (see `lastEpisode`). So a stressful stretch stays high on the scale AND raises my typical, which is
/// itself worth seeing; a spike always reads as a spike.
///
/// HONEST LIMITS (also stated wherever the number is shown):
/// - It measures EXCESS SYMPATHETIC DRIVE, not mental stress as such. Heat, caffeine, digestion, sleep
///   debt, illness and talking all show up as residual too; mental load is the biggest remaining
///   explanation once activity is accounted for, but the formula cannot prove the cause.
/// - It saturates at high intensity: near max HR, HRV is already floored and residuals compress. RUNNING
///   pace is not scored at all. Best from rest through moderate activity — desk, walking, chores.
/// - EXERCISE is not scored either (261025, `exerciseMarks`): pace comes from steps, and a step-light
///   sport reads as a walk. The 261025 log had pickleball at "walk" pace, 116–143 bpm against a calm walk
///   of 90, scored 89. So a window at exercise-level HR (`exerciseHRRFraction` of heart-rate reserve),
///   at running pace, or inside a logged workout is EXERCISE, and the `recoveryMinutes` after it are
///   RECOVERY (that log read 70 sitting at 97 bpm ten minutes after the game). Both are left out of
///   today's readings AND of the history the calm reference and my typical are learned from.
/// - Movement without steps (cycling, arm work) gets its own pace bin, but its baseline is only as good
///   as the history of that kind of movement.
/// - Time-domain only (HR, RMSSD, Baevsky): step cadence entrains heart rate and corrupts frequency
///   bands while moving. Baevsky needs a stable histogram, hence 5-minute windows and cleaned R-R
///   (`HRVAnalyzer.cleanRR`, ectopic rejection) — one missed beat wrecks SI far more than RMSSD.
/// - Daytime wrist R-R is noisy (see `DaytimeStress.daytimeRMSSDScoringEnabled`). The HRV terms carry
///   60% of the weight here only because they are residuals against MY OWN same-pace history, where the
///   noise is part of the baseline spread; if the score proves jumpy, those weights are the dial.
/// - Unvalidated: a new derived signal. Every update logs its inputs (`nss:` lines) so it can be checked
///   against moments the wearer knows were stressful or calm, on several days, before it is trusted.
///
/// Fork-only (the maintainer's iPhone build): no Kotlin twin, by the parity rule's fork exemption.
/// Pure and store-free: the caller reads the streams and persists the windows (`NormalizedStressStore`).
public enum NormalizedStress {

    // MARK: - Tunables

    /// Window length for every observation (5 min: "Baevsky needs beats … 5 minutes is stable").
    public static let windowSeconds = 300
    /// Minimum HR samples in a window before its mean HR counts (half coverage at 1 Hz).
    public static let minWindowHRSamples = 150
    /// History the calm reference is learned from, by default — the long pass's 21-day window. The
    /// wearer's own setting (`NormalizedStressStore.baselineDaysKey`) overrides it.
    public static let defaultBaselineDays = 21
    /// The calm reference: this percentile of HR and SI (and 1 − this of RMSSD) per pace.
    public static let calmPercentile = 0.10
    /// NSS points per typical swing (one robust SD of combined excess) above calm.
    public static let pointsPerSwing = 20.0
    /// "Unusual for me": this percentile of the window's history NSS.
    public static let unusualPercentile = 0.95
    /// A pace needs at least this many windows of history (one hour) before it is scored.
    public static let minWindowsPerPace = 12
    /// EMA weight on the new raw value, per 1-minute step.
    public static let emaAlpha = 0.2
    /// A gap longer than this between scored windows restarts the EMA instead of bridging it.
    public static let emaResetGapSeconds = 600
    /// Residual weights (HR, Baevsky SI, RMSSD) — the spec's 0.4 / 0.35 / 0.25.
    public static let weightHR = 0.40
    public static let weightSI = 0.35
    public static let weightRMSSD = 0.25
    /// Each z is clamped to ±this before combining (five swings fill the scale).
    public static let zClamp = 5.0
    /// Robust-SD floors, so a very consistent pace cannot turn a tiny wobble into a big z.
    public static let minSdHR = 2.0
    public static let minSdLn = 0.05
    /// How long readings must hold at or above the "unusual" level to count as an episode.
    public static let unusualMinMinutes = 10
    /// Pace thresholds in raw strap locomotion ticks per minute (`StepsCounter`, before the per-user
    /// ticks-per-step calibration). The bins only group like with like: each bin's reference is MY OWN
    /// calm state at it, so the exact cut points matter far less than they would against population norms.
    public static let lightTicksPerMin = 5.0
    public static let walkTicksPerMin = 40.0
    public static let briskTicksPerMin = 95.0
    public static let runTicksPerMin = 140.0
    /// 261025: a window whose mean HR is at or above this share of heart-rate reserve above resting is
    /// exercise — the same 50% line the day calorie model uses for exercise-level HR
    /// (`Calories.dayActiveHRRFraction`). Stress alone very rarely holds HR there for five minutes.
    public static let exerciseHRRFraction = 0.50
    /// 261025: how long after exercise ends the windows stay unscored while HR comes back down.
    public static let recoveryMinutes = 30
    /// Share of a window's wrist-motion records above the walk floor that makes a step-less window
    /// "moving without steps" rather than still — the same 30% `DaytimeStress` masks an hour at.
    public static let motionActiveFraction = 0.30

    // MARK: - Types

    /// How I was moving during a window.
    public enum Pace: String, Codable, CaseIterable, Sendable {
        case still, light, walk, brisk, run, movingNoSteps

        /// Running is not scored: near max effort the residuals compress (see the type doc).
        public var isScored: Bool { self != .run }

        /// Plain words for the coach and the screen.
        public var phrase: String {
            switch self {
            case .still: return "still"
            case .light: return "pottering about"
            case .walk: return "walking"
            case .brisk: return "walking briskly"
            case .run: return "running"
            case .movingNoSteps: return "moving without steps"
            }
        }
    }

    /// One 5-minute observation, ending at `endTs` (wall-clock unix seconds).
    public struct Window: Codable, Equatable, Sendable {
        public let endTs: Int
        public let pace: Pace
        public let hr: Double
        public let lnSI: Double?
        public let lnRMSSD: Double?

        public init(endTs: Int, pace: Pace, hr: Double, lnSI: Double?, lnRMSSD: Double?) {
            self.endTs = endTs; self.pace = pace; self.hr = hr; self.lnSI = lnSI; self.lnRMSSD = lnRMSSD
        }
    }

    /// One pace's CALM reference (HR and SI at the 10th percentile, RMSSD at the 90th) and residual
    /// spreads (robust SDs). The HRV terms are nil when the pace had too few windows with clean beats.
    public struct PaceBaseline: Codable, Equatable, Sendable {
        public let pace: Pace
        public let windows: Int
        public let hr: Double
        public let sdHR: Double
        public let lnSI: Double?
        public let sdSI: Double?
        public let lnRMSSD: Double?
        public let sdRMSSD: Double?
    }

    /// The personal model: a baseline per pace that had enough history.
    public struct Model: Codable, Equatable, Sendable {
        public let paces: [PaceBaseline]
        /// Days that contributed at least one window.
        public let days: Int

        public func baseline(for pace: Pace) -> PaceBaseline? { paces.first { $0.pace == pace } }
        public var windowCount: Int { paces.reduce(0) { $0 + $1.windows } }
    }

    /// One scored minute: the smoothed NSS and what produced it.
    public struct Reading: Equatable, Sendable {
        public let ts: Int
        /// EMA-smoothed NSS, 0–100 — the number shown.
        public let nss: Double
        /// This window's unsmoothed value.
        public let raw: Double
        public let pace: Pace
        public let hr: Double
        /// My calm heart rate at this pace (the reference the score is measured from).
        public let hrCalm: Double
        public let zHR: Double
        public let zSI: Double?
        public let zRMSSD: Double?

        public init(ts: Int, nss: Double, raw: Double, pace: Pace, hr: Double, hrCalm: Double,
                    zHR: Double, zSI: Double?, zRMSSD: Double?) {
            self.ts = ts; self.nss = nss; self.raw = raw; self.pace = pace; self.hr = hr
            self.hrCalm = hrCalm; self.zHR = zHR; self.zSI = zSI; self.zRMSSD = zRMSSD
        }
    }

    /// A stretch of readings at or above a level (the "unusual for me" episodes).
    public struct Episode: Equatable, Sendable {
        public let startTs: Int
        public let endTs: Int
        public let peak: Reading

        public init(startTs: Int, endTs: Int, peak: Reading) {
            self.startTs = startTs; self.endTs = endTs; self.peak = peak
        }
    }

    // MARK: - Step 1: windows

    /// The window ending at `endTs`, from streams already SORTED by `ts` (the caller sorts once for a
    /// whole batch). Nil when the window holds too little heart rate to say anything.
    public static func window(endTs: Int, hr: [HRSample], rr: [RRInterval], steps: [StepSample],
                              activity: [WorkoutDetector.ActivityPoint]) -> Window? {
        let start = endTs - windowSeconds
        let hrSlice = slice(hr, from: start, to: endTs, ts: \.ts)
        guard hrSlice.count >= minWindowHRSamples else { return nil }
        let meanHR = Double(hrSlice.reduce(0) { $0 + $1.bpm }) / Double(hrSlice.count)
        let rawRR = slice(rr, from: start, to: endTs, ts: \.ts).map { Double($0.rrMs) }
        let rmssd = HRVAnalyzer.analyze(rawRR: rawRR).rmssd
        let si = StressIndex.components(rawRR: rawRR)?.si
        return Window(endTs: endTs,
                      pace: pace(steps: Array(slice(steps, from: start, to: endTs, ts: \.ts)),
                                 activity: Array(slice(activity, from: start, to: endTs, ts: \.ts))),
                      hr: meanHR,
                      lnSI: si.flatMap { $0 > 0 ? log($0) : nil },
                      lnRMSSD: rmssd.flatMap { $0 > 0 ? log($0) : nil })
    }

    /// Windows ending on every `stepSeconds` boundary in `(from, to]`, skipping the empty ones. Sorts the
    /// streams once.
    public static func windows(from: Int, to: Int, stepSeconds: Int,
                               hr: [HRSample], rr: [RRInterval], steps: [StepSample],
                               gravity: [GravitySample]) -> [Window] {
        guard stepSeconds > 0, to > from else { return [] }
        let hrS = hr.sorted { $0.ts < $1.ts }
        let rrS = rr.sorted { $0.ts < $1.ts }
        let stS = steps.sorted { $0.ts < $1.ts }
        let act = WorkoutDetector.activitySeries(gravity)   // sorts internally
        var out: [Window] = []
        var end = (from / stepSeconds + 1) * stepSeconds
        while end <= to {
            if let w = window(endTs: end, hr: hrS, rr: rrS, steps: stS, activity: act) { out.append(w) }
            end += stepSeconds
        }
        return out
    }

    /// The pace for one window's step samples and wrist-motion points.
    public static func pace(steps: [StepSample], activity: [WorkoutDetector.ActivityPoint]) -> Pace {
        let ticksPerMin = Double(StepsCounter.stepsInWindow(steps) ?? 0) / (Double(windowSeconds) / 60)
        if ticksPerMin >= runTicksPerMin { return .run }
        if ticksPerMin >= briskTicksPerMin { return .brisk }
        if ticksPerMin >= walkTicksPerMin { return .walk }
        if ticksPerMin >= lightTicksPerMin { return .light }
        if !activity.isEmpty {
            let moving = activity.filter { $0.intensity > WorkoutDetector.motionThreshold }.count
            if Double(moving) / Double(activity.count) >= motionActiveFraction { return .movingNoSteps }
        }
        return .still
    }

    // MARK: - Exercise (261025)

    /// Why a window is left unscored for exercise.
    public enum ExerciseMark: String, Codable, Sendable {
        /// Exercise-level HR, running pace, or inside a logged workout.
        case exercise
        /// Within `recoveryMinutes` after exercise.
        case recovery
    }

    /// The HR at `exerciseHRRFraction` of heart-rate reserve, or nil when the inputs make no reserve.
    public static func exerciseHR(restingHR: Double, maxHR: Double) -> Double? {
        guard restingHR > 0, maxHR > restingHR else { return nil }
        return restingHR + exerciseHRRFraction * (maxHR - restingHR)
    }

    /// The exercise and recovery windows among `windows`, keyed by `endTs`. A window is EXERCISE when its
    /// mean HR is at or above `exerciseHR`, its pace is running, or it overlaps a `workouts` span (unix
    /// seconds, start...end); it is RECOVERY when it starts within `recoveryMinutes` after the end of the
    /// latest exercise window or workout before it. Pass one day's windows (any order).
    public static func exerciseMarks(_ windows: [Window], exerciseHR: Double?,
                                     workouts: [ClosedRange<Int>]) -> [Int: ExerciseMark] {
        var marks: [Int: ExerciseMark] = [:]
        var lastEnd: Int?
        let tail = recoveryMinutes * 60
        for w in windows.sorted(by: { $0.endTs < $1.endTs }) {
            let start = w.endTs - windowSeconds
            let inWorkout = workouts.contains { $0.lowerBound < w.endTs && $0.upperBound > start }
            let byHeart = w.pace == .run || exerciseHR.map({ w.hr >= $0 }) == true
            if inWorkout || byHeart {
                marks[w.endTs] = .exercise
                // A workout's tail runs from its own end (below), not from a window overlapping it.
                if byHeart { lastEnd = max(lastEnd ?? w.endTs, w.endTs) }
                continue
            }
            // A workout that ended before this window counts as the end of exercise too.
            let workoutEnd = workouts.map(\.upperBound).filter { $0 <= w.endTs }.max()
            if let end = [lastEnd, workoutEnd].compactMap({ $0 }).max(), start < end + tail {
                marks[w.endTs] = .recovery
            }
        }
        return marks
    }

    /// `windows` without their exercise and recovery windows.
    public static func excludingExercise(_ windows: [Window], marks: [Int: ExerciseMark]) -> [Window] {
        marks.isEmpty ? windows : windows.filter { marks[$0.endTs] == nil }
    }

    // MARK: - The personal model

    /// Calm references and robust spreads per pace, from history windows.
    public static func buildModel(_ windows: [Window], days: Int) -> Model {
        var paces: [PaceBaseline] = []
        for pace in Pace.allCases where pace.isScored {
            let ws = windows.filter { $0.pace == pace }
            guard ws.count >= minWindowsPerPace else { continue }
            let hrs = ws.map(\.hr)
            let sis = ws.compactMap(\.lnSI)
            let rms = ws.compactMap(\.lnRMSSD)
            let siOK = sis.count >= minWindowsPerPace, rmOK = rms.count >= minWindowsPerPace
            paces.append(PaceBaseline(
                pace: pace, windows: ws.count,
                hr: percentile(hrs, calmPercentile) ?? median(hrs),
                sdHR: max(minSdHR, robustSD(hrs, around: median(hrs))),
                lnSI: siOK ? percentile(sis, calmPercentile) : nil,
                sdSI: siOK ? max(minSdLn, robustSD(sis, around: median(sis))) : nil,
                lnRMSSD: rmOK ? percentile(rms, 1 - calmPercentile) : nil,
                sdRMSSD: rmOK ? max(minSdLn, robustSD(rms, around: median(rms))) : nil))
        }
        return Model(paces: paces, days: days)
    }

    // MARK: - Steps 2 and 3: residuals and the score

    /// One window's unsmoothed NSS and its residual z's above calm, or nil when its pace is unscored or
    /// unmodelled.
    public static func score(_ w: Window, model: Model)
        -> (raw: Double, hrCalm: Double, zHR: Double, zSI: Double?, zRMSSD: Double?)? {
        guard w.pace.isScored, let b = model.baseline(for: w.pace) else { return nil }
        func clampZ(_ z: Double) -> Double { min(max(z, -zClamp), zClamp) }
        let zHR = clampZ((w.hr - b.hr) / b.sdHR)
        var zSI: Double?
        if let v = w.lnSI, let p = b.lnSI, let sd = b.sdSI { zSI = clampZ((v - p) / sd) }
        var zRMSSD: Double?
        if let v = w.lnRMSSD, let p = b.lnRMSSD, let sd = b.sdRMSSD { zRMSSD = clampZ((p - v) / sd) }
        var sum = weightHR * zHR
        var weight = weightHR
        if let z = zSI { sum += weightSI * z; weight += weightSI }
        if let z = zRMSSD { sum += weightRMSSD * z; weight += weightRMSSD }
        let raw = min(max(pointsPerSwing * (sum / weight), 0), 100)
        return (raw, b.hr, zHR, zSI, zRMSSD)
    }

    /// Smoothed readings over `windows` (oldest first; meant for 1-minute steps).
    public static func readings(_ windows: [Window], model: Model) -> [Reading] {
        var out: [Reading] = []
        var last: (ts: Int, value: Double)?
        for w in windows.sorted(by: { $0.endTs < $1.endTs }) {
            guard let s = score(w, model: model) else { continue }
            let value: Double
            if let l = last, w.endTs - l.ts <= emaResetGapSeconds {
                value = emaAlpha * s.raw + (1 - emaAlpha) * l.value
            } else {
                value = s.raw
            }
            last = (w.endTs, value)
            out.append(Reading(ts: w.endTs, nss: value, raw: s.raw, pace: w.pace, hr: w.hr,
                               hrCalm: s.hrCalm, zHR: s.zHR, zSI: s.zSI, zRMSSD: s.zRMSSD))
        }
        return out
    }

    /// The most recent stretch of readings at or above `threshold` lasting at least
    /// `unusualMinMinutes` (consecutive readings at most two minutes apart), or nil.
    public static func lastEpisode(_ readings: [Reading], threshold: Double) -> Episode? {
        var best: Episode?
        var runStart: Reading?
        var runPeak: Reading?
        var prev: Reading?
        func close() {
            if let s = runStart, let p = runPeak, let e = prev,
               e.ts - s.ts + 60 >= unusualMinMinutes * 60 {
                best = Episode(startTs: s.ts - 60, endTs: e.ts, peak: p)
            }
            runStart = nil; runPeak = nil
        }
        for r in readings {
            if r.nss >= threshold {
                if let p = prev, runStart != nil, r.ts - p.ts > 120 { close() }
                if runStart == nil { runStart = r }
                if runPeak == nil || r.nss > runPeak!.nss { runPeak = r }
            } else if runStart != nil {
                close()
            }
            prev = r
        }
        if runStart != nil { close() }
        return best
    }

    // MARK: - Helpers

    /// The elements of `sorted` with `from < ts <= to`, by binary search.
    static func slice<T>(_ sorted: [T], from: Int, to: Int, ts: (T) -> Int) -> ArraySlice<T> {
        func lowerBound(_ v: Int) -> Int {
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ts(sorted[mid]) <= v { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        return sorted[lowerBound(from)..<lowerBound(to)]
    }

    /// The `p` quantile (0…1) by linear interpolation between order statistics, or nil when empty.
    public static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        let s = xs.sorted()
        guard !s.isEmpty else { return nil }
        let pos = min(max(p, 0), 1) * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// 1.4826 × median absolute deviation around `center` — an SD that ignores a few wild windows.
    static func robustSD(_ xs: [Double], around center: Double) -> Double {
        1.4826 * median(xs.map { abs($0 - center) })
    }
}
