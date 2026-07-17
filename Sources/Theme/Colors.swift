import SwiftUI

/// Locked color tokens for CodexIsland.
enum IslandColor {
    /// #0047AB — loading sweep, glow halo.
    static let cobalt = Color(red: 0/255, green: 71/255, blue: 171/255)

    /// #8A7CFF — Kimi brand purple. Kimi logo + ring/bar fills.
    static let kimi = Color(red: 138/255, green: 124/255, blue: 255/255)

    /// #5AA8F0 — OpenAI sky blue. Codex logo + ring/bar fills.
    static let codex = Color(red: 90/255, green: 168/255, blue: 240/255)

    /// #D4915D — Anthropic clay orange. Claude logo + ring/bar fills.
    static let claude = Color(red: 212/255, green: 145/255, blue: 93/255)

    /// #E8E8E8 — near-white. Grok's brand is monochrome (black/white); on
    /// the black silhouette the logo and fills read as soft white.
    static let grok = Color(red: 232/255, green: 232/255, blue: 232/255)

    /// #3B66FD — Zhipu/z.ai brand blue. GLM logo + ring/bar fills.
    static let glm = Color(red: 59/255, green: 102/255, blue: 253/255)

    /// #3DD68C — live status dot. Sits next to cobalt without clashing.
    static let liveTeal = Color(red: 61/255, green: 214/255, blue: 140/255)

    /// #F5A524 — approaching-limit warning tint. Reads as "amber" against
    /// the black silhouette without competing with the cobalt halo. Used
    /// for the static glow + peek pill accent at warning severity.
    static let alertAmber = Color(red: 245/255, green: 165/255, blue: 36/255)

    /// #E5484D — approaching-limit critical tint. Saturated enough to read
    /// as "stop, you're cooked" without going full red-alert pure.
    static let alertRed = Color(red: 229/255, green: 72/255, blue: 77/255)
}

extension AlertEngine.Provider {
    /// Brand tint for the provider's logo, charts, and settings dot.
    var brandColor: Color {
        switch self {
        case .kimi:   return IslandColor.kimi
        case .codex:  return IslandColor.codex
        case .claude: return IslandColor.claude
        case .grok:   return IslandColor.grok
        case .glm:    return IslandColor.glm
        }
    }

    /// Bundle resource for the peek-state logo (name + extension). Claude
    /// ships the upstream vector PDF; grok/glm are rasterized PNGs (no
    /// official vector source available offline).
    var logoResource: (name: String, ext: String) {
        switch self {
        case .kimi:   return ("kimi_logo", "pdf")
        case .codex:  return ("openai_logo", "pdf")
        case .claude: return ("claude_logo", "pdf")
        case .grok:   return ("grok_logo", "png")
        case .glm:    return ("glm_logo", "png")
        }
    }
}
