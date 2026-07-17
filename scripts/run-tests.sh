#!/bin/bash
# Compiles the usage-resolution sources together with the test harness and
# runs it. No XCTest/SPM — mirrors build.sh's bare-swiftc approach. The
# KIMI_CODE_HOME stub keeps the harness off the developer's real
# ~/.kimi-code login (see Tests/ResolveUsageTests.swift).
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR=$(mktemp -d)
trap 'rm -rf "$OUT_DIR"' EXIT

swiftc \
  -parse-as-library \
  -o "$OUT_DIR/resolve-usage-tests" \
  Sources/Model/UsageDisplayModeStore.swift \
  Sources/Usage/AppUsage.swift \
  Sources/Usage/KimiCredentials.swift \
  Tests/ResolveUsageTests.swift

KIMI_CODE_HOME="$OUT_DIR/no-such-kimi-home" "$OUT_DIR/resolve-usage-tests"

swiftc \
  -parse-as-library \
  -o "$OUT_DIR/kimi-usage-parsing-tests" \
  Sources/Model/UsageDisplayModeStore.swift \
  Sources/Usage/AppUsage.swift \
  Sources/Usage/KimiCredentials.swift \
  Sources/Usage/ClaudeCredentials.swift \
  Sources/Usage/CodexResetCredits.swift \
  Sources/Usage/UsageFetcher.swift \
  Tests/KimiUsageParsingTests.swift

"$OUT_DIR/kimi-usage-parsing-tests"

swiftc \
  -parse-as-library \
  -o "$OUT_DIR/claude-usage-parsing-tests" \
  Sources/Model/UsageDisplayModeStore.swift \
  Sources/Usage/AppUsage.swift \
  Sources/Usage/KimiCredentials.swift \
  Sources/Usage/ClaudeCredentials.swift \
  Sources/Usage/CodexResetCredits.swift \
  Sources/Usage/UsageFetcher.swift \
  Tests/ClaudeUsageParsingTests.swift

"$OUT_DIR/claude-usage-parsing-tests"

# GLM/Grok parsing tests. ProviderKeyStore's setter fires
# `UsageStore.shared.refresh()`, but the real UsageStore drags in the whole
# engine graph — a two-line stub satisfies the reference in the harness.
cat > "$OUT_DIR/UsageStoreStub.swift" <<'EOF'
import Foundation
@MainActor final class UsageStore {
    static let shared = UsageStore()
    private init() {}
    func refresh() {}
}
EOF

GLM_GROK_SOURCES="Sources/Model/UsageDisplayModeStore.swift Sources/Usage/AppUsage.swift Sources/Usage/KimiCredentials.swift Sources/Usage/ClaudeCredentials.swift Sources/Usage/CodexResetCredits.swift Sources/Usage/UsageFetcher.swift Sources/Usage/UsageFetcherGLMGrok.swift Sources/Usage/ProviderKeyStore.swift Sources/Usage/GLMCredentials.swift Sources/Usage/GrokCredentials.swift $OUT_DIR/UsageStoreStub.swift"

# shellcheck disable=SC2086 # intentional word splitting in the source list
swiftc \
  -parse-as-library \
  -o "$OUT_DIR/glm-usage-parsing-tests" \
  $GLM_GROK_SOURCES \
  Tests/GLMUsageParsingTests.swift

"$OUT_DIR/glm-usage-parsing-tests"

# shellcheck disable=SC2086
swiftc \
  -parse-as-library \
  -o "$OUT_DIR/grok-usage-parsing-tests" \
  $GLM_GROK_SOURCES \
  Tests/GrokUsageParsingTests.swift

"$OUT_DIR/grok-usage-parsing-tests"

# Provider slot store tests. A minimal AlertEngine stub (just the nested
# Provider enum) keeps the real engine/usage graph out of the harness. The
# store is a singleton that reads UserDefaults once, so each scenario runs
# as a separate process invocation.
cat > "$OUT_DIR/AlertEngineStub.swift" <<'EOF'
final class AlertEngine {
    enum Provider: String, Hashable, CaseIterable {
        case kimi, codex, claude, grok, glm
    }
}
EOF

swiftc \
  -parse-as-library \
  -o "$OUT_DIR/provider-slot-store-tests" \
  "$OUT_DIR/AlertEngineStub.swift" \
  Sources/Model/ProviderVisibilityStore.swift \
  Sources/Model/PreferenceStorage.swift \
  Tests/ProviderSlotStoreTests.swift

for scenario in fresh legacy-off swap seeded invalid; do
  "$OUT_DIR/provider-slot-store-tests" "$scenario"
done

swiftc \
  -parse-as-library \
  -o "$OUT_DIR/notch-height-tests" \
  Sources/Model/NotchInfo.swift \
  Sources/Model/IslandSpacingStore.swift \
  Sources/Model/PreferenceStorage.swift \
  Tests/NotchHeightTests.swift

"$OUT_DIR/notch-height-tests"
