import Foundation

/// Deep module owning Kimi Code credential acquisition: the credentials-file
/// read plus the in-app re-auth helpers. The usage fetcher hands it a probe
/// closure (the single `/coding/v1/usages` HTTP call) and `KimiCredentials`
/// drives token selection, deciding when to surface re-auth.
///
/// STRICTLY READ-ONLY against the token family: this module never calls the
/// refresh endpoint and never writes the credentials file. Kimi Code rotates
/// the access token on a short leash (`expires_in` ≈ 15 minutes) and rewrites
/// `credentials/kimi-code.json` itself, so a second refresher racing the CLI
/// would invalidate the user's CLI login. If the access token has expired we
/// simply report it — the CLI refreshes on its next run, and the re-auth
/// button's `kimi login` spawn refreshes silently when the refresh_token is
/// still valid.
enum KimiCredentials {
    /// Emitted as `WindowUsage.error` when the server rejects a token that
    /// looked valid locally (401) — the session was revoked or rotated
    /// beyond repair and only a fresh `kimi login` recovers. The UI layer
    /// matches on this exact string to swap the error caption for an in-app
    /// re-auth prompt.
    static let reauthRequiredMessage = "re-login: kimi login"

    /// Emitted as `WindowUsage.error` when the usage endpoint rate-limits us
    /// (HTTP 429). `UsageStore` matches on this exact string to arm the
    /// post-429 fetch cooldown.
    static let rateLimitedMessage = "rate limited"

    /// Emitted as `WindowUsage.error` when the file-stored access token has
    /// expired. We never refresh it ourselves (see the type doc); Kimi Code
    /// refreshes and writes back the next time it runs.
    static let tokenExpiredMessage = "token expired — run kimi"

    /// True when a probe error is one the in-app re-auth flow can act on: a
    /// terminal auth failure — an expired access token or a token the server
    /// flat-out rejects. Distinct from a transient 429/network error, which
    /// self-heals and must NOT trigger the re-auth prompt. Views key the
    /// "Re-authenticate" button and its caption on this.
    static func isReauthActionable(_ error: String?) -> Bool {
        error == tokenExpiredMessage || error == reauthRequiredMessage
    }

    /// True when BOTH windows carry a reauth-actionable error — the token
    /// itself is unusable, not one window transiently failing. The usage
    /// panel swaps its chart tiles for the re-auth prompt on this.
    static func isTerminalAuthFailure(_ usage: AppUsage) -> Bool {
        isReauthActionable(usage.fiveHour.error) && isReauthActionable(usage.weekly.error)
    }

    /// True when BOTH windows carry the server-side revocation sentinel
    /// (401): the session is dead and only a fresh `kimi login` recovers.
    /// `UsageStore`'s "don't clobber good values" retention makes an
    /// exception ONLY for this — a revoked token never comes back, so
    /// keeping stale numbers would mislead. Local expiry is deliberately
    /// excluded: the CLI rotates the credentials file on its own schedule
    /// (often minutes after `expires_at`, e.g. while a session sits idle),
    /// so the retained value self-heals on a later poll. Blanking the peek
    /// pill to "—%" through every rotation gap was the visible bug.
    static func isServerRevocation(_ usage: AppUsage) -> Bool {
        usage.fiveHour.error == reauthRequiredMessage
            && usage.weekly.error == reauthRequiredMessage
    }

    /// Outcome of a single usage-endpoint probe against one token. The fetcher
    /// owns the HTTP + parsing and reports back through this; `KimiCredentials`
    /// interprets it to decide the resolution.
    enum ProbeOutcome {
        case success(AppUsage)
        case rateLimited
        case unauthorized
        case otherError(String)
    }

    /// Resolution of the credential flow once probed against the usage
    /// endpoint.
    enum Resolution {
        /// A token was accepted by the probe; carries the parsed usage.
        case usage(AppUsage)
        /// No usage could be produced; carries the exact UI-facing error
        /// message the fetcher renders as the error caption.
        case failed(String)
    }

    // MARK: - Resolution

    /// One token source: Kimi Code's credentials file. The flow:
    ///   1. No file / no usable token → "auth required" (Codex-only user,
    ///      or never logged in).
    ///   2. `expires_at` in the past → report "token expired" without
    ///      probing; Kimi Code refreshes the file on its own schedule and
    ///      a locally-expired token is dead server-side anyway.
    ///   3. Probe says 401 → the session was revoked despite a fresh-looking
    ///      file; the only remediation is a fresh `kimi login`.
    static func resolveUsage(probe: (_ token: String) async -> ProbeOutcome) async -> Resolution {
        guard let creds = readKimiCreds() else {
            return .failed("auth required — run kimi")
        }
        if creds.expiresAt <= Date() {
            return .failed(tokenExpiredMessage)
        }
        switch await probe(creds.accessToken) {
        case .success(let u):       return .usage(u)
        // Account-level limit: re-probing only feeds a tripped limiter.
        case .rateLimited:          return .failed(rateLimitedMessage)
        case .unauthorized:         return .failed(reauthRequiredMessage)
        case .otherError(let e):    return .failed(e)
        }
    }

