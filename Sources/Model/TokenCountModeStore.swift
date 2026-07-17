import Foundation

/// How the cost screen sums tokens for the TOKENS hero. The billable reading
/// reports input + output only, while ccusage — and CodexIsland by default —
/// sums every token type that crossed the wire, including cache reads. The
/// two diverge by ~10× in normal CLI usage because cache reads dwarf the
/// rest.
enum TokenCountMode: String, CaseIterable {
    /// input + output + cache_creation + cache_read. ccusage parity.
    case all
    /// input + output only. Cache reads excluded.
    case billable

    var label: String {
        switch self {
        case .all:      L10n.tr("All tokens")
        case .billable: L10n.tr("Input + output")
        }
    }
}

@MainActor
final class TokenCountModeStore: ObservableObject {
    static let shared = TokenCountModeStore()

    private static let key = "MacIsland.tokenCountMode"

    @Published var mode: TokenCountMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.key) }
    }

    private init() {
        self.mode = Pref.enumValue(key: Self.key, default: .all)
    }
}
