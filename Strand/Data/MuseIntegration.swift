import Foundation
import WhoopStore
import StrandAnalytics
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Integration digest (260920)
//
// A once-a-day, fixed-name text file written to a folder the wearer chooses, holding the last 24
// hours in a form another tool can read. The maintainer's ask: "not a backup but rather a much
// smaller file that captures all the key elements from the last 24 hours ... it should have all the
// key information from each of the today, recap and sleep tabs."
//
// WHY THIS IS NOT BACKUP & SYNC, though it sits beside it in the same screen:
//
//   Backup & Sync writes the WHOLE database as a timestamped `.noopbak` so a future NOOP can restore
//   it. It accumulates files and prunes them by count. This writes ONE small Markdown digest under a
//   STABLE name, overwritten in place, for something that is not NOOP to read. Different payload,
//   different lifecycle, different reader — sharing the screen is right, sharing the code would mean
//   one mechanism serving two contracts.
//
// SCOPE (docs/SCOPE.md): this is local export to user-owned storage — the wearer picks the folder
// through the system picker, and NOOP writes a file into it. No server, no account, no network, no
// third-party destination, and nothing is ever read back. It is strictly narrower than the #1314
// self-hosted push the scope already permits, which is a NETWORK export; this never leaves the
// device except by whatever the wearer's own folder is synced with (iCloud Drive, in practice).
enum MuseIntegration {

    // MARK: Preferences

    static let bookmarkKey = "integration.folderBookmark"
    static let enabledKey = "integration.enabled"
    static let filenameKey = "integration.filename"
    static let lastWrittenKey = "integration.lastWrittenMs"
    static let lastErrorKey = "integration.lastError"
    static let hourKey = "integration.hourOfDay"
    static let useInternalKey = "integration.useInternalFolder"
    static let includeCoachKey = "integration.includeCoach"

    /// The default basename. Extension is appended by `resolvedFilename` so a wearer who types
    /// "noop_to_muse.txt" does not end up with "noop_to_muse.txt.txt".
    static let defaultFilename = "noop_to_muse"

    /// A plain `.txt`, not `.md`: the destination is another LLM app, and the maintainer asked for
    /// "simply a text file". The CONTENT is still Markdown-shaped — headings and bullets survive a
    /// paste into any chat box and cost nothing to a reader that ignores them.
    static let fileExtension = "txt"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Hour of the local day the digest is generated, 0–23. Defaults to 7am — the maintainer
    /// generates this "when I wake up".
    static var hourOfDay: Int {
        get {
            guard UserDefaults.standard.object(forKey: hourKey) != nil else { return 7 }
            return min(max(UserDefaults.standard.integer(forKey: hourKey), 0), 23)
        }
        set { UserDefaults.standard.set(min(max(newValue, 0), 23), forKey: hourKey) }
    }

    /// Whether to include the coach's own narrative text in the digest. Off by default: it costs a
    /// provider call per write, and the numbers are the part another tool cannot recompute.
    static var includesCoachNarratives: Bool {
        get { UserDefaults.standard.bool(forKey: includeCoachKey) }
        set { UserDefaults.standard.set(newValue, forKey: includeCoachKey) }
    }

    static var lastWrittenMs: Int { UserDefaults.standard.integer(forKey: lastWrittenKey) }
    static var lastError: String? { UserDefaults.standard.string(forKey: lastErrorKey) }

    /// The wearer's chosen basename, sanitised. Empty or all-separator input falls back to the
    /// default rather than writing a dotfile or escaping the folder.
    static var filename: String {
        get {
            let raw = UserDefaults.standard.string(forKey: filenameKey) ?? defaultFilename
            return sanitizeBasename(raw)
        }
        set { UserDefaults.standard.set(sanitizeBasename(newValue), forKey: filenameKey) }
    }

