import Foundation

/// GLM (Zhipu) and Grok usage fetchers. Both are Settings-credential
/// providers: there is no local CLI store to read, so `GLMCredentials` /
/// `GrokCredentials` are thin sentinel mappers in front of `ProviderKeyStore`
/// and the probes below are the only network calls. Neither endpoint could
/// be tested against a live account at implementation time (no key, no
/// cookie) — the parsers are deliberately tolerant and fail VISIBLY, and the
/// fixtures in GLM/GrokUsageParsingTests pin the expected shapes.
extension UsageFetcher {
    // MARK: - GLM

    /// Zhipu exposes a quota endpoint for coding-plan subscribers at
    /// `{base}/api/monitor/usage/quota/limit`. Credential acquisition (the
    /// Settings-entered key) lives behind `GLMCredentials`; we hand it the
    /// usage probe and render its resolution: a parsed `AppUsage`, or an
    /// error caption via `errorPair`.
    static func fetchGLM() async -> AppUsage {
        let resolution = await GLMCredentials.resolveUsage { apiKey, baseURL in
            await fetchGLMUsage(apiKey: apiKey, baseURL: baseURL)
        }
        switch resolution {
        case .usage(let u):    return u
        case .failed(let msg): return errorPair(msg)
        }
    }

    private static func fetchGLMUsage(apiKey: String, baseURL: String) async -> GLMCredentials.ProbeOutcome {
        // The base URL is user-editable (bigmodel.cn vs api.z.ai); drop a
        // trailing slash so a pasted "…/" doesn't produce "//api".
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmedBase)/api/monitor/usage/quota/limit") else {
            return .otherError("bad base URL — check Settings")
        }
        var req = URLRequest(url: url)
        // The coding-plan endpoint takes the RAW API key in the Authorization
        // header — NO "Bearer" prefix, unlike every other provider here
        // (per cc-switch's GLM integration).
        req.setValue(apiKey, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .otherError("bad response")
            }
            if http.statusCode == 401 || http.statusCode == 403 { return .unauthorized }
            if http.statusCode == 429 { return .rateLimited }
            guard http.statusCode == 200 else {
                return .otherError("HTTP \(http.statusCode)")
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .otherError("parse error")
            }
            return .success(parseGLMUsage(obj))
        } catch {
            return .otherError(error.localizedDescription)
        }
    }

    /// Pure parse of the GLM quota payload — internal (not private) so
    /// GLMUsageParsingTests can drive it with fixtures.
    ///
    /// IMPORTANT: this shape comes from PUBLIC REPORTS of the coding-plan
    /// endpoint (cc-switch and similar integrations), not from a verified
    /// live account — no GLM key was available at implementation time.
    /// Expected:
    ///   {"code":200,"data":{"limits":[
    ///     {"type":"TIME_LIMIT","percentage":33,"resetTime":…},
    ///     {"type":"TOKENS_LIMIT","percentage":75,"resetTime":…}]}}
    /// If a live response differs, adjust HERE and in the fixtures — the
    /// parsing is deliberately tolerant so schema drift reads as .unknown
    /// windows instead of a crash or a fabricated 0%.
    static func parseGLMUsage(_ obj: [String: Any]) -> AppUsage {
        // A non-200 business code means the call itself errored server-side
        // (bad plan, suspended account) even at HTTP 200. Surface it as a
        // visible error rather than rendering silent 0% tiles. The code
        // arrives as Int or String depending on the report — tolerate both,
        // and tolerate it missing entirely.
        if let code = stringNumber(obj["code"]), code != 200 {
            let detail = (obj["message"] as? String) ?? (obj["msg"] as? String)
            return errorPair(detail.map { "GLM error \(code): \($0)" } ?? "GLM error \(code)")
        }

        // Missing `data` = nothing can be said about either window. Both go
        // .unknown (passive "—%" tiles), never a fabricated 0%.
        guard let data = obj["data"] as? [String: Any] else {
            return AppUsage(fiveHour: .unknown, weekly: .unknown)
        }

        // limits[] entries are keyed by `type`: TIME_LIMIT is the short
        // rolling window (mapped to our 5h tile), TOKENS_LIMIT the weekly
        // token budget. Either can be absent (quiet period, plan without
        // that meter) — the tile then shows its passive state.
        var fiveHour = WindowUsage.unknown
        var weekly = WindowUsage.unknown
        for item in (data["limits"] as? [[String: Any]]) ?? [] {
            guard let type = item["type"] as? String else { continue }
            switch type {
            case "TIME_LIMIT":   fiveHour = parseGLMLimit(item)
            case "TOKENS_LIMIT": weekly = parseGLMLimit(item)
            default:             continue
            }
        }
        return AppUsage(fiveHour: fiveHour, weekly: weekly, plan: nil)
    }

    /// One limits[] entry. `percentage` arrives 0–100 as Int, Double or
    /// String — tolerate all three so a server-side type change doesn't
    /// blank the panel. A missing/unparseable percentage reads as .unknown.
    private static func parseGLMLimit(_ d: [String: Any]) -> WindowUsage {
        guard let pct = doubleNumber(d["percentage"]) else { return .unknown }
        return WindowUsage(
            usedPercent: min(1, max(0, pct / 100)),
            resetAt: parseGLMResetTime(d),
            error: nil
        )
    }

    /// Reset timestamp of one limits[] entry. The key name is unverified, so
    /// try the reported variants in order; the value may be an ISO8601 string
    /// (fractional seconds ok) or unix seconds shipped as Double/Int/String.
    /// nil when nothing parses — a missing reset time never blocks the
    /// percentage reading.
    private static func parseGLMResetTime(_ d: [String: Any]) -> Date? {
        for key in ["resetTime", "nextResetTime", "reset_time", "resetAt"] {
            guard let raw = d[key] else { continue }
            if let s = raw as? String {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) {
                    return date
                }
                // A unix-seconds value shipped as a string.
                if let seconds = Double(s) {
                    return Date(timeIntervalSince1970: seconds)
                }
            } else if let seconds = doubleNumber(raw) {
                return Date(timeIntervalSince1970: seconds)
            }
        }
        return nil
    }

    // MARK: - Grok

    /// Grok has no official usage API; grok.com's web app calls
    /// /rest/rate-limits with the session cookie, so we replay that with the
    /// cookie the user pastes into Settings. Credential acquisition (the
    /// cookie + the not-configured sentinel) lives behind `GrokCredentials`;
    /// we hand it the usage probe and render its resolution.
    static func fetchGrok() async -> AppUsage {
        let resolution = await GrokCredentials.resolveUsage { cookie in
            await fetchGrokUsage(cookie: cookie)
        }
        switch resolution {
        case .usage(let u):    return u
        case .failed(let msg): return errorPair(msg)
        }
    }

    private static func fetchGrokUsage(cookie: String) async -> GrokCredentials.ProbeOutcome {
        var req = URLRequest(url: URL(string: "https://grok.com/rest/rate-limits")!)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // grok.com sits behind bot heuristics that happy-path browsers and
        // reject obvious scripts; a bare URLSession User-Agent is an easy
        // 403. Present as desktop Chrome.
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .otherError("bad response")
            }
            if http.statusCode == 401 || http.statusCode == 403 { return .unauthorized }
            if http.statusCode == 429 { return .rateLimited }
            guard http.statusCode == 200 else {
                return .otherError("HTTP \(http.statusCode)")
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .otherError("parse error")
            }
            return .success(parseGrokUsage(obj))
        } catch {
            return .otherError(error.localizedDescription)
        }
    }

    /// Pure parse of the grok.com /rest/rate-limits payload — internal (not
    /// private) so GrokUsageParsingTests can drive it with fixtures.
    ///
    /// IMPORTANT: the exact response shape is UNVERIFIED — no cookie was
    /// available at implementation time and third-party write-ups disagree.
    /// Instead of a rigid decode we search DEFENSIVELY: the top-level object
    /// and each of its immediate dictionary values are scanned for a
    /// remaining+total style pair, and the first pair found maps to the 5h
    /// window (weekly stays .unknown — grok exposes no weekly figure we know
    /// of). If nothing recognizable is found we return the "parse error"
    /// sentinel pair: a visible error beats silently rendering 0% forever
    /// while the real schema drifts. When a live capture is available,
    /// replace this with a rigid decode like `parseKimiUsage`.
    static func parseGrokUsage(_ obj: [String: Any]) -> AppUsage {
        if let window = findGrokRateLimitPair(in: obj) {
            return AppUsage(fiveHour: window, weekly: .unknown, plan: nil)
        }
        for value in obj.values {
            guard let nested = value as? [String: Any],
                  let window = findGrokRateLimitPair(in: nested) else { continue }
            return AppUsage(fiveHour: window, weekly: .unknown, plan: nil)
        }
        return errorPair("parse error — grok response changed")
    }

    /// remaining/total pair search within a single dict. Key spellings cover
    /// the variants seen in third-party write-ups; values are
    /// Int/Double/String tolerant. A non-positive total is rejected so we
    /// never divide by zero — the shape then falls through to the sentinel
    /// like any other unrecognizable one.
    private static func findGrokRateLimitPair(in d: [String: Any]) -> WindowUsage? {
        let remaining = ["remainingQueries", "remaining", "remainingTokens"]
            .compactMap { doubleNumber(d[$0]) }.first
        let total = ["totalQueries", "total", "limit", "quota"]
            .compactMap { doubleNumber(d[$0]) }.first
        guard let remaining, let total, total > 0 else { return nil }
        let usedPercent = min(1, max(0, 1 - remaining / total))
        return WindowUsage(usedPercent: usedPercent, resetAt: nil, error: nil)
    }

    /// Tolerant number: JSONSerialization yields NSNumber for numeric types,
    /// but quota fields occasionally ship as strings ("100"). Shared by the
    /// GLM and Grok parsers; the Int-typed sibling (`stringNumber`) lives on
    /// the base type.
    private static func doubleNumber(_ v: Any?) -> Double? {
        if let s = v as? String { return Double(s) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}
