import SwiftUI
import StrandDesign

// MARK: - Integration (260920)
//
// A once-a-day digest of the last 24 hours, written as one small text file under a stable name to a
// folder the wearer chooses. Sits beside Backup & Sync because both write files to a chosen folder,
// but it is a DIFFERENT contract: Backup & Sync writes the whole database as dated `.noopbak`
// snapshots for a future NOOP to restore; this writes a short human/model-readable digest at one
// fixed path, overwritten each day, for something that is not NOOP to read.
struct IntegrationView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coach: AICoachEngine

    @State private var enabled = MuseIntegration.isEnabled
    @State private var basename = MuseIntegration.filename
    @State private var slots = MuseIntegration.slotMinutesRaw
    @State private var shortcutName = MuseShortcutRunner.shortcutName
    @State private var shortcutDelay = MuseShortcutRunner.delayMinutes
    @State private var includeCoach = MuseIntegration.includesCoachNarratives
    @State private var folderLabel = MuseIntegration.folderLabel()
    @State private var lastMs = MuseIntegration.lastWrittenMs
    @State private var busy = false

    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var preview: String?

    var body: some View {
        ScreenScaffold(title: "Integration",
                       subtitle: "A daily digest another app can read.",
                       topBackground: liquidScaffoldSky()) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                explainerCard
                destinationCard
                scheduleCard
                contentCard
                actionsCard
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: Binding(get: { preview != nil },
                                    set: { if !$0 { preview = nil } })) {
            previewSheet
        }
    }

    // MARK: Cards

    private var explainerCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What this writes")
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text("One small text file holding the key numbers from your last 24 hours — today so far, last night, and yesterday's grade. The same file is overwritten each day, so whatever reads it can point at one path.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This is not a backup. It cannot restore NOOP, and Backup & Sync is still the thing that protects your data.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var destinationCard: some View {
        StrandCard(padding: 20, tint: folderLabel != nil ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Where it goes", overline: "Destination")
                if let label = folderLabel {
                    Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    if let dest = MuseIntegration.destinationDescription() {
                        Text(dest).font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("No folder chosen yet.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
                NoopButton(folderLabel == nil ? "Choose folder…" : "Change folder…",
                           systemImage: "folder", kind: .secondary) { chooseFolder() }
                    .disabled(busy)
                #if os(iOS)
                if !MuseIntegration.useInternalFolder {
                    NoopButton("Use NOOP's own folder (browse in Files)",
                               systemImage: "iphone", kind: .tertiary) { useNoopFolder() }
                        .disabled(busy)
                }
                #endif

                Divider().overlay(StrandPalette.hairline)

                VStack(alignment: .leading, spacing: 4) {
                    Text("File name").font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    TextField(MuseIntegration.defaultFilename, text: $basename)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        #if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit { commitBasename() }
                    Text("Saved as \(MuseIntegration.resolvedFilename). The name never changes between days — the file is replaced, not added to.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var scheduleCard: some View {
        StrandCard(padding: 20, tint: enabled && folderLabel != nil ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Write it on a schedule").font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Written in the background on a strap sync — opening NOOP is not required. The times are set below.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("Write it on a schedule", isOn: $enabled)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .disabled(folderLabel == nil)
                        .onChangeCompat(of: enabled) { on in MuseIntegration.isEnabled = on }
                }
                // 261006: explicit clock times, replacing the "N× a day from the sleep window's end"
                // cadence — whose first slot fired MID-SLEEP on any longer-than-window night and
                // shipped a partial-night digest to the reader. Pick the times; an empty slot is
                // skipped.
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("When it's written").font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Up to \(MuseIntegration.slotCount) times a day. Each write happens at the next opportunity after its time — a strap sync in the background, or opening NOOP — so a missed time catches up rather than being skipped. With no times set, nothing is written automatically.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(0..<MuseIntegration.slotCount, id: \.self) { i in
                        slotRow(i)
                    }
                }
                NoopButton("Sync now", systemImage: "arrow.clockwise", kind: .secondary) {
                    generateNow()
                }
                .disabled(busy || folderLabel == nil)
                Divider().overlay(StrandPalette.hairline)

                // Chain a Shortcut onto every write (260924): the digest's reader IS a Shortcut, so
                // the file can ship itself. Blank name = feature off.
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run a Shortcut after each update").font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Runs the named Shortcut after the delay — give iCloud a minute to upload the file first. If NOOP isn't frontmost when it comes due (iOS only lets the open app launch a Shortcut), it runs at the next opportunity: the next strap sync with the app open, or the next time you open NOOP.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        TextField("Shortcut name (blank = off)", text: $shortcutName)
                            .textFieldStyle(.plain)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                            .disableAutocorrection(true)
                            .onChangeCompat(of: shortcutName) { MuseShortcutRunner.shortcutName = $0 }
                            .accessibilityLabel("Shortcut name")
                        Picker("Delay", selection: $shortcutDelay) {
                            ForEach([0, 1, 2, 3, 5, 10, 15, 30], id: \.self) { m in
                                Text(m == 0 ? String(localized: "right away") : String(localized: "+\(m) min")).tag(m)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).tint(StrandPalette.accent)
                        .onChangeCompat(of: shortcutDelay) { MuseShortcutRunner.delayMinutes = $0 }
                        .accessibilityLabel("Delay before the Shortcut runs")
                    }
                    if !shortcutName.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button {
                            MuseShortcutRunner.runNow()
                        } label: {
                            Label("Test run now", systemImage: "play.circle")
                                .font(StrandFont.footnote)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityLabel("Run the Shortcut now to test it")
                    }
                }

                Text(lastMs > 0 ? "Last written: \(relativeTime(lastMs))" : "Not written yet.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                if let err = MuseIntegration.lastError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                        Text(err).font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var contentCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("What goes in", overline: "Content")
                Text("Always included: today's charge, effort, heart rate and HRV so far; last night's sleep stages, efficiency and disturbances; and yesterday's day-quality grade with every component that drove it.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include the coach's summaries").font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Adds NOOP's written read on each tab. Costs one provider call per section, each time the file is generated.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("Include the coach's summaries", isOn: $includeCoach)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .onChangeCompat(of: includeCoach) { on in
                            MuseIntegration.includesCoachNarratives = on
                        }
                }
            }
        }
    }

    private var actionsCard: some View {
        StrandCard(padding: 20) {
            NoopButton("Preview without writing", systemImage: "eye", kind: .tertiary) {
                previewOnly()
            }
            .disabled(busy)
        }
    }

    // MARK: Slot rows (261006)

    /// One of the six write times: a picker when filled, an "Add" affordance when empty. The row
    /// keeps its position either way, so a wearer's "morning / lunch / evening" layout survives
    /// clearing the middle one.
    private func slotRow(_ i: Int) -> some View {
        HStack(spacing: 10) {
            Text("Time \(i + 1)")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 0)
            if slots.indices.contains(i), slots[i] != MuseIntegration.emptySlot {
                DatePicker("Time \(i + 1)", selection: slotBinding(i),
                           displayedComponents: [.hourAndMinute])
                    .labelsHidden()
                    .tint(StrandPalette.accent)
                Button {
                    slots[i] = MuseIntegration.emptySlot
                    MuseIntegration.slotMinutesRaw = slots
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(StrandFont.body).foregroundStyle(StrandPalette.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear time \(i + 1)")
            } else {
                Button {
                    slots[i] = nextSlotSeedMinute()
                    MuseIntegration.slotMinutesRaw = slots
                } label: {
                    Label("Add", systemImage: "plus.circle")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add time \(i + 1)")
            }
        }
    }

    /// Minute-of-day ↔ Date for the system picker, on an arbitrary reference day — only the clock
    /// components are kept.
    private func slotBinding(_ i: Int) -> Binding<Date> {
        Binding(
            get: {
                let m = max(slots.indices.contains(i) ? slots[i] : 0, 0)
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60,
                                             second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                slots[i] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                MuseIntegration.slotMinutesRaw = slots
            })
    }

    /// A seed for a freshly added slot: an hour after the latest filled time, or 09:00 on an empty
    /// schedule — a plausible next write rather than midnight.
    private func nextSlotSeedMinute() -> Int {
        let filled = MuseIntegration.enabledSlots(slots)
        guard let latest = filled.last else { return 9 * 60 }
        return (latest + 60) % (24 * 60)
    }

    private var previewSheet: some View {
        NavigationStack {
            ScrollView {
                Text(preview ?? "")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Digest preview")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { preview = nil }
                }
            }
        }
    }

    // MARK: Actions

    private func commitBasename() {
        MuseIntegration.filename = basename
        basename = MuseIntegration.filename      // reflect the sanitised form back
        folderLabel = MuseIntegration.folderLabel()
    }

    private func chooseFolder() {
        busy = true
        #if os(macOS)
        defer { busy = false }
        if MuseIntegration.pickFolder() != nil { folderLabel = MuseIntegration.folderLabel() }
        #else
        Task {
            defer { busy = false }
            let picked = await MuseIntegration.pickFolder()
            if picked != nil {
                folderLabel = MuseIntegration.folderLabel()
            } else if !MuseIntegration.useInternalFolder {
                alertTitle = String(localized: "No folder selected")
                alertMessage = String(localized: "NOOP didn't get a folder back from the picker. If the Open button won't do anything, tap \"Use NOOP's own folder\" to write inside NOOP instead — you can read that file from the Files app.")
                showAlert = true
            }
        }
        #endif
    }

    #if os(iOS)
    private func useNoopFolder() {
        MuseIntegration.useNoopFolder()
        folderLabel = MuseIntegration.folderLabel()
        alertTitle = String(localized: "Using NOOP's folder")
        alertMessage = String(localized: "The digest will be written inside NOOP. Open the Files app → On My iPhone → NOOP → Integration to see it, or drag that folder into iCloud Drive to read it elsewhere.")
        showAlert = true
    }
    #endif

    private func generateNow() {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await MuseIntegrationRunner.runNow(repo: model.repo, coach: coach)
                lastMs = MuseIntegration.lastWrittenMs
                alertTitle = String(localized: "Digest written")
                alertMessage = String(localized: "Saved \(MuseIntegration.resolvedFilename) to your folder.")
            } catch {
                alertTitle = String(localized: "Could not write")
                alertMessage = error.localizedDescription
            }
            showAlert = true
        }
    }

    /// Build the digest and show it WITHOUT touching the folder — so a wearer can see exactly what
    /// would leave the device before choosing to write it anywhere.
    private func previewOnly() {
        busy = true
        Task {
            defer { busy = false }
            let input = await MuseIntegrationRunner.gather(repo: model.repo,
                                                           coach: includeCoach ? coach : nil,
                                                           now: Date())
            preview = MuseIntegration.digest(input)
        }
    }

    // MARK: Formatting

    private func relativeTime(_ ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