    /// Strip anything that could redirect the write out of the chosen folder or produce a hidden
    /// file: path separators, `..`, leading dots, and a trailing copy of our own extension.
    ///
    /// Pure and total — every input yields a usable basename — so the picker cannot be talked into
    /// writing somewhere the wearer did not choose.
    static func sanitizeBasename(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasSuffix("." + fileExtension) {
            s = String(s.dropLast(fileExtension.count + 1))
        }
        // Separators are DROPPED, not substituted. Replacing them with "-" left the traversal
        // fragments visibly intact ("../../etc/passwd" became "-..-etc-passwd"): harmless, since
        // the result is still one path component, but a filename that looks like an attempted
        // escape is one a reader has to stop and reason about.
        for sep in ["/", "\\", ":"] { s = s.replacingOccurrences(of: sep, with: "") }
        // Then any run of dots, which is what carries the traversal meaning. A single dot inside a
        // name is fine and survives — only runs go.
        while s.contains("..") { s = s.replacingOccurrences(of: "..", with: "") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ."))
        s = String(s.unicodeScalars.filter { allowed.contains($0) })
        return s.isEmpty ? defaultFilename : s
    }

    /// The full filename written to disk. STABLE by design — the maintainer asked for a name that
    /// does not change and a file that is overwritten, so whatever reads it can point at one path
    /// forever instead of globbing for the newest.
    static var resolvedFilename: String { "\(filename).\(fileExtension)" }

    // MARK: Cadence

    /// Whether a digest is due, given the last write and the configured hour.
    ///
    /// Pure so the rule is testable without a clock or a folder. "Due" means: enabled, and the
    /// scheduled hour has passed today, and we have not already written since that hour — which
    /// makes a missed day (phone off, app not launched) catch up on the next launch rather than
    /// being silently skipped, while a second launch the same afternoon does not rewrite.
    static func isDue(now: Date,
                      lastWrittenMs: Int,
                      hourOfDay: Int,
                      calendar: Calendar = .current) -> Bool {
        guard let todaysTrigger = calendar.date(bySettingHour: min(max(hourOfDay, 0), 23),
                                                minute: 0, second: 0, of: now) else { return false }
        guard now >= todaysTrigger else { return false }
        guard lastWrittenMs > 0 else { return true }
        let last = Date(timeIntervalSince1970: TimeInterval(lastWrittenMs) / 1000)
        return last < todaysTrigger
    }
}

// MARK: - The digest

extension MuseIntegration {

    /// Everything the digest needs, gathered by the caller so this stays pure and testable.
    struct Input {
        /// The finished day being recapped (usually yesterday, since the digest runs at wake).
        var recapDay: String
        var recapScore: DayQualityScore?
        /// The row for `recapDay` — that day's own waking measurements.
        var recapMetric: DailyMetric?
        /// The row for the night that CONCLUDED `recapDay`, i.e. the one keyed by the next day.
        /// Held separately because the two are different rows and conflating them is exactly the
        /// 1.9h-vs-7.9h fault the coach prompts hit on 260920.
        var nightMetric: DailyMetric?
        /// Today's row so far: partial by nature, and labelled as such.
        var todayMetric: DailyMetric?
        var todayDay: String
        /// Today's live targets — the four pairs the Today strip and the widgets show.
        var todayTargets: LiveTargets?
        /// Water for the recap day, which `LiveTargets` only carries for today.
        var recapWaterCups: Int?
        var recapWaterTargetCups: Int?
        /// Recent history for context another tool cannot recompute from one row: the 7-day and
        /// 30-day means of the signals that have baselines.
        var recentDays: [DailyMetric] = []
        /// The stored day-quality series, so the digest can state yesterday's grade against the
        /// run it sits in rather than in isolation.
        var recentQualityScores: [String: Double] = [:]
        /// The deterministic derived-trends block (`AICoach.derivedTrendsBlock`): training load,
        /// the sleep-debt ledger, per-signal z-scores against this wearer's own baselines, and a
        /// data-density hedge.
        ///
        /// From the Trends tab, but every line of it is DAILY actionable — "acute load is running
        /// above chronic", "2.3h short over the last 7 nights", "HRV z -1.4" all change what today
        /// should look like. The long-horizon direction the Trends charts show is deliberately NOT
        /// here: a 90-day slope is not something a wearer acts on at breakfast.
        var derivedTrends: String?
        /// Optional coach text, only when the wearer opted in.
        var coachToday: String?
        var coachRecap: String?
        var coachSleep: String?
    }

