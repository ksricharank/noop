package com.noop.ai

import android.content.Context
import android.content.SharedPreferences
import com.noop.data.SecurePrefs

/**
 * Secure, at-rest-encrypted storage for the user's AI Coach API key.
 *
 * Backed by Jetpack Security `EncryptedSharedPreferences` — values are encrypted with a
 * key held in the Android Keystore (hardware-backed where available). The plaintext API
 * key is never written to disk in the clear. This is the Android counterpart to storing
 * the key in the macOS Keychain.
 *
 * The selected provider/model are NOT secret and are stored as plain preferences here too
 * for convenience, but the key itself is the only sensitive value.
 */
object AiKeyStore {

    private const val FILE_NAME = "noop_ai_secure_prefs"

    /**
     * The pre-multi-slot key entry and the marker naming its owner. Read once by
     * [migrateLegacyKeyIfNeeded], then removed; never written again.
     */
    private const val KEY_API_LEGACY = "api_key"
    private const val KEY_KEY_OWNER = "key_provider"

    /** Set once the legacy single-slot key has been dealt with, so migration runs at most once. */
    private const val KEY_MIGRATED = "key_migrated_per_provider"

    private const val KEY_PROVIDER = "provider"
    private const val KEY_CONSENT = "data_consent"
    private const val KEY_CUSTOM_URL = "custom_base_url"
    private const val KEY_CUSTOM_AUTH_HEADER = "custom_auth_header"
    private const val KEY_CUSTOM_CONNECTED = "custom_connected"

    /** Per-provider model preference key, so each provider remembers its own last model. */
    private fun modelKey(provider: AiProvider) = "model_${provider.name}"

    /**
     * Per-provider API-key entry, so every provider keeps its own key instead of the four of them
     * sharing one slot. Mirrors [modelKey], which has always been per-provider — the key was the odd
     * one out, and that asymmetry is exactly what made switching provider destructive.
     */
    private fun apiKeyKey(provider: AiProvider) = "api_key_${provider.name}"

    /**
     * The encrypted preferences file. The master key uses the AES256_GCM key scheme and lives in the
     * Android Keystore.
     *
     * Delegated to [SecurePrefs] so both credential stores open their file the same way — and so the
     * Keystore and Tink setup happens once per process rather than on every read and write, which is
     * what it used to do.
     */
    private fun prefs(ctx: Context): SharedPreferences = SecurePrefs.of(ctx, FILE_NAME)

    /**
     * Move a pre-multi-slot key into its owner's slot, once.
     *
     * The legacy entry carried no provider of its own — the owner lived in a separate marker. Where
     * that marker names a provider, the key belongs in that provider's slot. Where it is ABSENT (a key
     * saved before owner-tracking existed) the old guarded read treated it as belonging to whichever
     * cloud provider was selected, so it is filed under the currently-selected provider — unless that
     * is CUSTOM, which the old code explicitly refused to auto-send an unowned key to, and which is
     * refused here for the same reason.
     *
     * Idempotent and non-destructive: never overwrites a slot that already holds a key, and removes the
     * legacy entry only after the new one is written, so an interrupted migration leaves the key where
     * it was rather than losing it between two slots. Byte-parity with Swift `migrateLegacyKeyIfNeeded`.
     */
    fun migrateLegacyKeyIfNeeded(ctx: Context) {
        val p = prefs(ctx)
        if (p.getBoolean(KEY_MIGRATED, false)) return

        val legacy = p.getString(KEY_API_LEGACY, null)?.takeIf { it.isNotBlank() }
        if (legacy == null) {
            // Nothing to move (fresh install, or an earlier launch already migrated).
            p.edit().putBoolean(KEY_MIGRATED, true).remove(KEY_KEY_OWNER).apply()
            return
        }

        val markedOwner = p.getString(KEY_KEY_OWNER, null)
            ?.let { name -> AiProvider.entries.firstOrNull { it.name == name } }
        // An unowned legacy key is never filed under Custom — same refusal the old guarded read made.
        val owner = markedOwner ?: readProvider(ctx).takeIf { it != AiProvider.CUSTOM }
        // Leave the legacy entry alone and retry next launch, when a cloud provider may be selected.
        // Deleting it here would destroy a key we simply cannot place yet.
            ?: return

        val editor = p.edit()
        // Never clobber a slot the user has already populated.
        if (p.getString(apiKeyKey(owner), null).isNullOrBlank()) {
            editor.putString(apiKeyKey(owner), legacy)
        }
        editor.remove(KEY_API_LEGACY)
            .remove(KEY_KEY_OWNER)
            .putBoolean(KEY_MIGRATED, true)
            .apply()
    }

    /**
     * Persist the API [key] for [owner] (encrypted at rest). Blank keys clear THAT provider's slot
     * only — every other provider's key is untouched, which is the whole point of the per-provider
     * split. [owner] defaults to the currently-persisted provider, which the UI selects (and persists
     * via [saveProvider]) before the user pastes a key for it.
     */
    fun save(ctx: Context, key: String, owner: AiProvider = readProvider(ctx)) {
        val trimmed = key.trim()
        if (trimmed.isEmpty()) {
            clear(ctx, owner)
            return
        }
        prefs(ctx).edit().putString(apiKeyKey(owner), trimmed).apply()
    }

