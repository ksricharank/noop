import SwiftUI
import StrandDesign

/// Coach settings, split out of `CoachView` so the coach screen is the conversation and nothing else
/// (#2243). Holds the surfaces that used to stack above the transcript: the data-sharing consent, the
/// two further opt-ins that depend on it, the editable coach instructions, and the morning brief.
///
/// Connection management (the provider pill, Clear conversation, Disconnect) deliberately stays on
/// `CoachView`. Disconnect is the only route back to the setup card, which is the only place a key can
/// be typed, and #2206 is the record of what happened the last time that control was put somewhere a
/// presentation did not render it. The Kotlin twin `CoachSettingsScreen` splits on the same line.
///
/// Presented as a sheet rather than pushed. CoachView appears in three places between the two
/// platforms (a macOS route, an iPhone tab root whose navigation bar is hidden, and an iPhone pillar
/// sheet), and a sheet is the one presentation that behaves the same in all three without depending on
/// an enclosing NavigationStack.
struct CoachSettingsView: View {
    @EnvironmentObject var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss

    /// Morning-brief settings, read from `CoachBriefScheduler` on init exactly as `CoachView` did
    /// before the split. This screen can now be the first to render them.
    @State private var briefEnabled: Bool = CoachBriefScheduler.isEnabled
    @State private var briefMinutes: Int = CoachBriefScheduler.timeMinutes
    @State private var briefGenerating = false
    @State private var briefStatus: String?

    /// The coach-instructions editor, collapsed until asked for.
    @State private var promptExpanded: Bool = false
    @State private var promptDraft: String = ""
    /// Whether the editable Today-synthesis prompt section is expanded. Collapsed by default, and a
    /// separate section from the coach prompt because the two frame different surfaces.
    @State private var synthesisPromptExpanded: Bool = false
    /// Working copy of the synthesis instruction while editing, committed to the engine on change so
    /// an edit takes effect on the next Today refresh. Seeded when the editor opens.
    @State private var synthesisPromptDraft: String = ""
    /// 260903: the editable instruction behind every coach-written notification title.
    @State private var notifTitlePromptExpanded: Bool = false
    @State private var notifTitlePromptDraft: String = ""

    var body: some View {
        // Literals, not String(localized:): `title`/`subtitle` are LocalizedStringKey, which converts
        // from a string LITERAL only, so a String value does not type-check here. The catalog keys are
        // these exact English strings.
        //
        // Done goes in the scaffold's `trailing` slot rather than a .toolbar. ScreenScaffold is a bare
        // ScrollView with no NavigationStack, so a toolbar item presented in a sheet would render
        // nowhere, and a macOS sheet has no swipe-to-dismiss: that combination would leave this screen
        // with no way out. (#2206 is the same mistake in the other direction.)
        ScreenScaffold(title: "Coach settings",
                       subtitle: "What the coach may read, how it is told to answer, and when it writes to you.",
                       topBackground: liquidScaffoldSky(),
                       trailing: {
                           Button("Done") { dismiss() }
                               .buttonStyle(.plain)
                               .font(StrandFont.subhead)
                               .foregroundStyle(StrandPalette.accent)
                               .accessibilityLabel("Close coach settings")
                       }) {
            modelBar
            consentBar
            // v5: a SECOND opt-in, only meaningful once data access is on, folds a summary of the
            // new on-device signals (your strongest patterns + Lab Book) into the coach context.
            if coach.dataConsent { onDeviceSignalsBar }
            if coach.dataConsent && coach.provider == .gemini { multimodalChartBar }
            // A THIRD opt-in, likewise only meaningful once data access is on: widen the per-day
            // detail and append deterministic on-device trends. Same rows, more resolution. Feeds the
            // Today synthesis as well as the chat, since both share `buildFullContext()`.
            if coach.dataConsent { derivedTrendsBar }
            systemPromptBar
            morningBriefBar
            synthesisPromptBar
            notifTitlePromptBar
        }
        // Opening this screen is the moment a stale catalogue is worth refreshing: a key exists here by
        // definition, and the picker above is about to be read. Rate-limited and silent on failure.
        .task { await coach.refreshModelsIfStale() }
    }

