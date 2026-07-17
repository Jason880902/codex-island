import Foundation

/// User-entered credentials for the providers that have no local credential
/// store to read: GLM (Zhipu) takes an API key + base URL, Grok takes a
/// pasted grok.com session cookie. Written by the Settings "API Keys"
/// section; read by `GLMCredentials` / `GrokCredentials` on every poll.
///
/// Plain UserDefaults, not the Keychain: single-user desktop app, and the
/// values are low-blast-radius (a quota-monitoring key and a hand-pasted
/// cookie) — the same tradeoff the rest of this app's preferences already
/// make, and the same one cc-switch makes for the same keys. Upgrade path
/// is a Keychain item if that ever changes.
///
/// Every mutation re-triggers `UsageStore.refresh()` so a key pasted in
/// Settings takes effect on the spot instead of at the next 5–30-minute
/// poll. That's cheap here: `refresh()` is guarded against re-entry while
/// a fetch is in flight, and still-unconfigured providers short-circuit to
/// their sentinel without network traffic.
///
/// Dependency direction: the credentials modules read THIS store; UsageStore
/// never references it (the refresh trigger below is the one exception, and
/// it's a plain fire-and-forget call, not state coupling).
@MainActor
final class ProviderKeyStore: ObservableObject {
    static let shared = ProviderKeyStore()

    private static let glmAPIKeyKey = "MacIsland.glmAPIKey"
    private static let glmBaseURLKey = "MacIsland.glmBaseURL"
    private static let grokCookieKey = "MacIsland.grokCookie"

    /// Default GLM API base — the bigmodel.cn coding-plan host. Users on the
    /// international Z.ai host override it in Settings (https://api.z.ai).
    /// Also the fallback when the base-URL field is blanked out (see
    /// `GLMCredentials.resolveUsage`).
    static let defaultGLMBaseURL = "https://open.bigmodel.cn"

    /// GLM API key, pasted in Settings. Empty = not configured; the fetcher
    /// resolves to the not-configured sentinel without network traffic.
    @Published var glmAPIKey: String {
        didSet { Self.persist(glmAPIKey, key: Self.glmAPIKeyKey) }
    }

    /// GLM API base URL (no path). Defaults to `defaultGLMBaseURL`; editable
    /// for the api.z.ai host.
    @Published var glmBaseURL: String {
        didSet { Self.persist(glmBaseURL, key: Self.glmBaseURLKey) }
    }

    /// grok.com session cookie, pasted in Settings. Empty = not configured.
    /// Cookies expire; an expired one surfaces as the "cookie rejected"
    /// sentinel until a fresh one is pasted.
    @Published var grokCookie: String {
        didSet { Self.persist(grokCookie, key: Self.grokCookieKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.glmAPIKey = defaults.string(forKey: Self.glmAPIKeyKey) ?? ""
        self.glmBaseURL = defaults.string(forKey: Self.glmBaseURLKey) ?? Self.defaultGLMBaseURL
        self.grokCookie = defaults.string(forKey: Self.grokCookieKey) ?? ""
    }

    /// Persist one field, then kick a usage refresh so the new value takes
    /// effect immediately. Fire-and-forget: `UsageStore.refresh()` self-guards
    /// against overlapping fetches, so rapid edits (each keystroke in a
    /// Settings field) don't stack up network traffic.
    private static func persist(_ value: String, key: String) {
        UserDefaults.standard.set(value, forKey: key)
        Task { @MainActor in UsageStore.shared.refresh() }
    }
}
