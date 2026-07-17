import Foundation

/// Slot assignment for the two island slots (left / right of the notch).
/// Each slot holds one provider (or nil = slot off); the expanded panel
/// follows the same assignment. Picking a provider already sitting in the
/// other slot swaps the two — a provider can never occupy both slots.
///
/// Replaces the old per-provider visibility booleans: "hidden" is now
/// "not in any slot". `effectiveVisible(provider:)` keeps its old
/// signature so provider-keyed call sites (alert engine, logo/pill
/// overlays) read unchanged. One-time migration seeds the slots from the
/// legacy `kimiVisible`/`codexVisible` keys.
@MainActor
final class ProviderVisibilityStore: ObservableObject {
    static let shared = ProviderVisibilityStore()

    enum Slot: String {
        case left
        case right

        var other: Slot { self == .left ? .right : .left }
    }

    private static let leftKey = "MacIsland.slotLeft"
    private static let rightKey = "MacIsland.slotRight"
    // Legacy keys, read once for migration then left alone.
    private static let legacyKimiKey = "MacIsland.kimiVisible"
    private static let legacyCodexKey = "MacIsland.codexVisible"

    typealias Provider = AlertEngine.Provider

    @Published private(set) var leftProvider: Provider? {
        didSet { Self.persist(leftProvider, key: Self.leftKey) }
    }
    @Published private(set) var rightProvider: Provider? {
        didSet { Self.persist(rightProvider, key: Self.rightKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        if let leftRaw = defaults.string(forKey: Self.leftKey),
           let rightRaw = defaults.string(forKey: Self.rightKey) {
            self.leftProvider = Self.decode(leftRaw)
            self.rightProvider = Self.decode(rightRaw)
        } else {
            // Migration: both legacy toggles defaulted to true, so the
            // pre-slot layout was Kimi left / Codex right unless the user
            // had switched one off (off → empty slot).
            let kimiOn = Pref.seededBool(key: Self.legacyKimiKey, default: true)
            let codexOn = Pref.seededBool(key: Self.legacyCodexKey, default: true)
            self.leftProvider = kimiOn ? .kimi : nil
            self.rightProvider = codexOn ? .codex : nil
            Self.persist(leftProvider, key: Self.leftKey)
            Self.persist(rightProvider, key: Self.rightKey)
        }
    }

    /// Assign `provider` to `slot`. If it currently sits in the other slot,
    /// the two swap; assigning nil clears the slot.
    func assign(_ provider: Provider?, to slot: Slot) {
        switch slot {
        case .left:
            guard provider != leftProvider else { return }
            if let provider, rightProvider == provider {
                rightProvider = leftProvider
            }
            leftProvider = provider
        case .right:
            guard provider != rightProvider else { return }
            if let provider, leftProvider == provider {
                leftProvider = rightProvider
            }
            rightProvider = provider
        }
    }

    /// Which slot (if any) currently holds `provider`.
    func slot(of provider: Provider) -> Slot? {
        if leftProvider == provider { return .left }
        if rightProvider == provider { return .right }
        return nil
    }

    func provider(in slot: Slot) -> Provider? {
        slot == .left ? leftProvider : rightProvider
    }

    /// Single accessor for call sites that have an `AlertEngine.Provider`
    /// in hand. A provider is visible iff it occupies a slot.
    func effectiveVisible(provider: Provider) -> Bool {
        slot(of: provider) != nil
    }

    private static func persist(_ provider: Provider?, key: String) {
        // "none" is written for nil so "user cleared the slot" survives a
        // relaunch instead of falling into the migration branch (which
        // keys on missing values).
        UserDefaults.standard.set(provider?.rawValue ?? "none", forKey: key)
    }

    private static func decode(_ raw: String) -> Provider? {
        raw == "none" ? nil : Provider(rawValue: raw)
    }
}
