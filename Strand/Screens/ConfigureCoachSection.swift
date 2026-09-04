import SwiftUI
import StrandDesign

/// Settings → Configure coach: everything about HOW the coach works, in one place.
///
/// Moved wholesale out of `CoachView` at 260904 on maintainer instruction. It was 604 lines — 57% of
/// that screen — sitting above the chat: provider and key setup, model selection, the three
/// data-sharing consents, and four editable prompts. The Coach screen is now only the Q&A, so
/// "Ask the Coach" lands on the conversation rather than scrolling past configuration to reach it.
///
/// The code is MOVED, not rewritten: the same bodies, the same engine accessors, the same keychain
/// flow. Only the four prompt editors changed shape, and only because they now share
/// `CoachPromptEditor` instead of being four hand-rolled copies of one block.
///
/// Hosted by `SettingsView` inside a `SettingsDisclosureGroup`, collapsed by default — this is
/// set-once configuration, not something to scroll past on every visit to Settings.
struct ConfigureCoachSection: View {
    @EnvironmentObject var coach: AICoachEngine

    // State moved verbatim from CoachView, minus the composer's (`draft`, `composerFocused`), which
    // belong to the Q&A half and stayed there.
    @State private var keyDraft: String = ""
    @State private var customModel: Bool = false
    @State private var customModelDraft: String = ""
    @State private var showConnectedCustomModel: Bool = false
    @State private var showForgetKeyConfirm: Bool = false

