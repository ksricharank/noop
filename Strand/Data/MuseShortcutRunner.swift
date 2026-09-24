import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Run an Apple Shortcut after each digest write (260924)
//
// The digest's reader is a Shortcut (it ships the file onward to Muse), so the integration can chain
// it: after every successful write, run a named Shortcut a configurable number of minutes later —
// 0 means immediately. The delay exists for iCloud Drive to upload the file first.
//
// The platform constraint, stated rather than papered over: iOS lets an app launch a Shortcut
// (`shortcuts://run-shortcut`) only while that app is FRONTMOST. A digest written by a background
// sync therefore cannot start the Shortcut at its due time. The contract here is the maintainer's
// requested fallback chain: run at the due time when the app is frontmost; otherwise the run stays
// PENDING and fires at the first possible instant — the next sync hook or the next app-open,
// whichever comes first. A pending run never expires and never stacks: one slot, overwritten by the
// next write, because running yesterday's ship-it twice helps nobody. macOS has no such constraint
// (`NSWorkspace` opens URLs from any state), so there the delay is always honoured.

@MainActor
enum MuseShortcutRunner {

    static let nameKey = "integration.shortcutName"
    static let delayKey = "integration.shortcutDelayMin"
    /// Epoch ms the pending run is due at; absent = nothing pending. Persisted so a run that could
    /// not fire (backgrounded, relaunch) survives to the next opportunity.
    static let dueAtKey = "integration.shortcutDueAtMs"
    static let delayRange = 0...60

    static var shortcutName: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }

    static var delayMinutes: Int {
        get { min(max(UserDefaults.standard.integer(forKey: delayKey), delayRange.lowerBound), delayRange.upperBound) }
        set { UserDefaults.standard.set(min(max(newValue, delayRange.lowerBound), delayRange.upperBound), forKey: delayKey) }
    }

    static var isEnabled: Bool { !shortcutName.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The Shortcuts run URL for `name`, or nil for a blank name. Pure — unit-tested (the name is
    /// user-typed and must survive spaces and punctuation).
    nonisolated static func runURL(name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
                  .replacingOccurrences(of: "&", with: "%26") else { return nil }
        return URL(string: "shortcuts://run-shortcut?name=\(encoded)")
    }

    /// Whether a pending run is due. Pure. A due time in the future is not due; an absent one never is.
    nonisolated static func isDue(nowMs: Int, dueAtMs: Int?) -> Bool {
        guard let dueAtMs else { return false }
        return nowMs >= dueAtMs
    }

    /// Called after every successful digest write. Arms the pending slot at write + delay and, when
    /// the delay can elapse inside this process, schedules the attempt; the persisted slot is the
    /// fallback for every case where it cannot.
    static func scheduleAfterWrite(now: Date = Date(), log: ((String) -> Void)? = nil) {
        guard isEnabled else { return }
        let dueAt = Int(now.timeIntervalSince1970 * 1000) + delayMinutes * 60_000
        UserDefaults.standard.set(dueAt, forKey: dueAtKey)
        log?("integration: shortcut \"\(shortcutName)\" armed (+\(delayMinutes) min)")
        Task { @MainActor in
            if delayMinutes > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delayMinutes) * 60_000_000_000)
            }
            runIfDue(log: log)
        }
    }

    /// Fire the pending run if one is due AND the platform allows it right now. Safe to call often —
    /// it is hooked wherever the digest hooks are (post-sync, app active), which is exactly the
    /// "next possible instance" the fallback promises. Clears the slot only on an actual launch.
    static func runIfDue(now: Date = Date(), log: ((String) -> Void)? = nil) {
        let dueAt = UserDefaults.standard.object(forKey: dueAtKey) as? Int
        guard isDue(nowMs: Int(now.timeIntervalSince1970 * 1000), dueAtMs: dueAt) else { return }
        guard let url = runURL(name: shortcutName) else {
            UserDefaults.standard.removeObject(forKey: dueAtKey)   // name cleared since arming
            return
        }
        #if canImport(UIKit)
        // iOS: only a frontmost app may launch a Shortcut. Not frontmost = leave the slot pending;
        // the next hook (sync, app open) retries. Opening from the background silently fails, which
        // would consume the run without running anything.
        guard UIApplication.shared.applicationState == .active else {
            log?("integration: shortcut due, app not frontmost — will run at the next opportunity")
            return
        }
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
        UserDefaults.standard.removeObject(forKey: dueAtKey)
        log?("integration: shortcut \"\(shortcutName)\" launched")
    }

    /// The Test-run path for the settings screen: launch the named Shortcut right now, no arming.
    static func runNow() {
        guard let url = runURL(name: shortcutName) else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}