    /// Build the digest.
    ///
    /// Markdown-shaped plain text: headings and bullets a person can read and a model can parse,
    /// with no table syntax — tables survive a paste badly and carry no information here that a
    /// bullet does not.
    ///
    /// Every absent value is stated as "not recorded" rather than omitted. A reader diffing two
    /// days needs to tell "zero" from "we never measured it", and a silently missing line reads as
    /// the former.
    static func digest(_ i: Input, generatedAt: Date = Date()) -> String {
        var out: [String] = []

        out.append("# NOOP daily digest")
        out.append("")
        out.append("Generated \(stamp(generatedAt)). Covers the last 24 hours.")
        out.append("This file is overwritten once a day; it is a snapshot, not a log.")
        out.append("")

        // --- TODAY -----------------------------------------------------------------------
        out.append("## Today so far — \(i.todayDay)")
        out.append("")
        out.append("These figures are PARTIAL: the day is still running.")
        out.append("")
        if let m = i.todayMetric {
            out.append(contentsOf: measurementBullets(m))
        } else {
            out.append("- No data recorded for today yet.")
        }
        if let t = i.todayTargets {
            out.append("")
            out.append("Today's targets (what NOOP is asking of me today):")
            if let a = t.stepsToday, let g = t.stepsTarget {
                out.append("- Steps: \(a) of \(g)")
            }
            if let a = t.kcalToday, let g = t.kcalTargetKcal {
                out.append("- Total calories: \(a) of \(g) kcal")
            }
            if let a = t.effortTodayStored, let g = t.effortTarget {
                out.append("- Effort: \(a) of \(g) (0-100 scale)")
            }
            if let ml = t.waterTodayML, let g = t.waterTargetCups {
                out.append("- Water: " + String(format: "%.1f", ml / 240.0) + " of \(g) cups")
            }
            if let need = t.sleepNeedTonightMin {
                out.append("- Sleep needed tonight: " + hoursOrNot(Double(need)))
            }
            if t.restDay {
                out.append("- NOOP is prescribing a REST day: the effort target holds at today's "
                           + "current effort rather than asking for more.")
            } else if let mins = t.sessionMinutes, let bpm = t.sessionHrBpm {
                out.append("- Prescribed session: \(mins) min at about \(bpm) bpm")
            }
            if !t.explainLines.isEmpty {
                out.append("")
                out.append("How those targets were set:")
                for line in t.explainLines { out.append("- \(line)") }
            }
        }
        if let c = i.coachToday, !c.isEmpty {
            out.append("")
            out.append("NOOP's read on right now:")
            out.append("")
            out.append(c)
        }
        out.append("")

        // --- LAST NIGHT ------------------------------------------------------------------
        // Placed before the recap because at wake it is the freshest thing and the most likely
        // reason the wearer is reading this at all.
        out.append("## Last night")
        out.append("")
        if let n = i.nightMetric {
            out.append("The night that ended on the morning of \(n.day).")
            out.append("")
            out.append(contentsOf: sleepBullets(n))
        } else {
            out.append("- No sleep recorded for last night.")
        }
        if let c = i.coachSleep, !c.isEmpty {
            out.append("")
            out.append("NOOP's read on the night:")
            out.append("")
            out.append(c)
        }
        out.append("")

        // --- RECAP -----------------------------------------------------------------------
        out.append("## Yesterday's grade — \(i.recapDay)")
        out.append("")
        if let s = i.recapScore {
            out.append("Day quality: \(s.total) of 100 (\(DayQualityScore.band(s.total))).")
            out.append("Execution \(Int(s.executionPoints.rounded())) points, "
                       + "recovery \(Int(s.recoveryPoints.rounded())) points.")
            out.append("")
            if !s.components.isEmpty {
                out.append("What drove it:")
                for c in s.components {
                    out.append("- \(c.label): \(c.detail) — \(Int(c.points.rounded())) "
                               + "of \(Int(c.weight.rounded())) points")
                }
            }
            if s.loadFactor != 1.0 {
                let pct = Int(((s.loadFactor - 1) * 100).rounded())
                out.append("- Targets were \(pct > 0 ? "harder" : "easier") than recent average; "
                           + "execution scaled by \(pct)%.")
            }
            if !s.missing.isEmpty {
                out.append("- Not recorded (no data, NOT a zero): \(s.missing.joined(separator: ", "))")
            }
        } else {
            out.append("Day quality: not scored — too little data for this day.")
        }
        if let m = i.recapMetric {
            out.append("")
            out.append("Yesterday's measurements:")
            out.append(contentsOf: measurementBullets(m))
            if let cups = i.recapWaterCups {
                out.append("- Water: \(cups)"
                           + (i.recapWaterTargetCups.map { " of \($0) cups" } ?? " cups"))
            }
        }
        if let c = i.coachRecap, !c.isEmpty {
            out.append("")
            out.append("NOOP's read on the day:")
            out.append("")
            out.append(c)
        }
        out.append("")

        // --- CONTEXT ---------------------------------------------------------------------
        let baselines = baselineBullets(i.recentDays)
        if !baselines.isEmpty {
            out.append("## My normal range")
            out.append("")
            out.append(contentsOf: baselines)
            out.append("")
        }

        // Training load, the sleep-debt ledger and per-signal z-scores. Emitted VERBATIM from the
        // same builder the coach context uses, so the digest and anything the coach says are
        // reading one set of numbers rather than two that can drift.
        if let derived = i.derivedTrends, !derived.isEmpty {
            out.append("## Where this is heading")
            out.append("")
            out.append(derived)
            out.append("")
        }

        if !i.recentQualityScores.isEmpty {
            let recent = i.recentQualityScores.keys.sorted().suffix(14)
            out.append("## Recent day-quality grades")
            out.append("")
            out.append("Scored -100 to +100; 0 is an ordinary day.")
            out.append("")
            for day in recent {
                if let v = i.recentQualityScores[day] {
                    out.append("- \(day): \(Int(v.rounded()))")
                }
            }
            out.append("")
        }

        out.append("---")
        out.append("")
        out.append("Written by NOOP on-device. Nothing here was sent anywhere to produce it.")

        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Field formatting
    //
    // These mirror the app's own display rules rather than inventing new ones: a digest that
    // rounded differently from the screen would make the wearer doubt one of them.

    private static func measurementBullets(_ m: DailyMetric) -> [String] {
        var out: [String] = []
        out.append("- Charge (recovery): " + (m.recovery.map { "\(Int($0.rounded()))%" } ?? "not recorded"))
        out.append("- Effort (strain): " + (m.strain.map { String(format: "%.1f", $0) } ?? "not recorded"))
        out.append("- Resting heart rate: " + (m.restingHr.map { "\($0) bpm" } ?? "not recorded"))
        out.append("- HRV: " + (m.avgHrv.map { "\(Int($0.rounded())) ms" } ?? "not recorded"))
        out.append("- Steps: " + (m.steps.map { "\($0)" } ?? "not recorded"))
        out.append("- Calories (whole-day estimate): "
                   + (m.activeKcalEst.map { "\(Int($0.rounded())) kcal" } ?? "not recorded"))
        if let n = m.exerciseCount, n > 0 { out.append("- Workouts: \(n)") }
        if let sdnn = m.avgSdnn {
            out.append("- SDNN: \(Int(sdnn.rounded())) ms")
        }
        return out
    }

    /// Where a signal sits against its own recent history. This is the part another tool genuinely
    /// cannot recompute from a single day's file, so it earns its space: "36 ms" means nothing
    /// without knowing the wearer usually runs 33.
    private static func baselineBullets(_ recent: [DailyMetric]) -> [String] {
        guard recent.count >= 3 else { return [] }
        func mean(_ pick: (DailyMetric) -> Double?) -> Double? {
            let vs = recent.compactMap(pick)
            guard !vs.isEmpty else { return nil }
            return vs.reduce(0, +) / Double(vs.count)
        }
        var out: [String] = []
        let n = recent.count
        out.append("Averages over the last \(n) days, for comparison:")
        if let v = mean({ $0.recovery }) { out.append("- Charge: \(Int(v.rounded()))%") }
        if let v = mean({ $0.strain }) { out.append("- Effort: " + String(format: "%.1f", v)) }
        if let v = mean({ $0.restingHr.map(Double.init) }) { out.append("- Resting heart rate: \(Int(v.rounded())) bpm") }
        if let v = mean({ $0.avgHrv }) { out.append("- HRV: \(Int(v.rounded())) ms") }
        if let v = mean({ $0.totalSleepMin }) { out.append("- Time asleep: " + hoursOrNot(v)) }
        if let v = mean({ $0.steps.map(Double.init) }) { out.append("- Steps: \(Int(v.rounded()))") }
        if let v = mean({ $0.respRateBpm }) { out.append("- Respiratory rate: " + String(format: "%.1f rpm", v)) }
        return out
    }

    private static func sleepBullets(_ m: DailyMetric) -> [String] {
        var out: [String] = []
        out.append("- Time asleep: " + hoursOrNot(m.totalSleepMin))
        out.append("- Deep: " + hoursOrNot(m.deepMin))
        out.append("- REM: " + hoursOrNot(m.remMin))
        out.append("- Light: " + hoursOrNot(m.lightMin))
        out.append("- Efficiency: " + efficiencyOrNot(m.efficiency))
        if let d = m.disturbances { out.append("- Disturbances: \(d)") }
        out.append("- HRV overnight: " + (m.avgHrv.map { "\(Int($0.rounded())) ms" } ?? "not recorded"))
        out.append("- Resting heart rate: " + (m.restingHr.map { "\($0) bpm" } ?? "not recorded"))
        if let r = m.respRateBpm { out.append("- Respiratory rate: " + String(format: "%.1f rpm", r)) }
        if let s = m.spo2Pct { out.append("- SpO2: " + String(format: "%.0f%%", s)) }
        if let sdnn = m.avgSdnn { out.append("- SDNN: \(Int(sdnn.rounded())) ms") }
        if let skin = m.skinTempDevC {
            // Bimodal column: strap nights store a deviation, CSV/Apple imports an absolute wrist
            // temperature. Labelled by magnitude exactly as `AICoach.dayLine` does, so a reader is
            // never handed a "+31.2" it reads as a deviation.
            out.append(VitalBands.isAbsoluteSkinTemp(skin)
                       ? String(format: "- Skin temperature: %.1f C", skin)
                       : String(format: "- Skin temperature: %+.1f C vs baseline", skin))
        }
        return out
    }

    private static func hoursOrNot(_ minutes: Double?) -> String {
        guard let minutes else { return "not recorded" }
        let h = Int(minutes) / 60, mm = Int(minutes) % 60
        return "\(h)h \(mm)m"
    }

    /// Efficiency is stored either as a fraction or a percentage depending on the import path;
    /// normalised the same way `AICoach.dayLine` does so the two never disagree.
    private static func efficiencyOrNot(_ raw: Double?) -> String {
        guard var e = raw, e > 0 else { return "not recorded" }
        if e > 1.5 { e /= 100 }
        guard e > 0, e <= 1 else { return "not recorded" }
        return "\(Int((e * 100).rounded()))%"
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}

// MARK: - The folder and the write

extension MuseIntegration {

    /// Whether a destination has been chosen at all.
    static var hasFolder: Bool {
        useInternalFolder || UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    /// The #52 picker-free fallback, mirrored from `FolderBackup`: NOOP's own Files-visible folder,
    /// for a wearer whose picker cannot reach where they want (or who just wants it to work).
    static var useInternalFolder: Bool {
        get { UserDefaults.standard.bool(forKey: useInternalKey) }
        set { UserDefaults.standard.set(newValue, forKey: useInternalKey) }
    }

    @discardableResult
    static func useNoopFolder() -> URL? {
        useInternalFolder = true
        return internalFolderURL()
    }

    /// `<sandbox>/Documents/Integration`, created on first use. A DIFFERENT folder from Backup &
    /// Sync's `Documents/Backups` on purpose: a digest sitting among `.noopbak` snapshots invites
    /// someone to hand the wrong file to the wrong reader.
    private static func internalFolderURL() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("Integration", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func bookmarkCreationOptions() -> URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    static func resolveFolder() -> URL? {
        if useInternalFolder { return internalFolderURL() }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        #if os(macOS)
        let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let opts: URL.BookmarkResolutionOptions = []
        #endif
        let url = try? URL(resolvingBookmarkData: data, options: opts,
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale, let url { saveFolder(url) }
        return url
    }

    /// Persist a security-scoped bookmark. Same bracketing as `FolderBackup.saveFolder` — on macOS
    /// a `.withSecurityScope` bookmark can only be minted inside a scoped-access pair.
    static func saveFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try? url.bookmarkData(options: bookmarkCreationOptions(),
                                         includingResourceValuesForKeys: nil, relativeTo: nil)
        if let data {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            useInternalFolder = false
        }
    }

    /// A short human label for the destination, reusing `FolderBackup`'s path rules so the two
    /// screens describe the same folder the same way.
    static func folderLabel() -> String? {
        if useInternalFolder { return String(localized: "NOOP (in Files)") }
        guard let path = resolveFolder()?.path else { return nil }
        let trail = FolderBackup.folderTrail(path: path)
        if FolderBackup.isICloudPath(path) {
            return trail.isEmpty ? String(localized: "iCloud Drive")
                                 : String(localized: "iCloud Drive › \(trail)")
        }
        return trail.isEmpty ? (path.split(separator: "/").last.map(String.init) ?? path) : trail
    }

    /// The path the digest is written to, for display.
    static func destinationDescription() -> String? {
        guard let label = folderLabel() else { return nil }
        return "\(label) › \(resolvedFilename)"
    }

    // MARK: Write

    enum WriteError: LocalizedError {
        case noFolder
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noFolder:
                return String(localized: "No folder chosen for the integration file.")
            case .writeFailed(let why):
                return String(localized: "Could not write the integration file: \(why)")
            }
        }
    }

    /// Write `contents` to the chosen folder under the stable filename, replacing what is there.
    ///
    /// OVERWRITE, never append and never version: the maintainer asked for one file at one path
    /// that a reader can point at forever. `.atomic` so a reader that happens to open the file
    /// mid-write sees the old digest rather than half of the new one.
    @discardableResult
    static func write(_ contents: String, now: Date = Date()) throws -> URL {
        guard let folder = resolveFolder() else {
            UserDefaults.standard.set(WriteError.noFolder.localizedDescription, forKey: lastErrorKey)
            throw WriteError.noFolder
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let url = folder.appendingPathComponent(resolvedFilename)
        do {
            try contents.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: lastErrorKey)
            throw WriteError.writeFailed(error.localizedDescription)
        }
        UserDefaults.standard.set(Int(now.timeIntervalSince1970 * 1000), forKey: lastWrittenKey)
        UserDefaults.standard.removeObject(forKey: lastErrorKey)
        return url
    }
}

// MARK: - Choosing the folder
//
// Mirrors `FolderBackup.pickFolder` and shares `DocumentPicker` on iOS, so the two destinations
// behave identically at the picker — including the #1000a "Select never enables" mitigation of
// starting in the previously-chosen folder.
extension MuseIntegration {
    #if os(macOS)
    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a folder for the NOOP digest file (for example an iCloud Drive folder).")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        saveFolder(url)
        return url
    }
    #else
    @MainActor
    static func pickFolder() async -> URL? {
        let url = await DocumentPicker.pickFolder(startingAt: resolveFolder())
        if let url { saveFolder(url) }
        return url
    }
    #endif
}