    /// Sentinel tag for the "Custom…" entry in the model Picker.
    private let customModelTag = "__custom__"

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            // Connection first: nothing below it works until a provider and key are set.
            if coach.isConfigured {
                connectedHeader
            } else {
                setupCard
            }
            // What the coach is allowed to see. Each consent reveals the next, so a wearer who has
            // not granted the first is never shown toggles that would do nothing.
            consentBar
            if coach.dataConsent {
                onDeviceSignalsBar
                derivedTrendsBar
            }
            // How it writes. Four instructions, one editor.
            promptEditors
        }
        .onChangeCompat(of: coach.hasKey) { _ in keyDraft = "" }
    }

    /// The four editable instructions, each behind its own collapsible.
    ///
    /// `ai.dayQualityPrompt` joins them here (260904): it had no editor at all before, and was
    /// overridable only by writing UserDefaults by hand.
    private var promptEditors: some View {
        NoopCard(padding: 14) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                Text("Instructions").strandOverline()
                CoachPromptEditor(
                    title: String(localized: "Coach instructions"),
                    blurb: "Edit how the coach thinks and talks. Takes effect on your next message.",
                    customisedBlurb: "Customised. Your edited instructions frame every reply.",
                    icon: "text.alignleft",
                    text: Binding(get: { coach.customSystemPrompt },
                                  set: { coach.customSystemPrompt = $0 }),
                    isCustomised: coach.hasCustomSystemPrompt,
                    onReset: { coach.resetSystemPrompt() })
                Divider().overlay(StrandPalette.hairline)
                CoachPromptEditor(
                    title: String(localized: "Today synthesis instructions"),
                    blurb: "Edit how the Today paragraph is written. Takes effect on the next refresh.",
                    customisedBlurb: "Customised. Your edited instructions shape the Today paragraph.",
                    icon: "text.badge.star",
                    text: Binding(get: { coach.customSynthesisPrompt },
                                  set: { coach.customSynthesisPrompt = $0 }),
                    isCustomised: coach.hasCustomSynthesisPrompt,
                    onReset: { coach.resetSynthesisPrompt() })
                Divider().overlay(StrandPalette.hairline)
                CoachPromptEditor(
                    title: String(localized: "Notification title instructions"),
                    blurb: "Edit how coach-written notification titles are phrased.",
                    customisedBlurb: "Customised. Your edited instructions phrase every nudge title.",
                    icon: "bell.badge",
                    text: Binding(get: { coach.customNotificationTitlePrompt },
                                  set: { coach.customNotificationTitlePrompt = $0 }),
                    isCustomised: coach.hasCustomNotificationTitlePrompt,
                    onReset: { coach.resetNotificationTitlePrompt() })
                Divider().overlay(StrandPalette.hairline)
                CoachPromptEditor(
                    title: String(localized: "Day quality instructions"),
                    blurb: "Edit how yesterday's day-quality summary is written, in Trends.",
                    customisedBlurb: "Customised. Your edited instructions write the Trends summary.",
                    icon: "chart.line.uptrend.xyaxis",
                    text: Binding(get: { coach.customDayQualityPrompt },
                                  set: { coach.customDayQualityPrompt = $0 }),
                    isCustomised: coach.hasCustomDayQualityPrompt,
                    onReset: { coach.resetDayQualityPrompt() })
            }
        }
    }

    private var setupCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Connect a provider")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }

                Text("Coach uses your own API key. Pick a provider, paste a key, and choose a model. Your key is stored securely in the Keychain and never leaves \(Platform.deviceNounPhrase) except as the request you make.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Provider
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider").strandOverline()
                    Picker("Provider", selection: $coach.provider) {
                        ForEach(AIProvider.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Provider")
                }

                // Server URL (Custom / local LLM only)
                if coach.provider == .custom {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Server URL").strandOverline()
                        TextField("http://localhost:11434/v1", text: $coach.customBaseURL)
                            .textFieldStyle(.plain)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                            .disableAutocorrection(true)
                            .accessibilityLabel("Server URL")
                        Text("Any OpenAI-compatible server: Ollama, LM Studio, llama.cpp, or your own gateway. Stays on your network; nothing leaves \(Platform.deviceNounPhrase).")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Key header").strandOverline()
                        Picker("Key header", selection: $coach.customAuthHeader) {
                            ForEach(CustomAIAuthHeader.allCases) { header in
                                Text(header.displayName).tag(header)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Key header")
                        Text("Use Bearer for most local servers; use x-api-key for gateways that require the key in that header.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Model
                modelSelector

                // Key
                VStack(alignment: .leading, spacing: 6) {
                    Text(coach.provider == .custom ? "API key (optional)" : "API key").strandOverline()
                    SecureField(coach.provider == .custom
                                ? "Only if your server requires one"
                                : "Paste your \(coach.provider.displayName) API key", text: $keyDraft)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .onSubmit { coach.provider == .custom ? connectCustom() : saveKey() }
                        .accessibilityLabel("API key")
                }

                HStack(spacing: 10) {
                    if coach.provider == .custom {
                        NoopButton("Connect", systemImage: "link", kind: .primary, action: connectCustom)
                            .disabled(coach.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        NoopButton(coach.hasKey ? "Replace key" : "Save key",
                                   systemImage: "key.fill", kind: .primary, action: saveKey)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    // Forgetting a key is now a NAMED, confirmed action rather than the side effect of
                    // tapping a gear. Shown only for a provider that has something to forget.
                    if coach.hasKey {
                        NoopButton("Forget key", systemImage: "trash", kind: .secondary) {
                            showForgetKeyConfirm = true
                        }
                        .accessibilityLabel("Forget the saved \(coach.provider.displayName) key")
                    }

                    // The way OUT of this card, and it has to live HERE.
                    //
                    // "Save key" is disabled while the key field is empty, and that field is transient:
                    // cleared after every save and never prefilled from the Keychain, because a stored
                    // secret cannot be read back into a field. So selecting a provider with no stored
                    // key leaves the card with every control dead. There is no toolbar in this state
                    // either — `isConfigured` gates it — so the card must carry its own exit.
                    //
                    // Switching BACK is the action that helps, and the provider Picker above can do it,
                    // but only if the user works out that the Picker is the escape. This states it:
                    // jump straight to a provider that is ready, named so it is obvious where it goes.
                    if let ready = readyProviderToReturnTo {
                        NoopButton("Back to \(ready.displayName)", systemImage: "arrow.uturn.backward",
                                   kind: .secondary) {
                            coach.provider = ready
                            keyDraft = ""
                        }
                        .accessibilityLabel("Return to \(ready.displayName), which already has a key")
                    }

                    Spacer()
                }

                Divider().overlay(StrandPalette.hairline)
                // The privacy note stayed on the Coach screen with the chat it describes; the
                // provider card links the same idea in one line instead of duplicating it.
                Text("Only a compact text summary of your metrics and your question are sent, and only to the provider you choose here.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Forget the saved \(coach.provider.displayName) key?",
                            isPresented: $showForgetKeyConfirm, titleVisibility: .visible) {
            Button("Forget key", role: .destructive) {
                coach.clearKey()
                keyDraft = ""
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The key is deleted from the Keychain and has to be pasted again to use \(coach.provider.displayName). Your other providers' keys are not affected.")
        }
    }

    /// Connected header. The model half of the pill is a live menu, not a label: switching models
    /// within the connected provider used to be reachable ONLY through the setup card, which renders
    /// only while disconnected — so the sole route was the Disconnect button, and disconnecting forgot
    /// the key. Changing model therefore cost a re-entry of the key every single time. The key and the
    /// model are unrelated, so the menu changes the model in place and touches no credential.
    private var connectedHeader: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Model", selection: connectedModelSelection) {
                    ForEach(coach.availableModels, id: \.self) { m in
                        Text(m).tag(m)
                    }
                }
                Divider()
                Button("Custom model id…") { showConnectedCustomModel = true }
                Button {
                    Task { await coach.refreshModels() }
                } label: {
                    Label("Refresh models", systemImage: "arrow.clockwise")
                }
                Divider()
                // The PROVIDER switcher belongs here too, not only in the setup card. Switching to a
                // provider with no stored key drops you into that card, whose own Picker is then the
                // only way back — but its Save button is dead while the key field is empty, and the
                // field can never be prefilled from the Keychain. That is a dead end reachable by
                // ordinary use. Offering the switch from the connected header means a provider that
                // already HAS a key is always one tap away, without passing through the card at all.
                Picker("Provider", selection: $coach.provider) {
                    ForEach(AIProvider.allCases) { p in
                        // Mark which providers can be switched to without typing anything, so the
                        // choice that strands you is visibly distinct from the ones that don't.
                        Text(coach.hasStoredKey(for: p) ? "\(p.displayName) ✓" : p.displayName).tag(p)
                    }
                }
            } label: {
                StatePill("\(coach.provider.displayName) · \(coach.model)", tone: .accent, showsDot: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Provider \(coach.provider.displayName), model \(coach.model). Change model")

            Spacer()
            if coach.sending {
                StatePill("Thinking", tone: .accent, pulsing: true)
            }
        }
        // Free-text id, same escape hatch the setup card offers, for a model the picker doesn't list.
        .alert("Custom model id", isPresented: $showConnectedCustomModel) {
            TextField("Model id", text: $customModelDraft)
            Button("Use") { applyCustomModel() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Send requests to \(coach.provider.displayName) using this model id.")
        }
    }

    /// Binds the connected-header menu straight to `coach.model`. No "Custom…" sentinel here — the
    /// free-text path is its own menu item, so every tag in this picker is a real model id.
    private var connectedModelSelection: Binding<String> {
        Binding(get: { coach.model }, set: { coach.model = $0 })
    }

    /// Model selector: a Picker over `coach.availableModels` with a free-text "Custom…" path and a
    /// "Refresh models" button that fetches the provider's live list.
    private var modelSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Model").strandOverline()
                Spacer()
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
                .help("Fetch the available models from \(coach.provider.displayName) using your saved key")
                .accessibilityLabel("Refresh models from provider")
            }

            Picker("Model", selection: modelPickerSelection) {
                ForEach(coach.availableModels, id: \.self) { m in
                    Text(m).tag(m)
                }
                Divider()
                Text("Custom…").tag(customModelTag)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Model")

            if customModel {
                HStack(spacing: 8) {
                    TextField("Enter a model id", text: $customModelDraft)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .onSubmit(applyCustomModel)
                        .accessibilityLabel("Custom model id")

                    Button("Use", action: applyCustomModel)
                        .buttonStyle(NoopButtonStyle(.secondary))
                        .disabled(customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Use custom model")
                }
            }
        }
    }

    /// Bridges the model Picker to `coach.model`, with a "Custom…" sentinel that opens the free-text
    /// field instead of selecting a real id.
    private var modelPickerSelection: Binding<String> {
        Binding(
            get: { customModel ? customModelTag : coach.model },
            set: { newValue in
                if newValue == customModelTag {
                    customModel = true
                    if customModelDraft.isEmpty { customModelDraft = coach.model }
                } else {
                    customModel = false
                    coach.model = newValue
                }
            }
        )
    }

    private func applyCustomModel() {
        let trimmed = customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setCustomModel(trimmed)
        customModel = false
    }

    /// A provider other than the selected one that is already usable, if any — the destination for the
    /// setup card's escape hatch. Nil when nothing is configured yet (a first run, where the card is the
    /// correct place to be and there is nowhere to go back TO), so the button appears only when it can
    /// actually rescue someone.
    private var readyProviderToReturnTo: AIProvider? {
        AIProvider.allCases.first { $0 != coach.provider && coach.hasStoredKey(for: $0) }
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
                    Text(coach.dataConsent
                         ? "On: your charge, rest, HRV and workouts are shared with the provider for tailored coaching."
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




    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setKey(trimmed)
        keyDraft = ""
    }

    /// Commit the Custom (local) provider: save an optional key, then connect on the entered URL.
    private func connectCustom() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            coach.setKey(trimmed)
            keyDraft = ""
        }
        coach.connectCustom()
    }
}
