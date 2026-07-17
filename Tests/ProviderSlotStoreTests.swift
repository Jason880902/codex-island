import Foundation

/// Tests for `ProviderVisibilityStore` (the island slot store).
///
/// The store is a singleton whose private init reads UserDefaults exactly
/// once, so each scenario below runs as a SEPARATE process invocation
/// (argv[1] selects it — see scripts/run-tests.sh). Every scenario clears
/// the four relevant keys before touching `shared`, which makes runs
/// hermetic despite the CLI binary's persistent defaults domain.
///
/// The compile line pairs this file with a minimal AlertEngine stub (just
/// the nested Provider enum) so the real engine's dependency graph stays
/// out of the harness.

private var failures = 0

private func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("PASS \(label)")
    } else {
        print("FAIL \(label)")
        failures += 1
    }
}

@main
struct ProviderSlotStoreTests {
    static let slotLeftKey = "MacIsland.slotLeft"
    static let slotRightKey = "MacIsland.slotRight"
    static let legacyKimiKey = "MacIsland.kimiVisible"
    static let legacyCodexKey = "MacIsland.codexVisible"

    static func clearKeys() {
        let defaults = UserDefaults.standard
        for key in [slotLeftKey, slotRightKey, legacyKimiKey, legacyCodexKey] {
            defaults.removeObject(forKey: key)
        }
    }

    @MainActor static func main() {
        let scenario = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "fresh"
        switch scenario {
        case "fresh":     fresh()
        case "legacy-off": legacyOff()
        case "swap":      swap()
        case "seeded":    seeded()
        case "invalid":   invalid()
        default:
            print("unknown scenario: \(scenario)")
            exit(2)
        }

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("scenario \(scenario) passed")
    }

    /// No slot keys, no legacy keys → migration seeds the pre-slot layout:
    /// Kimi left, Codex right (both legacy toggles defaulted to true).
    @MainActor static func fresh() {
        clearKeys()
        let store = ProviderVisibilityStore.shared
        expect(store.leftProvider == .kimi, "fresh: left defaults to kimi")
        expect(store.rightProvider == .codex, "fresh: right defaults to codex")
        expect(UserDefaults.standard.string(forKey: slotLeftKey) == "kimi",
               "fresh: left persisted")
        expect(UserDefaults.standard.string(forKey: slotRightKey) == "codex",
               "fresh: right persisted")
        expect(store.effectiveVisible(provider: .kimi), "fresh: kimi visible")
        expect(!store.effectiveVisible(provider: .glm), "fresh: glm not visible")
    }

    /// Legacy toggle off → that slot migrates to nil (and persists as
    /// "none" so the migration branch isn't re-entered next launch).
    @MainActor static func legacyOff() {
        clearKeys()
        UserDefaults.standard.set(false, forKey: legacyKimiKey)
        UserDefaults.standard.set(true, forKey: legacyCodexKey)
        let store = ProviderVisibilityStore.shared
        expect(store.leftProvider == nil, "legacy-off: left migrates to nil")
        expect(store.rightProvider == .codex, "legacy-off: right migrates to codex")
        expect(UserDefaults.standard.string(forKey: slotLeftKey) == "none",
               "legacy-off: nil slot persisted as 'none'")
    }

    /// assign() swaps a provider out of the other slot, clears on nil, and
    /// keeps slot(of:)/effectiveVisible in sync.
    @MainActor static func swap() {
        clearKeys()
        let store = ProviderVisibilityStore.shared  // fresh: kimi L, codex R

        store.assign(.codex, to: .left)
        expect(store.leftProvider == .codex, "swap: codex takes left")
        expect(store.rightProvider == .kimi, "swap: kimi displaced to right")

        store.assign(nil, to: .right)
        expect(store.rightProvider == nil, "swap: right cleared")
        expect(UserDefaults.standard.string(forKey: slotRightKey) == "none",
               "swap: cleared slot persisted as 'none'")

        store.assign(.glm, to: .right)
        expect(store.rightProvider == .glm, "swap: glm assigned to right")
        expect(store.slot(of: .glm) == .right, "swap: slot(of:) tracks assignment")
        expect(store.slot(of: .kimi) == nil, "swap: displaced kimi is slotless")
        expect(store.effectiveVisible(provider: .glm), "swap: glm visible")
        expect(!store.effectiveVisible(provider: .claude), "swap: claude not visible")

        // No-op assignment must not disturb the other slot.
        store.assign(.glm, to: .right)
        expect(store.leftProvider == .codex, "swap: redundant assign is a no-op")
    }

    /// Pre-seeded slot keys skip migration entirely, including "none".
    @MainActor static func seeded() {
        clearKeys()
        UserDefaults.standard.set("glm", forKey: slotLeftKey)
        UserDefaults.standard.set("none", forKey: slotRightKey)
        let store = ProviderVisibilityStore.shared
        expect(store.leftProvider == .glm, "seeded: left reads back glm")
        expect(store.rightProvider == nil, "seeded: 'none' decodes to nil")
    }

    /// Garbage raw values decode to nil rather than crashing or migrating.
    @MainActor static func invalid() {
        clearKeys()
        UserDefaults.standard.set("bogus", forKey: slotLeftKey)
        UserDefaults.standard.set("claude", forKey: slotRightKey)
        let store = ProviderVisibilityStore.shared
        expect(store.leftProvider == nil, "invalid: garbage raw decodes to nil")
        expect(store.rightProvider == .claude, "invalid: valid raw still decodes")
    }
}
