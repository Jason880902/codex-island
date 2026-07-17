import Foundation
import Combine
import Network

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    private init() {}

    typealias Provider = AlertEngine.Provider

    /// Latest usage per provider. Missing = never fetched (renders as the
    /// provider's empty state). All providers are fetched every poll
    /// regardless of slot assignment so switching slots never waits for
    /// the next poll; unconfigured providers short-circuit to their
    /// sentinel without network traffic.
    @Published private(set) var usage: [Provider: AppUsage] = [:]
    @Published var codexResetCredits: CodexResetCredits = .empty
    @Published var lastUpdated: Date?
    @Published var loading = false
    /// Set while a `kimi login` flow is in progress (spawned + still
    /// polling for the credentials file to update). The UI hides the re-auth
    /// button during this window so users don't double-tap and spawn
    /// duplicate CLI processes; the click ends up no-ops anyway because the
    /// spawn check gates on this.
    @Published var kimiReauthInProgress = false

    private var refreshTask: Task<Void, Never>?
    private var reauthPollTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var intervalCancellable: AnyCancellable?
    private var netMonitor: NWPathMonitor?
    private let netQueue = DispatchQueue(label: "UsageStore.network")
    private var lastNetStatus: NWPath.Status?

    /// Kimi's /coding/v1/usages endpoint is rate-limited per account.
    /// `RefreshIntervalStore` enforces a 5-minute floor (300/900/1800).
    private var pollInterval: TimeInterval {
        TimeInterval(RefreshIntervalStore.shared.seconds)
    }

    /// A rate limiter is sticky once tripped, so polling through it never
    /// recovers — it just keeps the account hot. After a rate-limited fetch,
    /// skip that provider's fetches for this long. Deliberately in-memory
    /// only — a quit+relaunch retries immediately. Applies to the providers
    /// with account-level limiters (kimi, claude); the rest poll through.
    private static let rateLimitCooldown: TimeInterval = 900
    private var cooldownUntil: [Provider: Date] = [:]

    private func isCoolingDown(_ provider: Provider) -> Bool {
        cooldownUntil[provider].map { Date() < $0 } ?? false
    }

    func refresh() {
        if loading { return }
        // Demo mode for screen recordings: skip the network entirely and
        // inject hand-tuned values that read as "real, healthy heavy-user
        // data". Reset times are recomputed each refresh so the countdowns
        // tick down naturally on camera. Off by default — only fires when
        // CODEXISLAND_DEMO=1 is set in the launching env.
        if AppEnvironment.isDemo {
            let now = Date()
            func window(_ pct: Double, _ resetIn: TimeInterval) -> WindowUsage {
                WindowUsage(usedPercent: pct, resetAt: now.addingTimeInterval(resetIn), error: nil)
            }
            self.usage = [
                .kimi: AppUsage(
                    fiveHour: window(0.73, 1 * 3600 + 47 * 60),
                    weekly: window(0.81, 4 * 86400 + 11 * 3600),
                    plan: "Intermediate"
                ),
                .codex: AppUsage(
                    fiveHour: window(0.67, 2 * 3600 + 23 * 60),
                    weekly: window(0.76, 4 * 86400 + 18 * 3600),
                    plan: "pro"
                ),
                .claude: AppUsage(
                    fiveHour: window(0.41, 3 * 3600 + 12 * 60),
                    weekly: window(0.58, 5 * 86400 + 2 * 3600),
                    plan: "max"
                ),
                .grok: AppUsage(
                    fiveHour: window(0.22, 4 * 3600 + 5 * 60),
                    weekly: window(0.35, 6 * 86400 + 7 * 3600),
                    plan: "SuperGrok"
                ),
                .glm: AppUsage(
                    fiveHour: window(0.15, 1 * 3600 + 3 * 60),
                    weekly: window(0.49, 3 * 86400 + 9 * 3600),
                    plan: "Pro"
                ),
            ]
            self.codexResetCredits = CodexResetCredits(
                availableCount: 2,
                credits: [
                    CodexResetCredit(
                        id: "demo-reset-1",
                        status: "available",
                        expiresAt: now.addingTimeInterval(3 * 86400 + 4 * 3600),
                        title: "One free rate limit reset",
                        description: "Thanks for using Codex! You've been granted one free rate limit reset."
                    ),
                    CodexResetCredit(
                        id: "demo-reset-2",
                        status: "available",
                        expiresAt: now.addingTimeInterval(9 * 86400 + 3600),
                        title: "One free rate limit reset",
                        description: "Thanks for using Codex! You've been granted one free rate limit reset."
                    )
                ]
            )
            self.lastUpdated = now
            return
        }

        loading = true
        refreshTask?.cancel()
        refreshTask = Task {
            // All five providers poll concurrently. Unconfigured providers
            // (missing glm key / grok cookie, logged-out claude) resolve to
            // their sentinel without network traffic — see the fetchers.
            async let codexResult = UsageFetcher.fetchCodex()
            async let codexResetCreditsResult = UsageFetcher.fetchCodexResetCredits()
            async let grokResult = UsageFetcher.fetchGrok()
            async let glmResult = UsageFetcher.fetchGLM()
            async let kimiResult = self.fetchUnlessCoolingDown(.kimi)
            async let claudeResult = self.fetchUnlessCoolingDown(.claude)

            let results: [Provider: AppUsage?] = [
                .kimi: await kimiResult,
                .codex: await codexResult,
                .claude: await claudeResult,
                .grok: await grokResult,
                .glm: await glmResult,
            ]
            let codexResetCredits = await codexResetCreditsResult

            // Cancellation = network monitor saw the path come up while we
            // were mid-flight on a dead one. The fetched values are the
            // dead-path errors — drop them so the supersedes refresh
            // doesn't have a brief "cancelled" caption flash to overwrite.
            if Task.isCancelled {
                self.loading = false
                return
            }

            let now = Date()
            for (provider, result) in results {
                // nil = provider is in post-429 cooldown — keep whatever we
                // had rather than probing a tripped limiter.
                guard let result else { continue }
                self.applyRateLimitCooldown(provider: provider, result: result)
                if self.shouldStore(result, for: provider) {
                    self.usage[provider] = result
                }
                // Record this poll's readings so the SparkChart can plot real
                // history. `record` keeps only non-errored windows, so a failed
                // or rate-limited fetch leaves a gap instead of a flat fake line.
                UsageHistoryStore.shared.record(provider: provider, usage: result, at: now)
            }
            if let codexResetCredits {
                self.codexResetCredits = codexResetCredits
            }

            self.lastUpdated = now
            self.loading = false
        }
    }

    /// Fetch one rate-limitable provider unless it's in post-429 cooldown.
    /// nil means "skip this poll, keep the existing value".
    private func fetchUnlessCoolingDown(_ provider: Provider) async -> AppUsage? {
        guard !isCoolingDown(provider) else { return nil }
        switch provider {
        case .kimi:   return await UsageFetcher.fetchKimi()
        case .claude: return await UsageFetcher.fetchClaude()
        default:      return nil
        }
    }

    /// Arm/clear the post-429 fetch cooldown for providers with
    /// account-level limiters. Both windows carry the sentinel on a 429
    /// (see `UsageFetcher.errorPair`); anything else clears the cooldown.
    private func applyRateLimitCooldown(provider: Provider, result: AppUsage) {
        let sentinel: String
        switch provider {
        case .kimi:   sentinel = KimiCredentials.rateLimitedMessage
        case .claude: sentinel = ClaudeCredentials.rateLimitedMessage
        default:      return
        }
        if result.fiveHour.error == sentinel && result.weekly.error == sentinel {
            cooldownUntil[provider] = Date().addingTimeInterval(UsageStore.rateLimitCooldown)
            NSLog("CodexIsland: %@ usage rate-limited; skipping fetches for %.0fs",
                  provider.rawValue, UsageStore.rateLimitCooldown)
        } else {
            cooldownUntil[provider] = nil
        }
    }

    /// Don't clobber existing good values when a fetch returns an
    /// all-error result. A transient 429/network failure shouldn't blank
    /// the panel back to "0%" — that's worse than slightly stale data. If
    /// the existing value is itself error-only (cold start sitting on
    /// `.empty`, or a series of failures), let the new error through —
    /// otherwise a single bad first fetch sticks "no data" permanently
    /// even after the network recovers.
    ///
    /// One exception: a server-side revocation (kimi 401; claude revoked
    /// or scope-insufficient token) REPLACES the stale good value, so the
    /// panel surfaces the re-auth prompt instead of freezing on numbers it
    /// can no longer refresh. Local token expiry does NOT replace — the
    /// CLI rotates credentials on its own schedule and the retained value
    /// self-heals on a later poll.
    private func shouldStore(_ new: AppUsage, for provider: Provider) -> Bool {
        if !UsageStore.isErrorOnly(new) { return true }
        if UsageStore.isErrorOnly(usage[provider] ?? .empty) { return true }
        switch provider {
        case .kimi:   return KimiCredentials.isServerRevocation(new)
        case .claude: return ClaudeCredentials.isServerRevocation(new)
        default:      return false
        }
    }

    /// True when both windows have errors and zero values — nothing useful
    /// to show, so we keep whatever we had before.
    private static func isErrorOnly(_ u: AppUsage) -> Bool {
        u.fiveHour.error != nil && u.weekly.error != nil
            && u.fiveHour.usedPercent == 0 && u.weekly.usedPercent == 0
    }

    /// Replace the two slot providers' usage values with hand-tuned
    /// percentages so the alert engine's pulse + tint behavior can be
    /// exercised without waiting for a real provider crossing. Auto-refresh
    /// continues — the next scheduled poll will overwrite these values with
    /// real data. Each call uses fresh `resetAt` timestamps so the alert
    /// engine treats it as a new reset window and re-evaluates crossings.
    func injectPreviewUsage(leftFiveHour: Double, rightFiveHour: Double) {
        let slots = ProviderVisibilityStore.shared
        let now = Date()
        let fiveHourReset = now.addingTimeInterval(2 * 3600 + 14 * 60)
        let weeklyReset = now.addingTimeInterval(4 * 86400 + 6 * 3600)
        func inject(_ provider: Provider?, fiveHour: Double, weekly: Double, fallbackPlan: String) {
            guard let provider else { return }
            usage[provider] = AppUsage(
                fiveHour: WindowUsage(usedPercent: fiveHour, resetAt: fiveHourReset, error: nil),
                weekly: WindowUsage(usedPercent: weekly, resetAt: weeklyReset, error: nil),
                plan: usage[provider]?.plan ?? fallbackPlan
            )
        }
        inject(slots.leftProvider, fiveHour: leftFiveHour, weekly: 0.45, fallbackPlan: "Intermediate")
        inject(slots.rightProvider, fiveHour: rightFiveHour, weekly: 0.30, fallbackPlan: "pro")
        self.lastUpdated = now
    }

    /// Spawn `kimi login` and poll for the credentials file to update.
    ///
    /// We can't `await` the login directly — it happens in a separate
    /// process that may open a browser tab — so we kick off retries every
    /// few seconds and stop as soon as one returns success (or after a
    /// generous deadline so the button doesn't stay disabled forever if the
    /// user closes the browser without completing).
    func reauthenticateKimi() {
        guard !kimiReauthInProgress else { return }
        guard KimiCredentials.spawnReauth() else { return }
        kimiReauthInProgress = true
        reauthPollTask?.cancel()
        reauthPollTask = Task { [weak self] in
            // ~2 minutes total — generous enough that even a slow login
            // round-trip (browser cold start, SSO redirect, 2FA prompt)
            // resolves in time, short enough to not strand the UI.
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                let cl = await UsageFetcher.fetchKimi()
                if Task.isCancelled { return }
                if cl.fiveHour.error == nil || cl.weekly.error == nil {
                    await MainActor.run {
                        self?.usage[.kimi] = cl
                        self?.lastUpdated = Date()
                        self?.kimiReauthInProgress = false
                    }
                    return
                }
            }
            await MainActor.run { self?.kimiReauthInProgress = false }
        }
    }

    func startAutoRefresh() {
        stopAutoRefresh()
        refresh()
        armTimer()
        // Re-arm whenever the user changes the refresh interval. We
        // dropFirst() the initial @Published replay so we don't re-fire
        // refresh() on subscription.
        intervalCancellable = RefreshIntervalStore.shared.$seconds
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.armTimer() }
            }
        startNetworkMonitor()
    }

    func stopAutoRefresh() {
        pollTimer?.invalidate()
        pollTimer = nil
        intervalCancellable?.cancel()
        intervalCancellable = nil
        netMonitor?.cancel()
        netMonitor = nil
        lastNetStatus = nil
    }

    private func armTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Trigger an immediate refresh whenever the network transitions from
    /// unsatisfied to satisfied — closes the launch-at-login race where
    /// Wi-Fi is still associating when our first refresh fires. Without
    /// this, the panel sits at the empty cold-start state until the next
    /// scheduled poll (5–30 minutes away). The initial path callback fires
    /// with the current state and is deliberately ignored (lastNetStatus
    /// starts nil) — startAutoRefresh's own refresh() already covers
    /// cold-start, and acting on the initial callback would double-fire.
    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let was = self.lastNetStatus
                self.lastNetStatus = path.status
                guard path.status == .satisfied,
                      let prior = was, prior != .satisfied else { return }
                // Cancel any in-flight refresh — its URLSession call was
                // started on the dead path and is going to return an
                // error. Wait for it to finalize so its loading=false
                // lands before we start the replacement, otherwise our
                // refresh() hits the `if loading { return }` guard.
                self.refreshTask?.cancel()
                await self.refreshTask?.value
                self.refresh()
            }
        }
        monitor.start(queue: netQueue)
        netMonitor = monitor
    }
}
