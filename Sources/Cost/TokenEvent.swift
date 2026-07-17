import Foundation

/// A single billable unit of token consumption parsed from a local session log.
/// The per-provider log readers emit these so the cost pipeline downstream is
/// provider-agnostic.
struct TokenEvent {
    /// One shared provider vocabulary across usage, alerts, and cost —
    /// `AlertEngine.Provider` is the canonical enum; cost code uses this
    /// alias so the two layers can never drift apart again.
    typealias Provider = AlertEngine.Provider

    let provider: Provider
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    /// Tokens written to the prompt cache during this turn. Codex sessions
    /// report no separate cache-creation count (always 0 there).
    let cacheCreationTokens: Int
    /// Tokens served from the prompt cache during this turn (Kimi calls
    /// these "inputCacheRead"; Codex calls them "cached_input_tokens").
    let cacheReadTokens: Int
}
