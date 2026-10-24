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
/// THE METHOD, in three steps (the maintainer's spec, kept as written where it was concrete):
/// 1. PERSONAL MODEL PER PACE. From the last `modelDays` days of waking-hour data, every 5-minute window
///    gets a `Pace` (from strap locomotion ticks per minute, and wrist motion for movement without steps)
///    and three observations: mean HR, ln Baevsky SI, ln RMSSD. Per pace, the MEDIAN of each is the
///    prediction, so a few stressed days cannot poison the baseline, and the residual spread is a
///    robust SD (1.4826 × MAD around that median).
/// 2. RESIDUALS over a rolling 5-minute window, each as a z against that spread:
///    zHR = (HR − HR_pred) / sd, zSI = (ln SI − ln SI_pred) / sd, zRMSSD = (ln RMSSD_pred − ln RMSSD) / sd.
///    Positive on all three = heart working harder and variability lower than this pace warrants.
/// 3. COMBINE: raw = 50 + 15 × (0.40·zHR + 0.35·zSI + 0.25·zRMSSD), clamped to 0–100, then smoothed by
///    an exponential moving average (α = 0.2 per 1-minute step, reset after a 10-minute gap). A missing
///    HRV term (too few clean beats, common on a moving wrist) is dropped and the remaining weights are
///    renormalised, so heart rate alone still gives a number. Each z is clamped to ±4 so one artifact
///    window cannot swing the score across the whole scale.
///
/// SCALE. 50 = my usual for the pace I am at. Each 15 points is one robust SD of combined excess. The
/// Stress screen's band colours apply at NSS × 3/100 (so ≥ 67 is HIGH), and a "high episode" is NSS
/// ≥ `highThreshold` held for at least `highMinMinutes`.
///
/// HONEST LIMITS (also stated wherever the number is shown):
/// - It measures EXCESS SYMPATHETIC DRIVE, not mental stress as such. Heat, caffeine, digestion, sleep
///   debt, illness and talking all show up as residual too; mental load is the biggest remaining
///   explanation once activity is accounted for, but the formula cannot prove the cause.
/// - It saturates at high intensity: near max HR, HRV is already floored and residuals compress. RUNNING
///   pace is not scored at all. Best from rest through moderate activity — desk, walking, chores.
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
    /// History the personal model is learned from.
    public static let modelDays = 14
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
    /// Each z is clamped to ±this before combining.
    public static let zClamp = 4.0
    /// Robust-SD floors, so a very consistent pace cannot turn a tiny wobble into a big z.
    public static let minSdHR = 2.0
    public static let minSdLn = 0.05
    /// A "high" reading, and how long it must hold to count as an episode. 200/3 is the Stress screen's
    /// HIGH band (≥ 2.0 of 3) on this scale.
    public static let highThreshold = 200.0 / 3.0
    public static let highMinMinutes = 10
    /// Pace thresholds in raw strap locomotion ticks per minute (`StepsCounter`, before the per-user
    /// ticks-per-step calibration). The bins only group like with like: each bin's prediction is MY OWN
    /// median, so the exact cut points matter far less than they would against population norms.
    public static let lightTicksPerMin = 5.0
    public static let walkTicksPerMin = 40.0
    public static let briskTicksPerMin = 95.0
    public static let runTicksPerMin = 140.0
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

    /// One pace's prediction (medians) and residual spreads (robust SDs). The HRV terms are nil when the
    /// pace had too few windows with clean beats.
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
        public let hrPred: Double
        public let zHR: Double
        public let zSI: Double?
        public let zRMSSD: Double?

        public init(ts: Int, nss: Double, raw: Double, pace: Pace, hr: Double, hrPred: Double,
                    zHR: Double, zSI: Double?, zRMSSD: Double?) {
            self.ts = ts; self.nss = nss; self.raw = raw; self.pace = pace; self.hr = hr
            self.hrPred = hrPred; self.zHR = zHR; self.zSI = zSI; self.zRMSSD = zRMSSD
        }
    }

    /// A stretch of high readings.
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

    // MARK: - The personal model

    /// Medians and robust spreads per pace, from history windows.
    public static func buildModel(_ windows: [Window], days: Int) -> Model {
        var paces: [PaceBaseline] = []
        for pace in Pace.allCases where pace.isScored {
            let ws = windows.filter { $0.pace == pace }
            guard ws.count >= minWindowsPerPace else { continue }
            let hrs = ws.map(\.hr)
            let hrMed = median(hrs)
            let sis = ws.compactMap(\.lnSI)
            let rms = ws.compactMap(\.lnRMSSD)
            let siMed = sis.count >= minWindowsPerPace ? median(sis) : nil
            let rmMed = rms.count >= minWindowsPerPace ? median(rms) : nil
            paces.append(PaceBaseline(
                pace: pace, windows: ws.count,
                hr: hrMed, sdHR: max(minSdHR, robustSD(hrs, around: hrMed)),
                lnSI: siMed, sdSI: siMed.map { max(minSdLn, robustSD(sis, around: $0)) },
                lnRMSSD: rmMed, sdRMSSD: rmMed.map { max(minSdLn, robustSD(rms, around: $0)) }))
        }
        return Model(paces: paces, days: days)
    }

    // MARK: - Steps 2 and 3: residuals and the score

    /// One window's unsmoothed NSS and its residual z's, or nil when its pace is unscored or unmodelled.
    public static func score(_ w: Window, model: Model)
        -> (raw: Double, hrPred: Double, zHR: Double, zSI: Double?, zRMSSD: Double?)? {
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
        let raw = min(max(50 + 15 * (sum / weight), 0), 100)
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
                               hrPred: s.hrPred, zHR: s.zHR, zSI: s.zSI, zRMSSD: s.zRMSSD))
        }
        return out
    }

    /// The most recent stretch of readings at or above `highThreshold` lasting at least
    /// `highMinMinutes` (consecutive readings at most two minutes apart), or nil.
    public static func lastHighEpisode(_ readings: [Reading]) -> Episode? {
        var best: Episode?
        var runStart: Reading?
        var runPeak: Reading?
        var prev: Reading?
        func close() {
            if let s = runStart, let p = runPeak, let e = prev,
               e.ts - s.ts + 60 >= highMinMinutes * 60 {
                best = Episode(startTs: s.ts - 60, endTs: e.ts, peak: p)
            }
            runStart = nil; runPeak = nil
        }
        for r in readings {
            if r.nss >= highThreshold {
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
