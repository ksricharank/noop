import Foundation

/// Pure cadence + smoothing policy for the live-HR Live Activity.
///
/// While the phone is unlocked the activity refreshes at the live ~2 s cadence, so the Dynamic
/// Island reads as live. While the phone is locked nobody can watch beat-level movement — but every
/// update still wakes the widget-extension process and, on an Always-On display, repaints the Lock
/// Screen, which is a sustained battery cost (~1,800 wakes/hour at the live cadence). So locked
/// pushes slow to one per minute and carry a one-minute average instead of the instantaneous
/// reading: the Lock Screen still shows a current heart rate, at 1/30th the update volume.
///
/// Platform-free and stateless so StrandTests can pin the cadence boundaries and the averaging
/// without ActivityKit or a device. The Live Activity itself is iOS-only; the macOS target compiles
/// this but never calls it.
enum LiveActivityHrPolicy {
    /// Minimum spacing between pushes while the phone is unlocked — the pre-existing live cadence
    /// (`LiveActivityController` throttled to "once every 2 s" before lock-awareness existed).
    static let unlockedMinSpacing: TimeInterval = 2
    /// Spacing between pushes while the phone is locked.
    static let lockedSpacing: TimeInterval = 60
    /// How far back the locked-mode average looks.
    static let averagingWindow: TimeInterval = 60

    /// One display-HR tick as received from the live stream (the app's stabilised display value,
    /// not the raw 0x2A37 sample — the average smooths what the user would otherwise have seen).
    struct Sample: Equatable {
        let at: Date
        let bpm: Int
    }

    /// Append a tick, dropping everything that has aged out of the averaging window. The stream
    /// ticks at ~1 Hz, so the buffer stays around `averagingWindow` entries.
    static func appending(_ samples: [Sample], bpm: Int, at now: Date) -> [Sample] {
        var kept = samples.filter { now.timeIntervalSince($0.at) <= averagingWindow }
        kept.append(Sample(at: now, bpm: bpm))
        return kept
    }

    /// Whether enough time has passed since the last push for the current lock state. Strict
    /// `>` on both branches, matching the original 2 s throttle's comparison exactly.
    static func shouldPush(locked: Bool, now: Date, lastPush: Date) -> Bool {
        now.timeIntervalSince(lastPush) > (locked ? lockedSpacing : unlockedMinSpacing)
    }

    /// Mean of the samples inside the averaging window, rounded to a whole bpm. Nil when nothing
    /// is in the window (the caller falls back to the instantaneous reading rather than pushing
    /// an empty state).
    static func windowAverage(_ samples: [Sample], now: Date) -> Int? {
        let inWindow = samples.filter { now.timeIntervalSince($0.at) <= averagingWindow }
        guard !inWindow.isEmpty else { return nil }
        let mean = Double(inWindow.reduce(0) { $0 + $1.bpm }) / Double(inWindow.count)
        return Int(mean.rounded())
    }
}
