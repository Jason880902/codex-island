import Foundation

/// Grok credential acquisition for the unofficial grok.com rate-limits
/// endpoint. xAI ships no public usage API, so the web app's own
/// `/rest/rate-limits` call is replayed with the session cookie the user
/// pastes into Settings (persisted by `ProviderKeyStore`). The usage fetcher
/// hands this module the probe closure and `GrokCredentials` maps the
/// outcome to a resolution.
///
/// Cookies expire on grok.com's schedule, not ours — an expired cookie comes
/// back as a 401/403 probe and resolves to the "cookie rejected" sentinel
/// until the user pastes a fresh one. No rotation is possible from here, so
/// this module is a thin sentinel mapper, same shape as `GLMCredentials`.
enum GrokCredentials {
    /// Emitted as `WindowUsage.error` when no grok.com cookie has been pasted
    /// in Settings. Pasting one triggers a refresh (see `ProviderKeyStore`)
    /// that clears this on the next probe.
    static let notConfiguredMessage = "not configured — add grok.com cookie in Settings"

    /// Outcome of a single usage-endpoint probe against the configured
    /// cookie. The fetcher owns the HTTP + parsing and reports back through
    /// this; `GrokCredentials` interprets it to decide the resolution.
    enum ProbeOutcome {
        case success(AppUsage)
        case rateLimited
        case unauthorized
        case otherError(String)
    }

    /// Resolution of the credential flow once probed against the usage
    /// endpoint.
    enum Resolution {
        /// The cookie was accepted by the probe; carries the parsed usage.
        case usage(AppUsage)
        /// No usage could be produced; carries the exact UI-facing error
        /// message the fetcher renders as the error caption.
        case failed(String)
    }

    // MARK: - Resolution

    /// One credential source: the Settings-entered cookie. The flow:
    ///   1. Empty cookie → "not configured" sentinel, no network traffic.
    ///   2. Probe says 401/403 → the cookie expired or was pasted wrong;
    ///      ask for a fresh one.
    ///   3. 429 → account-level limit; surface "rate limited" and let the
    ///      next poll retry (grok polls through, same as codex).
    static func resolveUsage(probe: (_ cookie: String) async -> ProbeOutcome) async -> Resolution {
        // Single hop to the main-actor key store. A pasted cookie often
        // carries a trailing newline from the copy — trim before the
        // emptiness check.
        let cookie = await MainActor.run {
            ProviderKeyStore.shared.grokCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !cookie.isEmpty else {
            return .failed(notConfiguredMessage)
        }
        switch await probe(cookie) {
        case .success(let u):       return .usage(u)
        // Account-level limit: re-probing only feeds a tripped limiter.
        case .rateLimited:          return .failed("rate limited")
        case .unauthorized:         return .failed("grok.com cookie rejected — paste a fresh one")
        case .otherError(let e):    return .failed(e)
        }
    }
}
