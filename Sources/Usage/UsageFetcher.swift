import Foundation

enum UsageFetcher {
    // MARK: - Codex

    /// Codex usage lives at chatgpt.com/backend-api/wham/usage and accepts
    /// the access_token from ~/.codex/auth.json. The endpoint is reliable
    /// and rarely rate-limited, so this is the easy half of the integration.
    static func fetchCodex() async -> AppUsage {
        guard let token = readCodexAccessToken() else {
            return errorPair("no codex auth")
        }

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 401 means the access_token in ~/.codex/auth.json has expired.
            // The Codex CLI rotates this token on its own — there's nothing
            // we can do from here, so surface the exact remediation step.
            if status == 401 {
                return errorPair("auth expired — codex login")
            }
            if status != 200 {
                return errorPair("http \(status)")
            }

            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rl = obj["rate_limit"] as? [String: Any] else {
                return errorPair("parse error")
            }
            return AppUsage(
                fiveHour: parseCodexWindow(rl["primary_window"]),
                weekly: parseCodexWindow(rl["secondary_window"]),
                plan: obj["plan_type"] as? String
            )
        } catch {
            return errorPair(error.localizedDescription)
        }
    }

    /// Internal (not private) so the GLM/Grok fetchers in
    /// `UsageFetcherGLMGrok.swift` can build the same both-windows error.
    static func errorPair(_ message: String) -> AppUsage {
        AppUsage(
            fiveHour: WindowUsage(usedPercent: 0, resetAt: nil, error: message),
            weekly: WindowUsage(usedPercent: 0, resetAt: nil, error: message)
        )
    }

    private static func readCodexAccessToken() -> String? {
        let path = NSString("~/.codex/auth.json").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { return nil }
        return token
    }

    private static func parseCodexWindow(_ obj: Any?) -> WindowUsage {
        guard let d = obj as? [String: Any] else { return .unknown }
        let used = (d["used_percent"] as? Double) ?? 0
        let resetAt = (d["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return WindowUsage(usedPercent: used / 100, resetAt: resetAt, error: nil)
    }

    static func fetchCodexResetCredits() async -> CodexResetCredits? {
        guard let token = readCodexAccessToken() else { return nil }

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            let availableCount = (obj["available_count"] as? Int) ?? 0
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallbackFormatter = ISO8601DateFormatter()
            fallbackFormatter.formatOptions = [.withInternetDateTime]

            let rawCredits: [[String: Any]] = (obj["credits"] as? [[String: Any]]) ?? []
            let credits: [CodexResetCredit] = rawCredits.compactMap { item -> CodexResetCredit? in
                guard let id = item["id"] as? String,
                      let status = item["status"] as? String,
                      let expiresRaw = item["expires_at"] as? String,
                      let expiresAt = formatter.date(from: expiresRaw)
                        ?? fallbackFormatter.date(from: expiresRaw)
                else { return nil }

                return CodexResetCredit(
                    id: id,
                    status: status,
                    expiresAt: expiresAt,
                    title: item["title"] as? String ?? "",
                    description: item["description"] as? String ?? ""
                )
            }

            return CodexResetCredits(availableCount: availableCount, credits: credits)
        } catch {
            return nil
        }
    }

    // MARK: - Kimi

    /// Kimi Code ships a first-party usage endpoint for its subscription:
    /// `{base}/coding/v1/usages` with the access_token from
    /// `~/.kimi-code/credentials/kimi-code.json`. The endpoint is reliable
    /// and politely rate-limited, so this is the easy half of the
    /// integration.
    ///
    /// Token acquisition (credentials file, strictly read-only) lives behind
    /// `KimiCredentials`. We hand it the usage probe and render its
    /// resolution: a parsed `AppUsage`, or an error caption via `errorPair`.
    static func fetchKimi() async -> AppUsage {
        let resolution = await KimiCredentials.resolveUsage { token in
            await fetchKimiUsage(token: token)
        }
        switch resolution {
        case .usage(let u):    return u
        case .failed(let msg): return errorPair(msg)
        }
    }

    private static func fetchKimiUsage(token: String) async -> KimiCredentials.ProbeOutcome {
        var req = URLRequest(url: URL(string: "\(KimiCredentials.apiBaseURL)/coding/v1/usages")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .otherError("bad response")
            }
            if http.statusCode == 401 { return .unauthorized }
            if http.statusCode == 429 { return .rateLimited }
            guard http.statusCode == 200 else {
                return .otherError("HTTP \(http.statusCode)")
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .otherError("parse error")
            }
            return .success(parseKimiUsage(obj))
        } catch {
            return .otherError(error.localizedDescription)
        }
    }

    /// Pure parse of the `/coding/v1/usages` payload — internal (not
    /// private) so KimiUsageParsingTests can drive it with fixtures. Quota
    /// fields (`limit`/`used`/`remaining`) arrive as string numbers
    /// ("100"/"2"); `resetTime` is ISO8601 with fractional seconds.
    static func parseKimiUsage(_ obj: [String: Any]) -> AppUsage {
        let user = obj["user"] as? [String: Any]
        let membership = user?["membership"] as? [String: Any]
        let plan = (membership?["level"] as? String).map(prettyKimiPlan)

        // The top-level `usage` object is the weekly quota — Kimi Code
        // labels it "Weekly limit" in the CLI.
        let weekly = parseKimiWindow(obj["usage"])

        // The 5h window rides in `limits[]` as a 300-minute entry. It can
        // be absent (fresh account, quiet period) — fall back to .unknown
        // so the tile shows its passive state instead of a fake 0%.
        var fiveHour = WindowUsage.unknown
        for item in (obj["limits"] as? [[String: Any]]) ?? [] {
            guard let window = item["window"] as? [String: Any],
                  stringNumber(window["duration"]) == 300,
                  (window["timeUnit"] as? String) == "TIME_UNIT_MINUTE"
            else { continue }
            fiveHour = parseKimiWindow(item["detail"])
            break
        }

        return AppUsage(fiveHour: fiveHour, weekly: weekly, plan: plan)
    }

    private static func parseKimiWindow(_ obj: Any?) -> WindowUsage {
        guard let d = obj as? [String: Any] else { return .unknown }
        let limit = stringNumber(d["limit"]) ?? 0
        let used = stringNumber(d["used"]) ?? 0
        // Normalize to the 0...1 fraction WindowUsage expects; a zero or
        // missing limit reads as 0% rather than a divide-by-zero.
        let usedPercent = limit > 0 ? min(1, max(0, Double(used) / Double(limit))) : 0
        var resetAt: Date?
        if let s = d["resetTime"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetAt = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return WindowUsage(usedPercent: usedPercent, resetAt: resetAt, error: nil)
    }

    /// Prettify the membership level for display:
    /// "LEVEL_INTERMEDIATE" → "Intermediate".
    static func prettyKimiPlan(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("LEVEL_") { s = String(s.dropFirst("LEVEL_".count)) }
        let lowered = s.lowercased()
        return lowered.prefix(1).uppercased() + lowered.dropFirst()
    }

    /// Quota fields arrive as strings ("100") in the wire payload; tolerate
    /// numeric JSON too so a server-side type change doesn't blank the panel.
    /// Internal (not private) so the GLM/Grok parsers reuse it.
    static func stringNumber(_ v: Any?) -> Int? {
        if let s = v as? String { return Int(s) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    // MARK: - Claude

    /// Anthropic doesn't ship a usage endpoint for end users — Claude Code
    /// itself talks to api.anthropic.com/api/oauth/usage with a beta header
    /// and a User-Agent that identifies as the CLI. We replicate that.
    ///
    /// Token acquisition (env → keychain, strictly read-only) lives behind
    /// `ClaudeCredentials`. We hand it the usage probe and render its
    /// resolution: a parsed `AppUsage`, or an error caption (re-auth or last
    /// error) via `errorPair`.
    static func fetchClaude() async -> AppUsage {
        let resolution = await ClaudeCredentials.resolveUsage { token, plan in
            await fetchClaudeUsage(token: token, plan: plan)
        }
        switch resolution {
        case .usage(let u):              return u
        case .reauthRequired(let msg):   return errorPair(msg)
        case .failed(let msg):           return errorPair(msg)
        }
    }

    private static func fetchClaudeUsage(token: String, plan: String?) async -> ClaudeCredentials.ProbeOutcome {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Anthropic gates this endpoint on a CLI User-Agent. Without it the
        // request 401s even with a valid token.
        req.setValue("claude-code/2.1.121", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .otherError("bad response")
            }
            if http.statusCode == 401 { return .unauthorized }
            if http.statusCode == 403 { return .scopeInsufficient }
            if http.statusCode == 429 { return .rateLimited }
            guard http.statusCode == 200 else {
                return .otherError("HTTP \(http.statusCode)")
            }
            // The endpoint also returns 200 with a rate_limit_error body
            // sometimes; don't trust the status code alone.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let err = obj["error"] as? [String: Any],
                   let type = err["type"] as? String, type == "rate_limit_error" {
                    return .rateLimited
                }
                return .success(AppUsage(
                    fiveHour: parseClaudeWindow(obj["five_hour"]),
                    weekly: parseClaudeWindow(obj["seven_day"]),
                    plan: plan
                ))
            }
            return .otherError("parse error")
        } catch {
            return .otherError(error.localizedDescription)
        }
    }

    /// Pure parse of one `/api/oauth/usage` window (`five_hour`/`seven_day`)
    /// — internal (not private) so ClaudeUsageParsingTests can drive it with
    /// fixtures.
    static func parseClaudeWindow(_ obj: Any?) -> WindowUsage {
        guard let d = obj as? [String: Any] else { return .unknown }
        // Anthropic returns `utilization` as a percentage in [0, 100], not a
        // normalized [0, 1] fraction. An earlier `raw > 1 ? raw / 100 : raw`
        // heuristic broke the moment the 5h window reset: utilization values
        // in (0, 1] (e.g. 0.5% used → 0.5) were treated as already-normalized
        // and rendered as 50%–100%. Always divide by 100; clamp below.
        let raw = (d["utilization"] as? Double) ?? (d["used_percent"] as? Double) ?? 0
        let normalized = raw / 100.0
        // `resets_at` arrives either as unix seconds or as an ISO8601 string
        // (usually with fractional seconds); tolerate both.
        var resetAt: Date?
        if let r = d["resets_at"] as? Double {
            resetAt = Date(timeIntervalSince1970: r)
        } else if let s = d["resets_at"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetAt = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return WindowUsage(usedPercent: min(1, max(0, normalized)), resetAt: resetAt, error: nil)
    }
}