    // MARK: - Credentials file

    /// One decoded credentials file. Internal (not private) so
    /// KimiCredentialsTests can assert the decoded fields.
    struct KimiCreds {
        let accessToken: String
        let expiresAt: Date
    }

    /// Kimi Code's configuration root. `KIMI_CODE_HOME` relocates
    /// `~/.kimi-code` — rarely set for a LaunchServices-spawned GUI app, but
    /// honored to match the CLI's resolution (and to let tests point the
    /// reader at a fixture).
    static func kimiHome() -> String {
        let env = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"] ?? ""
        return env.isEmpty ? "\(NSHomeDirectory())/.kimi-code" : env
    }

    /// Internal (not private) so KimiCredentialsTests can point it at a
    /// fixture via KIMI_CODE_HOME.
    static func kimiCredentialsFilePath() -> String {
        "\(kimiHome())/credentials/kimi-code.json"
    }

    /// API base URL for the usage endpoint. `KIMI_CODE_BASE_URL` overrides
    /// the default, matching the CLI's env contract.
    static var apiBaseURL: String {
        let env = ProcessInfo.processInfo.environment["KIMI_CODE_BASE_URL"] ?? ""
        return env.isEmpty ? "https://api.kimi.com" : env
    }

    /// Reads Kimi Code's login from the credentials file, or nil if there
    /// isn't a usable one. No caching layer: a file read is cheap and never
    /// trips a keychain ACL prompt, and the CLI rewrites the file every
    /// ~15 minutes as it rotates the token, so a cached copy would go stale
    /// within a single poll cycle anyway.
    static func readKimiCreds() -> KimiCreds? {
        guard let data = FileManager.default.contents(atPath: kimiCredentialsFilePath()),
              let blob = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = blob["access_token"] as? String, !access.isEmpty,
              let expiresAt = (blob["expires_at"] as? NSNumber)?.doubleValue
        else { return nil }
        return KimiCreds(
            accessToken: access,
            expiresAt: Date(timeIntervalSince1970: expiresAt)
        )
    }

    // MARK: - In-app re-auth

    /// True only when the in-app "Re-authenticate" button can actually do
    /// something useful: a credentials file exists (otherwise they're a
    /// Codex-only user, no Kimi flow to re-auth) and the `kimi` binary is
    /// discoverable at a known install path. We deliberately do not shell
    /// out to `which`; LaunchServices gives the app a stripped PATH
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), so a `which` call would miss every
    /// Homebrew/manual install and the button would silently never appear
    /// for most users.
    static func canPromptReauth() -> Bool {
        guard FileManager.default.fileExists(atPath: kimiCredentialsFilePath()) else { return false }
        return locateKimiBinary() != nil
    }

    /// Detached spawn of `kimi login`. While the refresh_token is valid the
    /// CLI refreshes the credentials file non-interactively and exits — no
    /// browser, no prompt. Only a fully dead session falls into the
    /// device-code flow, whose code our detached spawn can't display; that
    /// process simply lingers until it times out while the user logs in
    /// manually. Returns false only if `kimi` couldn't be located — the
    /// spawn itself is fire-and-forget; the caller polls for the file update.
    @discardableResult
    static func spawnReauth() -> Bool {
        guard let path = locateKimiBinary() else { return false }
        let task = Process()
        task.launchPath = path
        task.arguments = ["login"]
        // Detach stdio: we don't want the CLI's progress output to leak into
        // our app's stderr, and we explicitly do not want it inheriting our
        // controlling terminal (we don't have one — we're a GUI app).
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        task.standardInput = Pipe()
        do {
            try task.run()
            return true
        } catch {
            NSLog("CodexIsland: failed to spawn kimi login: %@", error.localizedDescription)
            return false
        }
    }

    /// Common install locations for the Kimi Code CLI, in priority order.
    /// The CLI's own installer drops the binary under its config root; the
    /// rest are the usual manual-install suspects. We don't probe nvm-style
    /// versioned paths; users with exotic installs will fall through to the
    /// manual `kimi login` path.
    private static func locateKimiBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(kimiHome())/bin/kimi",
            "/opt/homebrew/bin/kimi",
            "/usr/local/bin/kimi",
            "\(home)/.local/bin/kimi",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
