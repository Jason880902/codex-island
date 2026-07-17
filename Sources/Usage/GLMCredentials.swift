import Foundation

/// GLM (Zhipu) credential acquisition for the coding-plan quota endpoint.
/// GLM has no local CLI credential store for us to read — the user pastes an
/// API key into Settings, persisted by `ProviderKeyStore`. The usage fetcher
/// hands this module the probe closure (the single
/// `/api/monitor/usage/quota/limit` HTTP call) and `GLMCredentials` maps the
/// outcome to a resolution.
///
/// Unlike Kimi/Claude there is no token rotation or revocation lifecycle to
/// respect: the key is static until the user replaces it, so this module is
/// a thin sentinel mapper. An empty key resolves to the "not configured"
/// sentinel WITHOUT network traffic — GLM is opt-in, most users never set
/// it up, and the pill must read as a calm empty state, not an error loop.
enum GLMCredentials {
    /// Emitted as `WindowUsage.error` when no GLM API key has been entered in
    /// Settings. Filling the key triggers a refresh (see `ProviderKeyStore`)
    /// that clears this on the next probe.
    static let notConfiguredMessage = "not configured — add GLM key in Settings"

    /// Outcome of a single usage-endpoint probe against the configured key.
    /// The fetcher owns the HTTP + parsing and reports back through this;
    /// `GLMCredentials` interprets it to decide the resolution.
    enum ProbeOutcome {
        case success(AppUsage)
        case rateLimited
        case unauthorized
        case otherError(String)
    }

    /// Resolution of the credential flow once probed against the usage
    /// endpoint.
    enum Resolution {
        /// The key was accepted by the probe; carries the parsed usage.
        case usage(AppUsage)
        /// No usage could be produced; carries the exact UI-facing error
        /// message the fetcher renders as the error caption.
        case failed(String)
    }

    // MARK: - Resolution

    /// One credential source: the Settings-entered API key + base URL. The
    /// flow:
    ///   1. Empty key → "not configured" sentinel, no network traffic.
    ///   2. Probe says 401/403 → the key is wrong or revoked; point the user
    ///      back at Settings.
    ///   3. 429 → account-level limit. Re-probing only feeds a tripped
    ///      limiter, so surface "rate limited" and let the next poll retry
    ///      (GLM has no cooldown wiring in UsageStore — it polls through,
    ///      same as codex).
    static func resolveUsage(probe: (_ apiKey: String, _ baseURL: String) async -> ProbeOutcome) async -> Resolution {
        // Single hop to the main-actor key store: read + normalize the
        // Settings-entered pair. Pasted keys often carry a trailing
        // newline/space from the copy — trim before the emptiness check.
        let (apiKey, baseURL) = await MainActor.run { () -> (String, String) in
            let store = ProviderKeyStore.shared
            let key = store.glmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            var base = store.glmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            // A blanked-out base URL field would produce a nonsense request
            // URL; fall back to the default host rather than erroring out.
            if base.isEmpty { base = ProviderKeyStore.defaultGLMBaseURL }
            return (key, base)
        }
        guard !apiKey.isEmpty else {
            return .failed(notConfiguredMessage)
        }
        switch await probe(apiKey, baseURL) {
        case .success(let u):       return .usage(u)
        // Account-level limit: re-probing only feeds a tripped limiter.
        case .rateLimited:          return .failed("rate limited")
        case .unauthorized:         return .failed("invalid GLM key — check Settings")
        case .otherError(let e):    return .failed(e)
        }
    }
}
