import SwiftUI
import MarkdownUI
import StrandDesign

/// Coach, the one feature in NOOP that talks to the network.
///
/// It is strictly opt-in and bring-your-own-key: the user pastes their own OpenAI
/// or Anthropic API key (stored in the macOS Keychain by `AICoachEngine`), and only
/// a compact text summary of their metrics plus their question ever leaves the Mac.
/// Nothing is sent until a key is saved and a question asked.
///
/// This screen compiles against `AICoachEngine`'s public API (the macos-core agent's
/// contract): `hasKey`, `provider` / `provider.modelOptions`, `model`, `messages`,
/// `sending`, `errorText`, `setKey(_:)`, `clearKey()`, and `send(_:)`.
struct CoachView: View {
    @EnvironmentObject var coach: AICoachEngine
    /// K8: used by "Save to Journal" — saves the coach advice as a journal entry with the text
    /// in the notes field, so it appears alongside other journal entries in Insights.
    @EnvironmentObject var repo: Repository

    /// Draft text in the composer (the question being typed).
    /// K15: the composer draft is persisted to UserDefaults so it survives an app relaunch.
    /// Restored on first appear, saved on every change. Keyed identically to the Android twin.
    private static let draftKey = "coach.composerDraft"
    @State private var draft: String = UserDefaults.standard.string(forKey: "coach.composerDraft") ?? ""
    /// Pending key text in the setup card (never persisted here, handed to `setKey`).
    @State private var keyDraft: String = ""
    /// The corrected key, typed into the editor a rejection opens. Separate from `keyDraft` so the
    /// setup card's own field is untouched, and cleared on save so a secret does not sit in view state
    /// after it has been stored. Twin of the Kotlin `keyFix`.
    @State private var keyFix: String = ""
    /// Whether the model selector is in free-text "Custom…" mode.
    @State private var customModel: Bool = false
    /// The id typed in the "Custom…" field. Shared by the setup card's inline field and the connected
    /// header's prompt — only one of the two is ever on screen.
    @State private var customModelDraft: String = ""
    /// Whether the connected header's free-text model-id prompt is showing.
    @State private var showConnectedCustomModel: Bool = false
    /// Whether the provider-configuration sheet is showing (the gear). Presenting the same setup card
    /// as a sheet rather than routing through `isConfigured` means reaching it never requires being
    /// disconnected, and dismissing it never requires saving anything.
    @State private var showProviderConfig: Bool = false
    /// Whether the "Forget key" confirmation is showing. Deleting a credential asks first — the old
    /// gear did it on a single tap with no way to undo.
    @State private var showForgetKeyConfirm: Bool = false
    @FocusState private var composerFocused: Bool

    /// K2: confirmation gate for the destructive "Clear conversation" toolbar action.
    @State private var showClearConfirm = false
    /// #2243: the coach settings, presented as a sheet. See `CoachSettingsView` for why a sheet
    /// rather than a push.
    @State private var showSettings = false

    // K4: on-device voice input for the composer (iOS only). macOS gets a no-op stub via
    // `#if os(iOS)` guards — the shared file keeps compiling for both targets.
    #if os(iOS)
    @StateObject private var voiceInput = CoachVoiceInput()
    #endif

    /// Sentinel tag for the "Custom…" entry in the model Picker.
    private let customModelTag = "__custom__"

    /// Contextual suggestion chips, derived from today's bands by `AICoachEngine.suggestions`
    /// (→ `CoachSuggestions`). Falls back to a stable generic set when there is no data. Recomputed
    /// on each body evaluation so a fresh sync immediately updates the chips.
    private var suggestions: [String] { coach.suggestions }

