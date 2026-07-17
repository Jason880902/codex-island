import Foundation

/// Embedded snapshot of per-million-token API prices in USD. Mirrors LiteLLM's
/// `model_prices_and_context_window.json` for the models we actually expect
/// in Kimi Code, Codex CLI, and Claude Code sessions, so totals cross-check
/// against `npx @ccusage/codex` to within rounding.
///
/// To refresh: bump `snapshotDate` and re-fetch the four rates per model
/// from `https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json`.
/// Unknown models silently price to $0 — same behavior as ccusage when
/// LiteLLM has no entry.
enum Pricing {
    static let snapshotDate = "2026-07-10"

    struct Rates {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheCreationPerMillion: Double
        let cacheReadPerMillion: Double
    }

    private static let table: [String: Rates] = [
        // Moonshot — Kimi Code is a flat subscription, so per-token rates
        // are all zero: the cost screen tracks token volume for Kimi, not
        // dollars. The entries exist so the models count as "known" and
        // don't trip the unpriced-model warning.
        "kimi-code/kimi-for-coding": Rates(
            inputPerMillion: 0, outputPerMillion: 0,
            cacheCreationPerMillion: 0, cacheReadPerMillion: 0
        ),
        "kimi-code/k3": Rates(
            inputPerMillion: 0, outputPerMillion: 0,
            cacheCreationPerMillion: 0, cacheReadPerMillion: 0
        ),

        // OpenAI — Codex CLI tags conversations with the chat-completion
        // model name. cache_creation has no separate rate (OpenAI bills
        // cache writes at the standard input rate).
        // Base reasoning models (newest first). Starting with 5.6, OpenAI
        // bills cache writes at 1.25x input (matching Anthropic) instead of
        // the standard input rate.
        "gpt-5.6": Rates(
            inputPerMillion: 5, outputPerMillion: 30,
            cacheCreationPerMillion: 6.25, cacheReadPerMillion: 0.50
        ),
        "gpt-5.6-sol": Rates(
            inputPerMillion: 5, outputPerMillion: 30,
            cacheCreationPerMillion: 6.25, cacheReadPerMillion: 0.50
        ),
        "gpt-5.6-terra": Rates(
            inputPerMillion: 2.5, outputPerMillion: 15,
            cacheCreationPerMillion: 3.125, cacheReadPerMillion: 0.25
        ),
        "gpt-5.6-luna": Rates(
            inputPerMillion: 1, outputPerMillion: 6,
            cacheCreationPerMillion: 1.25, cacheReadPerMillion: 0.10
        ),
        "gpt-5.5": Rates(
            inputPerMillion: 5, outputPerMillion: 30,
            cacheCreationPerMillion: 5, cacheReadPerMillion: 0.50
        ),
        "gpt-5.4": Rates(
            inputPerMillion: 2.5, outputPerMillion: 15,
            cacheCreationPerMillion: 2.5, cacheReadPerMillion: 0.25
        ),
        "gpt-5.2": Rates(
            inputPerMillion: 1.75, outputPerMillion: 14,
            cacheCreationPerMillion: 1.75, cacheReadPerMillion: 0.175
        ),
        "gpt-5.1": Rates(
            inputPerMillion: 1.25, outputPerMillion: 10,
            cacheCreationPerMillion: 1.25, cacheReadPerMillion: 0.125
        ),
        "gpt-5": Rates(
            inputPerMillion: 1.25, outputPerMillion: 10,
            cacheCreationPerMillion: 1.25, cacheReadPerMillion: 0.125
        ),
        // Codex variants (newest first).
        "gpt-5.3-codex": Rates(
            inputPerMillion: 1.75, outputPerMillion: 14,
            cacheCreationPerMillion: 1.75, cacheReadPerMillion: 0.175
        ),
        "gpt-5.2-codex": Rates(
            inputPerMillion: 1.75, outputPerMillion: 14,
            cacheCreationPerMillion: 1.75, cacheReadPerMillion: 0.175
        ),
        "gpt-5.1-codex": Rates(
            inputPerMillion: 1.25, outputPerMillion: 10,
            cacheCreationPerMillion: 1.25, cacheReadPerMillion: 0.125
        ),
        "gpt-5.1-codex-max": Rates(
            inputPerMillion: 1.25, outputPerMillion: 10,
            cacheCreationPerMillion: 1.25, cacheReadPerMillion: 0.125
        ),
        "gpt-5.1-codex-mini": Rates(
            inputPerMillion: 0.25, outputPerMillion: 2,
            cacheCreationPerMillion: 0.25, cacheReadPerMillion: 0.025
        ),
        "gpt-5-codex": Rates(
            inputPerMillion: 1.25, outputPerMillion: 10,
            cacheCreationPerMillion: 1.25, cacheReadPerMillion: 0.125
        ),
        // Mini / nano tiers.
        "gpt-5.4-mini": Rates(
            inputPerMillion: 0.75, outputPerMillion: 4.5,
            cacheCreationPerMillion: 0.75, cacheReadPerMillion: 0.075
        ),
        "gpt-5.4-nano": Rates(
            inputPerMillion: 0.2, outputPerMillion: 1.25,
            cacheCreationPerMillion: 0.2, cacheReadPerMillion: 0.02
        ),
        "gpt-5-mini": Rates(
            inputPerMillion: 0.25, outputPerMillion: 2,
            cacheCreationPerMillion: 0.25, cacheReadPerMillion: 0.025
        ),
        "gpt-5-nano": Rates(
            inputPerMillion: 0.05, outputPerMillion: 0.4,
            cacheCreationPerMillion: 0.05, cacheReadPerMillion: 0.005
        ),
        // Pro tier — LiteLLM lists no cache-read rate for gpt-5-pro /
        // gpt-5.2-pro (no prompt caching), so 0 is safe: they emit no
        // cache tokens.
        "gpt-5.5-pro": Rates(
            inputPerMillion: 30, outputPerMillion: 180,
            cacheCreationPerMillion: 30, cacheReadPerMillion: 3
        ),
        "gpt-5.4-pro": Rates(
            inputPerMillion: 30, outputPerMillion: 180,
            cacheCreationPerMillion: 30, cacheReadPerMillion: 3
        ),
        "gpt-5.2-pro": Rates(
            inputPerMillion: 21, outputPerMillion: 168,
            cacheCreationPerMillion: 21, cacheReadPerMillion: 0
        ),
        "gpt-5-pro": Rates(
            inputPerMillion: 15, outputPerMillion: 120,
            cacheCreationPerMillion: 15, cacheReadPerMillion: 0
        ),

        // Anthropic — Claude Code logs the bare API model id; the
        // canonical-name stripper removes its -YYYYMMDD date suffix, so
        // one entry per family version covers every pinned release.
        // Rates verified 2026-07-17 (not rolled into `snapshotDate`,
        // which tracks the last full-table LiteLLM refresh): Sonnet
        // family $3/M in + $15/M out, Opus 4.x $5/$25, Haiku 4.5 $1/$5.
        // Anthropic bills cache writes at 1.25x input, reads at 0.1x.
        "claude-sonnet-4-6": Rates(
            inputPerMillion: 3, outputPerMillion: 15,
            cacheCreationPerMillion: 3.75, cacheReadPerMillion: 0.30
        ),
        "claude-sonnet-4-5": Rates(
            inputPerMillion: 3, outputPerMillion: 15,
            cacheCreationPerMillion: 3.75, cacheReadPerMillion: 0.30
        ),
        "claude-sonnet-4": Rates(
            inputPerMillion: 3, outputPerMillion: 15,
            cacheCreationPerMillion: 3.75, cacheReadPerMillion: 0.30
        ),
        "claude-opus-4-7": Rates(
            inputPerMillion: 5, outputPerMillion: 25,
            cacheCreationPerMillion: 6.25, cacheReadPerMillion: 0.50
        ),
        "claude-opus-4-6": Rates(
            inputPerMillion: 5, outputPerMillion: 25,
            cacheCreationPerMillion: 6.25, cacheReadPerMillion: 0.50
        ),
        "claude-opus-4-5": Rates(
            inputPerMillion: 5, outputPerMillion: 25,
            cacheCreationPerMillion: 6.25, cacheReadPerMillion: 0.50
        ),
        "claude-opus-4-1": Rates(
            inputPerMillion: 5, outputPerMillion: 25,
            cacheCreationPerMillion: 6.25, cacheReadPerMillion: 0.50
        ),
        "claude-opus-4": Rates(
            inputPerMillion: 5, outputPerMillion: 25,
            cacheCreationPerMillion: 6.25, cacheReadPerMillion: 0.50
        ),
        "claude-haiku-4-5": Rates(
            inputPerMillion: 1, outputPerMillion: 5,
            cacheCreationPerMillion: 1.25, cacheReadPerMillion: 0.10
        ),

        // Zhipu — GLM's coding plan is a flat subscription, so per-token
        // rates are all zero (same treatment as Kimi): the cost screen
        // tracks token volume for GLM, not dollars. The entries exist so
        // the models count as "known" and don't trip the unpriced-model
        // warning. The lookup is exact-match (no prefix wildcards), so
        // each model id gets its own row.
        "glm-4.5": Rates(
            inputPerMillion: 0, outputPerMillion: 0,
            cacheCreationPerMillion: 0, cacheReadPerMillion: 0
        ),
        "glm-4.5-air": Rates(
            inputPerMillion: 0, outputPerMillion: 0,
            cacheCreationPerMillion: 0, cacheReadPerMillion: 0
        ),
        "glm-4.6": Rates(
            inputPerMillion: 0, outputPerMillion: 0,
            cacheCreationPerMillion: 0, cacheReadPerMillion: 0
        ),
        "glm-5": Rates(
            inputPerMillion: 0, outputPerMillion: 0,
            cacheCreationPerMillion: 0, cacheReadPerMillion: 0
        ),

        // xAI — Grok usage is tracked via the SuperGrok subscription's
        // rate-limit data, not per-token billing, so zero rates like the
        // other subscription providers (kimi/glm).
        "grok-3": Rates(
            inputPerMillion: 0, outputPerMillion: 0,
            cacheCreationPerMillion: 0, cacheReadPerMillion: 0
        ),
        "grok-4": Rates(
            inputPerMillion: 0, outputPerMillion: 0,
            cacheCreationPerMillion: 0, cacheReadPerMillion: 0
        ),
        "grok-code-fast-1": Rates(
            inputPerMillion: 0, outputPerMillion: 0,
            cacheCreationPerMillion: 0, cacheReadPerMillion: 0
        ),
    ]