    /// Which model answers, and the control that refreshes the list of them.
    ///
    /// This lives HERE rather than on the setup card because of where a key exists. `setupCard` renders
    /// only while `isConfigured` is false, which for a cloud provider means no key is stored, and the
    /// Refresh control is `.disabled(!coach.hasKey)` — gated on having a key inside a screen that only
    /// appears when there is none. So for OpenAI, Anthropic and Gemini that button was permanently
    /// disabled and the live catalogue those three publish was unreachable. A key exists by definition
    /// on this screen, so the picker and the refresh both work.
    ///
    /// The PROVIDER deliberately stays on the setup card. A stored key records which provider it
    /// belongs to and is never sent anywhere else, so switching provider here would leave a key that
    /// cannot be used and a screen that cannot fix it. Kotlin twin: `CoachModelCard`.
    private var modelBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(coach.provider.displayName) · \(coach.model)")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    Button {
                        Task { await coach.refreshModels() }
                    } label: {
                        Label("Refresh models", systemImage: "arrow.clockwise")
                            .font(StrandFont.footnote)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    .disabled(!coach.hasKey)
                    .accessibilityLabel("Refresh models from provider")
                }
                Picker("Model", selection: $coach.model) {
                    ForEach(coach.availableModels, id: \.self) { m in
                        Text(m).tag(m)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("Model")
            }
        }
    }

    /// Explicit, revocable permission for the coach to read & send the user's data. Off by default.
    /// A frosted Charge-tinted card so it reads as part of the green Coach world, not a flat panel.
    private var consentBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.dataConsent ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(coach.dataConsent ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Let the coach use my data")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    // The ON line NAMES what a session carries rather than saying "workouts" and
                    // leaving the reader to guess how much that is: the sport, how long, how far and how
                    // hard, per session. This toggle is the only place someone is asked to agree to it.
                    // Android says the same sentence (#2033).
                    Text(coach.dataConsent
                         ? "On: your charge, rest, HRV and workouts are sent to the provider, each workout with its sport, duration, distance and heart rate."
                         : "Off: the coach answers generally and sends none of your metrics.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.dataConsent)
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Let the coach use my data")
            }
        }
    }

    /// The v5 second opt-in: include a SUMMARY of the new on-device signals (strongest n-of-1 patterns +
    /// Lab Book markers). Summary-only, never raw readings, so the no-raw-egress posture holds.
    private var onDeviceSignalsBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.includeOnDeviceSignals ? "checklist.checked" : "checklist")
                    .foregroundStyle(coach.includeOnDeviceSignals ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Also share my patterns & Lab Book")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(coach.includeOnDeviceSignals
                         ? "On: a short summary of your strongest patterns and logged health numbers is added. Summaries only, never raw readings."
                         : "Off: only your core metrics are shared, not your patterns or Lab Book.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.includeOnDeviceSignals)
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Also share my patterns and Lab Book with the coach")
            }
        }
    }

    /// K11: Third opt-in — send a chart image alongside the text when using Gemini's multimodal
    /// API. Only shown when the provider is Gemini. OFF by default.
    private var multimodalChartBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.multimodalChartEnabled ? "photo.badge.checkmark" : "photo")
                    .foregroundStyle(coach.multimodalChartEnabled ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Send chart image to Gemini")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(coach.multimodalChartEnabled
                         ? "On: a chart snapshot of your trends is sent with each question. Gemini can analyze the visual."
                         : "Off: only text is sent. Enable to let Gemini see your charts.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.multimodalChartEnabled)
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Send chart image to Gemini")
            }
        }
    }

    /// A THIRD opt-in: widen the per-day rows with the sleep-architecture / autonomic fields the coach
    /// already holds (deep/REM, efficiency, disturbances, SDNN, absolute skin temp) and append a block of
    /// deterministic on-device trends (training load, sleep debt, personal-baseline deviations).
    ///
    /// This adds RESOLUTION, not reach: every figure is computed from the same days already summarised
    /// above, so no new data category leaves the device and the summary-only posture is unchanged.
    ///
    /// It applies to the Today synthesis too — both surfaces build on `buildFullContext()` — so the copy
    /// names both rather than implying this is chat-only.
    private var derivedTrendsBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.includeDerivedTrends ? "chart.line.uptrend.xyaxis.circle.fill" : "chart.line.uptrend.xyaxis.circle")
                    .foregroundStyle(coach.includeDerivedTrends ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Also share additional data & trends")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(coach.includeDerivedTrends
                         ? "On: adds sleep stages, efficiency, SDNN and skin temperature to each day, plus training load, sleep debt and how today compares with your own baseline. Used by the Today synthesis as well as this chat. All computed on \(Platform.deviceNounPhrase) from the days already shared."
                         : "Off: only the core daily figures are shared, without sleep detail or computed trends.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.includeDerivedTrends)
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Also share additional data and trends with the coach")
            }
        }
    }

    /// Editable system prompt, the instructions that frame the coach. Collapsed by default; expanding
    /// reveals a TextEditor bound to the engine (edits persist to UserDefaults and take effect on the
    /// next message) plus a Reset-to-default control.
    private var systemPromptBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: promptExpanded ? 10 : 0) {
                Button {
                    withAnimation(StrandMotion.fade) {
                        promptExpanded.toggle()
                        if promptExpanded { promptDraft = coach.customSystemPrompt }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "text.alignleft")
                            .foregroundStyle(coach.hasCustomSystemPrompt ? StrandPalette.accent : StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Coach instructions")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(coach.hasCustomSystemPrompt
                                 ? "Customised. Your edited instructions frame every reply."
                                 : "Edit how the coach thinks and talks. Takes effect on your next message.")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: promptExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(promptExpanded ? "Collapse coach instructions" : "Edit coach instructions")

                if promptExpanded {
                    TextEditor(text: $promptDraft)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140, maxHeight: 240)
                        .padding(8)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .onChangeCompat(of: promptDraft) { newValue in
                            coach.customSystemPrompt = newValue
                        }
                        .accessibilityLabel("Coach instructions editor")

                    HStack {
                        Spacer()
                        Button {
                            coach.resetSystemPrompt()
                            promptDraft = coach.customSystemPrompt
                        } label: {
                            Label("Reset to default", systemImage: "arrow.uturn.backward")
                                .font(StrandFont.footnote)
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.accent)
                        .disabled(!coach.hasCustomSystemPrompt)
                        .accessibilityLabel("Reset coach instructions to default")
                    }
                }
            }
        }
    }

    /// K5: the scheduled morning-brief notification settings — enable toggle, time-of-day picker, and an
    /// explicit "Generate now" button. Mirrors the `ScheduledDebugExport` settings row shape (TestCentreView).
    private var morningBriefBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: briefEnabled ? "sunrise.fill" : "sunrise")
                        .foregroundStyle(briefEnabled ? StrandPalette.accent : StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Morning brief").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(briefEnabled
                             ? "A local notification with today's readiness + training plan, generated on-device each morning."
                             : "Off: nothing is generated or sent on a schedule.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $briefEnabled)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .accessibilityLabel("Morning brief")
                }
                .onChangeCompat(of: briefEnabled) { on in
                    CoachBriefScheduler.setEnabled(on, generateBrief: { await coach.generateBrief() }) { outcome in
                        if outcome == .denied {
                            briefEnabled = false
                            briefStatus = "Notifications are off for NOOP — enable them in Settings first."
                        }
                    }
                }

                if briefEnabled {
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        Text("Time").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        DatePicker("", selection: briefTimeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityLabel("Morning brief time")
                    }
                    Text("At \(Platform.deviceNounPhrase == "Mac" ? "this time" : "or soon after"), NOOP will use your key to generate today's brief. Best-effort: \(Platform.deviceNounPhrase) decides exactly when a backgrounded app wakes.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    NoopButton(briefGenerating ? "Generating…" : "Generate now", systemImage: "sparkles", kind: .secondary) {
                        generateBriefNow()
                    }
                    .disabled(briefGenerating)
                    if let briefStatus {
                        Text(briefStatus).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    private var synthesisPromptBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: synthesisPromptExpanded ? 10 : 0) {
                Button {
                    withAnimation(StrandMotion.fade) {
                        synthesisPromptExpanded.toggle()
                        if synthesisPromptExpanded { synthesisPromptDraft = coach.customSynthesisPrompt }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "text.alignleft")
                            .foregroundStyle(coach.hasCustomSynthesisPrompt ? StrandPalette.accent : StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Today synthesis instructions")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(coach.hasCustomSynthesisPrompt
                                 ? "Customised. Your edited instructions shape the Today paragraph."
                                 : "Edit the paragraph the coach writes on Today. Takes effect on the next refresh.")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: synthesisPromptExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(synthesisPromptExpanded ? "Collapse Today synthesis instructions" : "Edit Today synthesis instructions")

                if synthesisPromptExpanded {
                    TextEditor(text: $synthesisPromptDraft)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 100, maxHeight: 200)
                        .padding(8)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .onChangeCompat(of: synthesisPromptDraft) { newValue in
                            coach.customSynthesisPrompt = newValue
                        }
                        .accessibilityLabel("Today synthesis instructions editor")

                    HStack {
                        Spacer()
                        Button {
                            coach.resetSynthesisPrompt()
                            synthesisPromptDraft = coach.customSynthesisPrompt
                        } label: {
                            Label("Reset to default", systemImage: "arrow.uturn.backward")
                                .font(StrandFont.footnote)
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.accent)
                        .disabled(!coach.hasCustomSynthesisPrompt)
                        .accessibilityLabel("Reset Today synthesis instructions to default")
                    }
                }
            }
        }
    }

    /// Editable instruction for coach-written NOTIFICATION TITLES (260903) — the pace check, the
    /// water reminder and the move reminder all route through it. A sibling of `synthesisPromptBar`
    /// and deliberately the same shape. The 32-character bound lives in the prompt (with examples)
    /// AND in code, so an edit that drops the limit still cannot post a clipped title.
    private var notifTitlePromptBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: notifTitlePromptExpanded ? 10 : 0) {
                Button {
                    withAnimation(StrandMotion.fade) {
                        notifTitlePromptExpanded.toggle()
                        if notifTitlePromptExpanded {
                            notifTitlePromptDraft = coach.customNotificationTitlePrompt
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bell.badge")
                            .foregroundStyle(coach.hasCustomNotificationTitlePrompt
                                             ? StrandPalette.accent : StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Notification title instructions")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(coach.hasCustomNotificationTitlePrompt
                                 ? "Customised. Your edited instructions title every nudge."
                                 : "Edit the one-line titles the coach writes for pace, water and move nudges.")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: notifTitlePromptExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(notifTitlePromptExpanded
                                    ? "Collapse notification title instructions"
                                    : "Edit notification title instructions")

                if notifTitlePromptExpanded {
                    TextEditor(text: $notifTitlePromptDraft)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 100, maxHeight: 200)
                        .padding(8)
                        .background(StrandPalette.surfaceInset,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .onChangeCompat(of: notifTitlePromptDraft) { newValue in
                            coach.customNotificationTitlePrompt = newValue
                        }
                        .accessibilityLabel("Notification title instructions editor")

                    Text("Titles longer than \(AICoachEngine.notificationTitleMaxChars) characters are shortened at a word boundary, or dropped for the plain title — iOS clips a long title on the Lock Screen.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Spacer()
                        Button {
                            coach.resetNotificationTitlePrompt()
                            notifTitlePromptDraft = coach.customNotificationTitlePrompt
                        } label: {
                            Label("Reset to default", systemImage: "arrow.uturn.backward")
                                .font(StrandFont.footnote)
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.accent)
                        .disabled(!coach.hasCustomNotificationTitlePrompt)
                        .accessibilityLabel("Reset notification title instructions to default")
                    }
                }
            }
        }
    }

    private var briefTimeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = briefMinutes / 60
                c.minute = briefMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                briefMinutes = m
                CoachBriefScheduler.setTimeMinutes(m, generateBrief: { await coach.generateBrief() })
            }
        )
    }

    private func generateBriefNow() {
        Task {
            briefGenerating = true
            briefStatus = nil
            defer { briefGenerating = false }
            let text = await CoachBriefScheduler.generateNow { await coach.generateBrief() }
            if let text {
                coach.appendGeneratedBrief(text)
            } else {
                briefStatus = "Couldn't generate a brief right now — check your key and data access."
            }
        }
    }
}