    var body: some View {
        ScreenScaffold(title: "Coach",
                       subtitle: "Ask about your charge, effort, rest and workouts, grounded in your own numbers.",
                       // Liquid finish: the same full-bleed day-of-sky backdrop Today + the other liquid
                       // tabs carry, so Coach sits in one atmosphere. Static + non-interactive; the frosted
                       // message/setup cards below sit on the opaque canvas and stay legible.
                       topBackground: liquidScaffoldSky()) {
            if coach.isConfigured {
                connectedHeader
                transcript
                if let error = coach.errorText, !error.isEmpty {
                    errorBanner(error)
                    // A rejected key is the one failure the wearer can act on from here, and the
                    // message already tells them to: "Check the key and the provider you selected".
                    // Until this, the screen offered nowhere to check it. Rendered INSIDE the error
                    // branch, never on its own flag, so it cannot outlive the message justifying it.
                    if coach.keyRejected { keyRepairPanel }
                }
                // K7: show follow-up chips after each assistant reply (when the transcript is
                // non-empty and the last message is from the assistant and not mid-send);
                // otherwise show the initial contextual chips.
                if showFollowUpChips {
                    followUpChips
                } else {
                    suggestionChips
                }
                // Why Today's synthesis is blank. It fails silently by design there — the card falls
                // back to the rule-based read rather than showing a provider error — which left no way
                // to tell a broken provider from a quiet one. This is where that question gets answered.
                if let synthesisError = coach.lastSynthesisError, !synthesisError.isEmpty {
                    errorBanner("Today's synthesis: \(synthesisError)")
                }
                // What the last generation actually DID — which model ran, whether a fallback was
                // attempted, and how it ended. Without this the retry is invisible: a blank result
                // cannot be told apart from a retry that ran and failed, which is precisely the
                // ambiguity that made "the fallback doesn't work" unanswerable from inside the app.
                if let trace = coach.lastAttemptTrace, !trace.isEmpty {
                    attemptTraceNote(trace)
                }
                suggestionChips
                composer
                // K12: show a rough token estimate when the draft is non-empty.
                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let tokens = coach.estimatedTokens(forDraft: draft) {
                    tokenEstimateBar(tokens)
                }
                privacyFootnote
            } else {
                setupCard
            }
        }
        // macOS only. On iOS these two live in `connectionMenu` instead, because this bar is hidden for
        // a primary tab root and VISIBLE in the pillar sheet, so leaving them here would render nothing
        // on the Coach tab and a duplicate of the menu in the sheet. One control per platform, reachable
        // in both of iOS's presentations. The `#if` sits on the CHAIN rather than inside the builder:
        // `ToolbarContentBuilder` is not relied on to accept an empty body, and the one other
        // conditional toolbar here (CoupledView) always yields an item on both platforms. (#2206)
        #if os(macOS)
        .toolbar {
            if coach.isConfigured {
                // K2: wipe the persisted + in-memory conversation. Confirmed, since it's destructive.
                ToolbarItem {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("Clear conversation", systemImage: "trash")
                    }
                    .help("Clear the saved conversation")
                    .accessibilityLabel("Clear conversation")
                    .disabled(coach.messages.isEmpty)
                }
                ToolbarItem {
                    // OPENS the provider configuration; it does not destroy anything.
                    //
                    // This was a `.destructive` button that called `disconnect()` on a single tap, with
                    // no confirmation — labelled "Disconnect" but wearing a gear, which reads as
                    // settings. Tapping it deleted the saved key and dropped the user into the setup
                    // card, and under the old single-slot store that was the ONLY stored key. A gear
                    // that silently destroys a credential is a trap regardless of its label, so the
                    // gear now means what it looks like it means. Forgetting a key is still available,
                    // as a named and confirmed action inside the card.
                    Button {
                        showProviderConfig = true
                        keyDraft = ""
                    } label: {
                        Label("Configure providers", systemImage: "gearshape")
                    }
                    .help("Add or replace API keys and switch provider")
                    .accessibilityLabel("Configure providers")
                }
            }
        }
        #endif
        // #2243: coach settings. `repo` rides along because the scaffold's environment is not
        // inherited by a sheet's own view tree.
        .sheet(isPresented: $showSettings) {
            CoachSettingsView()
                .environmentObject(coach)
                .environmentObject(repo)
        }
        .confirmationDialog(
            "Clear conversation?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { coach.clearConversation() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the saved conversation from this device. Coach history is your own notes, not medical advice.")
        }
        // K2 + K5 ordering matters and every step gates on an EMPTY transcript, so this is ONE `.task`
        // running sequentially (separate `.task`s can interleave at their await points on the same
        // actor): restore whatever the prior launch persisted, THEN surface a brief the scheduled
        // notification already generated (if any), THEN the interactive first-open brief — so
        // `startBriefIfNeeded` only ever runs over the network when BOTH of the above left the
        // transcript genuinely empty.
        .task {
            // 260922: load the on-device model before the first question, not during it.
            coach.prepareProviderIfNeeded()
            await coach.loadPersistedMessagesIfNeeded()
            // Gated on the transcript BEFORE consuming. `consumeStoredBrief()` clears the unconsumed
            // flag, and `surfaceScheduledBrief` then drops the text if a transcript exists, so a brief
            // that arrived on a day with a conversation already open was consumed and thrown away, gone
            // for good. Android checked first and so only ever failed to SHOW it (#2087).
            if coach.messages.isEmpty, let stored = CoachBriefScheduler.consumeStoredBrief() {
                coach.surfaceScheduledBrief(stored)
            }
            CoachBriefScheduler.activateIfEnabled { await coach.generateBrief() }
            await coach.startBriefIfNeeded()
        }
        // #1862: a question handed over by the Today launcher sheet. Cleared BEFORE sending so a view
        // rebuild mid-flight cannot send it twice, and gated on `isConfigured` so an unconfigured handoff
        // (which the launcher does not produce, but a future caller might) degrades to showing setup
        // rather than a failed request.
        //
        // 260920: the clear-before-send MUST NOT happen inside a `.task(id:)` keyed on the value
        // being cleared. `.task(id:)` cancels and restarts its body whenever the id changes, so
        // setting `pendingPrompt = nil` here cancelled the very task that was about to await
        // `send` — the request was torn down mid-flight and surfaced as
        // `URLError.cancelled` -> `.network("cancelled")` -> "Network problem: cancelled",
        // blaming the internet for a self-inflicted cancellation. It only showed up once the tab
        // summaries started seeding `pendingPrompt` (the Today launcher sets it and pushes in one
        // gesture, which raced past it); every other coach path worked, which is exactly why the
        // maintainer could see the summaries generate fine and this fail.
        //
        // `.onChangeCompat` + a detached-from-identity Task keeps the double-send guard (the value
        // is still cleared before the await) without the clearing being a cancellation trigger.
        .onChangeCompat(of: coach.pendingPrompt) { pending in
            guard let prompt = pending, !prompt.isEmpty else { return }
            coach.pendingPrompt = nil
            guard coach.isConfigured else { return }
            Task { await coach.send(prompt) }
        }
        // The same handoff, for a prompt that was ALREADY set before this view appeared — an
        // `.onChange` never fires for a value that did not change while it was mounted, which is
        // the case every time a tab seeds the prompt and THEN routes here.
        .task {
            guard let prompt = coach.pendingPrompt, !prompt.isEmpty else { return }
            coach.pendingPrompt = nil
            guard coach.isConfigured else { return }
            await coach.send(prompt)
        }
        // K15: persist the composer draft so it survives an app relaunch.
        .onChangeCompat(of: draft) { newValue in
            UserDefaults.standard.set(newValue, forKey: Self.draftKey)
        }
        // K14: haptic feedback when a reply arrives (sending goes true → false).
        .onChangeCompat(of: coach.sending) { isSending in
            if !isSending && !coach.messages.isEmpty {
                triggerReplyHaptic()
            }
        }
        // A consent toggle AFTER the initial load re-checks the brief (the original `.task(id:)`
        // behaviour); the guard inside `startBriefIfNeeded` (messages.isEmpty) keeps this a no-op once
        // a conversation exists.
        .onChangeCompat(of: coach.dataConsent) { _ in
            Task { await coach.startBriefIfNeeded() }
        }
        .task(id: coach.dataConsent) { await coach.startBriefIfNeeded() }
        // The gear's destination: the same provider-configuration card, presented so it can always be
        // left. Dismissing requires nothing — no key, no save — which is the property the old
        // disconnect-into-the-card path lacked and the whole reason it was a dead end.
        .sheet(isPresented: $showProviderConfig) {
            NavigationStack {
                ScrollView {
                    setupCard.padding(16)
                }
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationTitle("Providers")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showProviderConfig = false }
                    }
                }
            }
        }
        // Saving a key from the sheet has done its job — close it and return to the chat rather than
        // leaving the user on a configuration screen wondering whether it took.
        .onChangeCompat(of: coach.hasKey) { hasKey in
            if hasKey && showProviderConfig { showProviderConfig = false }
        }
    }

    // MARK: - Setup (no key yet)

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

                Text(AppleOnDeviceModel.isAvailable
                     ? "Coach uses your own API key, or Apple's on-device model, which needs none. Pick a provider, paste a key if it takes one, and choose a model. A key is stored securely in the Keychain and never leaves \(Platform.deviceNounPhrase) except as the request you make."
                     : "Coach uses your own API key. Pick a provider, paste a key, and choose a model. Your key is stored securely in the Keychain and never leaves \(Platform.deviceNounPhrase) except as the request you make.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Provider
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider").strandOverline()
                    Picker("Provider", selection: $coach.provider) {
                        ForEach(AIProvider.selectable) { p in
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

                if coach.provider == .appleOnDevice {
                    // 260922: nothing to configure. The model is the system's, there is no key, and
                    // `isConfigured` is already true when this is selectable — so this card is only
                    // reached from the Configure-providers sheet, where it says what to expect.
                    onDeviceNote
                } else {
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
                }

                // Whatever the last attempt from THIS card ran into. The setup card had no error line
                // at all, so every way it can fail before a key is committed failed silently: a Refresh
                // the provider turned away, a Connect to a server that wants auth. The wearer saw a
                // button do nothing. No repair affordance beside it, unlike the chat: the key field is
                // already on screen, which is the whole point of the card.
                if let error = coach.errorText, !error.isEmpty {
                    errorBanner(error)
                }

                Divider().overlay(StrandPalette.hairline)
                privacyFootnote
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

    /// What the setup card says for Apple's on-device model: where it runs, what it costs, and how it
    /// differs from the cloud providers (a small model with a short memory), so the first answer's
    /// brevity reads as designed rather than broken.
    private var onDeviceNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Runs entirely on \(Platform.deviceNounPhrase) using Apple Intelligence. No key, no account, no network — your data never leaves the device, and it works offline.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "iphone.gen3")
                    .foregroundStyle(StrandPalette.accent)
            }
            Text("It is a small model with a short memory: answers are brief, and long conversations are trimmed to fit. For deeper analysis, switch to a cloud provider from the header.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = AppleOnDeviceModel.unavailabilityNote {
                Text(note)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.signalYellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A provider other than the selected one that is already usable, if any — the destination for the
    /// setup card's escape hatch. Nil when nothing is configured yet (a first run, where the card is the
    /// correct place to be and there is nowhere to go back TO), so the button appears only when it can
    /// actually rescue someone.
    private var readyProviderToReturnTo: AIProvider? {
        AIProvider.selectable.first { $0 != coach.provider && coach.hasStoredKey(for: $0) }
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

    // MARK: - Connected state

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
                    ForEach(AIProvider.selectable) { p in
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
            // #2243: the way through to what used to be stacked under this header.
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Coach settings"))
            #if os(iOS)
            connectionMenu
            #endif
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

    #if os(iOS)
    /// #2206: the same two actions the toolbar above carries, drawn where iPhone can reach them.
    ///
    /// `RootTabView.tab(...)` wraps every primary tab root in a NavigationStack and applies
    /// `.toolbar(.hidden, for: .navigationBar)`, because each screen draws its own in-content header.
    /// So Clear conversation and Disconnect were being placed into a bar this platform never shows, and
    /// rendered nowhere. Disconnect is the ONLY route back to the setup card, which is the only place
    /// an API key can be typed: `isConfigured` gates that card away the moment a key is saved. The
    /// result was a key that could be set once and then never changed, with reinstalling the app the
    /// only way out, which on an offline-first app costs the wearer their entire history.
    ///
    /// macOS keeps the toolbar and does not get this, so its behaviour is untouched. On iOS the toolbar
    /// route is withdrawn rather than kept alongside: CoachView is presented twice on this platform, as
    /// a primary tab whose bar is hidden and as a pillar sheet whose bar is NOT (it draws a Done button
    /// and only hides the bar's background). Keeping both would render nothing on the tab and two of
    /// everything in the sheet. One control, reachable in both presentations.
    ///
    /// A menu rather than a bare button because it needs two taps to reach a destructive action,
    /// matching the protection the toolbar's separation gives, and because both actions belong to the
    /// same connection.
    ///
    /// Worth knowing before changing `disconnect()`: neither `hasKey` nor `isConfigured` is published,
    /// since `hasKey` reads the Keychain on each evaluation. The setup card reappears because
    /// `disconnect()` ALSO assigns the published `messages`, which is what re-evaluates the body. A
    /// future disconnect that stopped clearing the transcript would clear the key and leave this screen
    /// showing a chat for a connection that no longer exists. macOS has depended on the same coupling
    /// since its toolbar button existed, so this is a latent edge being written down, not a new one.
    private var connectionMenu: some View {
        Menu {
            Button {
                showClearConfirm = true
            } label: {
                Label("Clear conversation", systemImage: "trash")
            }
            .disabled(coach.messages.isEmpty)
            // Nothing to disconnect FROM on the keyless on-device provider: there is no key to forget
            // and no server to leave, and the action would land the wearer back on the same chat.
            // Switching provider is the header's job.
            if !coach.provider.isKeyless {
                Button(role: .destructive) {
                    coach.disconnect()
                    keyDraft = ""
                } label: {
                    Label("Disconnect", systemImage: "gearshape")
                }
            }
        } label: {
            // Same affordance DevicesView uses for its per-device menu, headline size included. The
            // size is not decoration here: the report this came from was that the option could not be
            // FOUND, so a control that matches the one the wearer has already learned, at a size worth
            // aiming at, is doing part of the work.
            Image(systemName: "ellipsis.circle")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityLabel("Connection")
    }
    #endif

    private var transcript: some View {
        StrandCard(padding: 16) {
            if coach.messages.isEmpty {
                emptyTranscript
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Lazy so off-screen bubbles aren't all resident/laid-out at once; with the
                        // `maxStoredMessages` cap the transcript is already bounded, this keeps render cost flat.
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(coach.messages) { message in
                                bubble(message).id(message.id)
                            }
                            if coach.sending {
                                typingIndicator.id("typing")
                            }
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // #697 parity: this screen builds its OWN ScrollView rather than going through
                    // ScreenScaffold, so it never inherited the scaffold's horizontal-bounce suppression and
                    // could still rubber-band left-right on a purely vertical scroll. Same modifier, same
                    // guard. `.basedOnSize` permits horizontal bounce only when content genuinely overflows
                    // the width, so nothing that is meant to scroll sideways is affected. (#1532 follow-up)
                    #if os(iOS)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    #endif
                    .frame(minHeight: 220, maxHeight: 460)
                    .onChangeCompat(of: coach.messages.count) { _ in
                        scrollToEnd(proxy)
                    }
                    .onChangeCompat(of: coach.sending) { _ in
                        scrollToEnd(proxy)
                    }
                }
            }
        }
    }

    private var emptyTranscript: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask your first question")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Coach reads a summary of your last two weeks plus 30-day averages and recent workouts, then answers in plain language. Try a suggestion below.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(StrandPalette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: 520, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You said: \(message.text)")
        case .assistant:
            // LLM replies arrive as Markdown (bold, lists, headings, tables),             // rendered with the chat-bubble-sized Strand theme. User bubbles stay
            // verbatim `Text` so typed `*`/`#` never turn into surprise formatting.
            // The reply sits on a frosted Charge-tinted surface, a card, not a flat box.
            // K8: context menu (long-press / right-click) with Copy, Share, and Save actions.
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Markdown(message.text)
                        .markdownTheme(.strand)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frostedCardSurface(tint: StrandPalette.chargeColor, cornerRadius: 16)
                        // K8: Copy / Share / Save context menu on assistant replies.
                        .contextMenu {
                            Button {
                                #if os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.text, forType: .string)
                                #else
                                UIPasteboard.general.string = message.text
                                #endif
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            ShareLink(item: message.text) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Button {
                                saveAdvice(message.text)
                            } label: {
                                Label("Save to Journal", systemImage: "square.and.pencil")
                            }
                        }

                    // Attribution on EVERY reply, naming whichever model wrote it.
                    //
                    // It used to appear only for a fallback, which made the label's absence carry the
                    // real information — "this came from the model you picked" — and that is invisible
                    // to anyone who does not already know the rule. Naming the model every time makes
                    // each reply self-describing; a substitution then stands out because the name
                    // differs from the picker, not because a label materialised.
                    //
                    // The fallback case still says so in words, since the model name alone does not
                    // tell you a substitution happened unless you remember what you had selected.
                    if let model = message.generatedByModel {
                        Text(message.cameFromFallback
                             ? "generated by \(model) (fallback)"
                             : "generated by \(model)")
                            .font(StrandFont.footnote)
                            .foregroundStyle(message.cameFromFallback
                                             ? StrandPalette.textSecondary
                                             : StrandPalette.textTertiary)
                            .padding(.horizontal, 4)
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                // K8 (upstream): Copy / Share / Save to Journal on an assistant reply. Attached to
                // the attribution VStack rather than to the Markdown, so the menu covers the whole
                // bubble including the "generated by" line. Lost once in the v17 uplift when this
                // VStack was introduced around upstream's Markdown — `saveAdvice` was left defined
                // but uncalled, which compiles clean and fails silently.
                .contextMenu {
                    Button {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                        #else
                        UIPasteboard.general.string = message.text
                        #endif
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: message.text) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        saveAdvice(message.text)
                    } label: {
                        Label("Save to Journal", systemImage: "square.and.pencil")
                    }
                }
                Spacer(minLength: 48)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message.generatedByModel.map { model in
                message.cameFromFallback
                    ? "Coach said, generated by \(model) as a fallback: \(message.text)"
                    : "Coach said, generated by \(model): \(message.text)"
            } ?? "Coach said: \(message.text)")
        }
    }

    private var typingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(StrandPalette.accent)
            Text("Coach is thinking…")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frostedCardSurface(tint: StrandPalette.chargeColor, cornerRadius: 16)
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityLabel("Coach is thinking")
    }

    private func errorBanner(_ message: String) -> some View {
        StrandCard(padding: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(StrandPalette.statusCritical)
                    .accessibilityHidden(true)
                Text(message)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.statusCritical)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }

    /// The inline "your key was turned away, here is the field" repair, shown under a rejection.
    ///
    /// Saving goes through `setKey`, which replaces the stored key and leaves the transcript alone. The
    /// existing route was the Disconnect button, which also wipes the conversation and un-commits a
    /// custom provider: far more than correcting a typo asks for, and named for an outcome the wearer
    /// is trying to avoid. Twin of the Kotlin editor in `CoachChat`.
    private var keyRepairPanel: some View {
        StrandCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste the corrected key. Your conversation is kept.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Paste your \(coach.provider.displayName) API key", text: $keyFix)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    .onSubmit(saveRepairedKey)
                    .accessibilityLabel("Corrected API key")
                HStack {
                    NoopButton("Update key", systemImage: "key.fill", kind: .primary, action: saveRepairedKey)
                        .disabled(keyFix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
            }
        }
    }

    /// Store the corrected key and drop it from view state. `setKey` clears the error and the rejection
    /// flag, which is what closes this panel.
    private func saveRepairedKey() {
        let trimmed = keyFix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setKey(trimmed)
        keyFix = ""
    }

    /// What the last generation did. Informational, not an error — it reports a successful fallback as
    /// readily as a failed one, because an answer that quietly came from a different model than the one
    /// named in the picker is its own kind of confusion. Tertiary styling so it reads as a footnote
    /// rather than competing with a real error banner above it.
    private func attemptTraceNote(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text(message)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Model attempt: \(message)")
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { prompt in
                    Button {
                        send(prompt)
                    } label: {
                        Text(prompt)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
                            .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    }
                    // Liquid tap response: the physical settle-inward every tappable liquid
                    // affordance gets, replacing the flat `.plain` press.
                    .buttonStyle(LiquidPressStyle())
                    .disabled(coach.sending)
                    .accessibilityLabel("Suggested prompt: \(prompt)")
                }
            }
            .padding(.vertical, 1)
        }
    }

    /// K7: True when follow-up chips should show instead of the initial contextual chips —
    /// i.e. the transcript is non-empty, the last message is from the assistant, and a reply
    /// is not currently in flight.
    private var showFollowUpChips: Bool {
        guard let last = coach.messages.last, !coach.sending else { return false }
        return last.role == .assistant
    }

    /// K7: Follow-up suggestion chips shown after each assistant reply, so the user can dig
    /// deeper without typing. Uses the static `AICoachEngine.followUpSuggestions` list.
    private var followUpChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AICoachEngine.followUpSuggestions, id: \.self) { prompt in
                    Button {
                        send(prompt)
                    } label: {
                        Text(prompt)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
                            .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(LiquidPressStyle())
                    .disabled(coach.sending)
                    .accessibilityLabel("Follow-up prompt: \(prompt)")
                }
            }
            .padding(.vertical, 1)
        }
    }

    /// K12: A subtle token estimate shown below the composer when the draft is non-empty.
    /// Uses the ~4 chars/token heuristic — an estimate only, not an exact tokenizer count.
    private func tokenEstimateBar(_ tokens: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "speedometer")
                .font(.system(size: 10))
                .foregroundStyle(StrandPalette.textTertiary)
            Text("~\(tokens) tokens")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textTertiary)
            if tokens > 8000 {
                Text("· may exceed small context windows")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.top, 2)
    }

    /// The input bar, a frosted overlay surface holding the field + Send, so the composer reads as a
    /// distinct docked surface above the canvas rather than two floating controls.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask Coach about your data…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(composerFocused ? StrandPalette.focusRing : StrandPalette.hairline, lineWidth: 1))
                .onSubmit { send(draft) }
                .accessibilityLabel("Question")

            // K4: on-device voice input (iOS only). macOS compiles this section out entirely.
            #if os(iOS)
            micButton
            #endif

            // Docked icon-only send affordance: a crisp accent-filled square sized to the
            // composer row (not the full 48pt control height), so it routes through the same
            // token fill/label colours as the button system without overpowering the field.
            Button {
                send(draft)
            } label: {
                Group {
                    if coach.sending {
                        ProgressView().controlSize(.small).tint(StrandPalette.goldDeepText)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .frame(width: 44, height: 38)
                .foregroundStyle(StrandPalette.goldDeepText)
                .background(StrandPalette.accent,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(coach.sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(8)
        .background(NoopPanelSurface(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    // MARK: - K4: Voice input (iOS only)

    #if os(iOS)
    /// Mic button: starts/stops on-device speech recognition. Disabled when the locale lacks
    /// on-device support or permission is denied; tapping when permission is not yet determined
    /// triggers the system prompt.
    private var micButton: some View {
        Button {
            toggleVoice()
        } label: {
            Group {
                if voiceInput.isRecording {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(StrandPalette.statusCritical)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canUseVoice ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                }
            }
            .frame(width: 36, height: 38)
            .background(StrandPalette.surfaceInset,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!micButtonEnabled)
        .help(voiceInput.statusMessage ?? "Ask out loud")
        .accessibilityLabel(voiceInput.isRecording ? "Stop voice input" : "Voice input")
        .accessibilityHint(voiceInput.statusMessage ?? "Transcribes your question on-device")
        .task {
            // Pre-check on appear so the button reflects the right state without a tap.
            if voiceInput.authorization == .notDetermined {
                voiceInput.requestAuthorization { _ in }
            }
        }
    }

    /// Whether the mic button is tappable: not while sending, and only if voice is either
    /// already usable or permission hasn't been asked yet (first tap triggers the prompt).
    private var canUseVoice: Bool { voiceInput.canUseVoice }
    private var micButtonEnabled: Bool {
        !coach.sending && (canUseVoice || voiceInput.authorization == .notDetermined)
    }

    private func toggleVoice() {
        if voiceInput.isRecording {
            voiceInput.stopTranscribing { finalText in
                let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    // Append to the draft (not replace) so a user can speak into existing text.
                    draft = draft.isEmpty ? trimmed : "\(draft) \(trimmed)"
                }
            }
        } else {
            // First tap with undetermined permission triggers the system prompt; if granted,
            // start transcribing immediately on the next tap. If already authorized, start now.
            if voiceInput.authorization == .notDetermined {
                voiceInput.requestAuthorization { state in
                    if state == .authorized {
                        voiceInput.startTranscribing { partial in
                            draft = partial
                        }
                    }
                }
            } else {
                voiceInput.startTranscribing { partial in
                    draft = partial
                }
            }
        }
    }
    #endif

    private var privacyFootnoteText: String {
        switch coach.provider {
        case .custom:
            return String(localized: "Coach talks only to the server URL you set. Point it at a local model (Ollama, LM Studio, llama.cpp) to keep everything on your own machine. Nothing is sent until you ask.")
        case .appleOnDevice:
            return String(localized: "Coach is running on \(Platform.deviceNounPhrase) with Apple Intelligence. Nothing leaves it — not your data, not your questions.")
        default:
            return String(localized: "This is the only feature that leaves \(Platform.deviceNounPhrase). It sends a summary of your metrics to \(coach.provider.displayName) using your own key. Nothing is sent until you ask.")
        }
    }

    private var privacyFootnote: some View {
        Label {
            Text(privacyFootnoteText)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

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

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coach.sending else { return }
        draft = ""
        composerFocused = false
        Task { await coach.send(trimmed) }
    }

    /// K14: Trigger a subtle haptic when the Coach reply arrives. On iOS, a light impact feedback.
    /// macOS doesn't have an equivalent simple API, so it's a no-op there.
    private func triggerReplyHaptic() {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }

    /// K8: Save a coach reply to the journal as a note, so it appears alongside other journal
    /// entries in Insights and can be reviewed later. Uses the existing journal API with a
    /// fixed question ("Coach advice") and the reply text in the notes field.
    private func saveAdvice(_ text: String) {
        let day = Repository.localDayKey(Date())
        Task {
            await repo.saveJournalAnswer(
                day: day,
                question: "Coach advice",
                answeredYes: true,
                notes: text
            )
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(StrandMotion.fade) {
            if coach.sending {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let last = coach.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}