    /**
     * Read the key stored for [provider], or null if that provider has none.
     *
     * The cross-provider leak the old owner marker guarded against is now structural: a key lives under
     * its own provider's entry and there is no read that returns another provider's key, so one
     * provider's secret can never reach another's endpoint (above all an arbitrary Custom URL).
     */
    fun read(ctx: Context, provider: AiProvider): String? =
        prefs(ctx).getString(apiKeyKey(provider), null)?.takeIf { it.isNotBlank() }

    /** Remove [provider]'s key, leaving every other provider's key (and all model prefs) intact. */
    fun clear(ctx: Context, provider: AiProvider = readProvider(ctx)) {
        prefs(ctx).edit().remove(apiKeyKey(provider)).apply()
    }

    /** Remove EVERY provider's key, plus any legacy entry. The "leave nothing behind" action. */
    fun clearAll(ctx: Context) {
        val editor = prefs(ctx).edit()
        AiProvider.entries.forEach { editor.remove(apiKeyKey(it)) }
        editor.remove(KEY_API_LEGACY).remove(KEY_KEY_OWNER).apply()
    }

    /**
     * True when a non-blank key is stored for [provider] — the gate the UI uses to enable sending.
     * Per-provider by construction, so switching provider changes the answer without any key moving.
     */
    fun hasKey(ctx: Context, provider: AiProvider = readProvider(ctx)): Boolean =
        read(ctx, provider) != null

    // --- Non-secret selection helpers (provider + model). Convenience only. ---

    /** Persist the chosen provider (by enum name). */
    fun saveProvider(ctx: Context, provider: AiProvider) {
        prefs(ctx).edit().putString(KEY_PROVIDER, provider.name).apply()
    }

    /** Read the chosen provider, defaulting to OpenAI. */
    fun readProvider(ctx: Context): AiProvider =
        AiProvider.fromName(prefs(ctx).getString(KEY_PROVIDER, null))

    /**
     * Persist the chosen model id for [provider]. Any non-blank id is accepted (curated,
     * live-fetched, or a custom id the user typed) — the model list is no longer a fixed,
     * shipped set. A blank id is ignored.
     */
    fun saveModel(ctx: Context, provider: AiProvider, model: String) {
        val trimmed = model.trim()
        if (trimmed.isEmpty()) return
        prefs(ctx).edit().putString(modelKey(provider), trimmed).apply()
    }

    /**
     * Read the chosen model id for [provider], defaulting to that provider's default model
     * when nothing valid is stored. A previously-saved custom or live model id is preserved
     * even if it isn't in the curated [AiProvider.models] list.
     */
    fun readModel(ctx: Context, provider: AiProvider): String =
        prefs(ctx).getString(modelKey(provider), null)?.takeIf { it.isNotBlank() }
            ?: provider.defaultModel

    /** Persist the data-access consent flag. */
    fun saveConsent(ctx: Context, consent: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_CONSENT, consent).apply()
    }

    /** Read the data-access consent flag (default false — privacy-safe; no metrics sent until on). */
    fun readConsent(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_CONSENT, false)

    // --- Custom (OpenAI-compatible / local LLM) provider settings ---

    /** Persist the Custom provider's base URL (e.g. http://localhost:11434/v1). */
    fun saveCustomBaseUrl(ctx: Context, url: String) {
        prefs(ctx).edit().putString(KEY_CUSTOM_URL, url.trim()).apply()
    }

    /** Read the Custom provider's base URL, or empty string if unset. */
    fun readCustomBaseUrl(ctx: Context): String =
        prefs(ctx).getString(KEY_CUSTOM_URL, null)?.trim().orEmpty()

    /** Persist which header the Custom provider should use when an API key is present. */
    fun saveCustomAuthHeader(ctx: Context, header: CustomAiAuthHeader) {
        prefs(ctx).edit().putString(KEY_CUSTOM_AUTH_HEADER, header.name).apply()
    }

    /** Read the Custom provider auth header. Defaults to Bearer for existing local setups. */
    fun readCustomAuthHeader(ctx: Context): CustomAiAuthHeader =
        CustomAiAuthHeader.fromName(prefs(ctx).getString(KEY_CUSTOM_AUTH_HEADER, null))

    /**
     * Persist whether the user has committed the Custom provider (entered a URL and tapped
     * Connect). Lets the keyless local path reach the chat without a stored API key.
     */
    fun saveCustomConnected(ctx: Context, connected: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_CUSTOM_CONNECTED, connected).apply()
    }

    /** Read the Custom-provider committed flag (default false). */
    fun readCustomConnected(ctx: Context): Boolean =
        prefs(ctx).getBoolean(KEY_CUSTOM_CONNECTED, false)
}
