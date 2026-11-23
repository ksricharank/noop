import Foundation

/// 260922: the strap-log sink for SCREEN-side lines, so no view has to hold `@EnvironmentObject var live`.
///
/// Holding `LiveState` in a tab root subscribes its whole body to the 1 Hz heart-rate churn — the
/// regression SleepView's header warns about, and exactly what the 260921 `chargeShown` ledger did to
/// the liquid Today for one build ("the UI is very laggy now"). Set once by AppModel to
/// `LiveState.append(log:)`; same shape as `DisplayPerformanceMonitor.emit`. Nil = inert (tests, previews).
///
/// Two lines ride it: `screenLoad screen=… ms=… restored=…` (one per tab load — the tab-switch cost was
/// felt for a week and never measured) and the `chargeShown` display-branch transitions.
@MainActor
enum ScreenLedger {
    static var emit: ((String) -> Void)?

    static func log(_ line: String) { emit?(line) }

    /// `restored` = the screen restored a same-key cache instead of re-reading the store.
    static func recordLoad(screen: String, restored: Bool, since started: UInt64) {
        let ms = Int(Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)
        emit?("screenLoad screen=\(screen) ms=\(ms) restored=\(restored)")
    }
}