    /// Compute the dollar cost of a single TokenEvent. Returns 0 for unknown
    /// models — ccusage parity. Synthetic placeholder models filtered upstream.
    ///
    /// Kimi models price to $0 by design (flat subscription, see the table);
    /// their rows still contribute token volume to every window total.
    static func cost(for event: TokenEvent) -> Double {
        let lookup = canonicalModel(event.model)
        guard let rates = table[lookup] else { return 0 }

        let input = Double(event.inputTokens) / 1_000_000 * rates.inputPerMillion
        let output = Double(event.outputTokens) / 1_000_000 * rates.outputPerMillion
        let cacheCreate = Double(event.cacheCreationTokens) / 1_000_000 * rates.cacheCreationPerMillion
        let cacheRead = Double(event.cacheReadTokens) / 1_000_000 * rates.cacheReadPerMillion

        return input + output + cacheCreate + cacheRead
    }

    /// Whether the embedded snapshot has a price entry for this model.
    /// Lets callers warn the user about unpriced spend without re-implementing
    /// the canonical-name stripping logic.
    static func isKnown(_ rawModel: String) -> Bool {
        table[canonicalModel(rawModel)] != nil
    }

    /// Calendar days between `snapshotDate` and now (UTC). Returns 0 if the
    /// snapshot string fails to parse, so a malformed constant is treated as
    /// fresh rather than triggering a permanent staleness warning.
    static var daysSinceSnapshot: Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let snapshot = formatter.date(from: snapshotDate) else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") { calendar.timeZone = utc }
        let components = calendar.dateComponents([.day], from: snapshot, to: Date())
        return max(0, components.day ?? 0)
    }

    /// Strip provider-style date suffixes (e.g. "gpt-5.4-20251001"
    /// → "gpt-5.4") so the snapshot table doesn't need an entry per
    /// pinned release. Exposed for downstream consumers (e.g. per-model
    /// breakdown views) so date-pinned variants group with their base model.
    static func canonicalModelName(_ raw: String) -> String {
        canonicalModel(raw)
    }

    private static func canonicalModel(_ raw: String) -> String {
        guard raw.count > 9 else { return raw }
        let suffixStart = raw.index(raw.endIndex, offsetBy: -9)
        let suffix = raw[suffixStart...]
        guard suffix.first == "-",
              suffix.dropFirst().allSatisfy({ $0.isNumber })
        else { return raw }
        return String(raw[..<suffixStart])
    }
}
