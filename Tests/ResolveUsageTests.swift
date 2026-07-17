import Foundation

/// Regression tests for KimiCredentials.resolveUsage, run by
/// scripts/run-tests.sh (no XCTest — the app builds with bare swiftc, so the
/// harness does too). Every case points KIMI_CODE_HOME at a per-run fixture
/// directory before touching KimiCredentials, so the real ~/.kimi-code login
/// on a dev machine is never read and results stay deterministic.
///
/// Why the rate-limited case is locked down (issue #35 heritage): the usage
/// endpoint's limiter is account-keyed and sticky once tripped. resolveUsage
/// must short-circuit on the first rate-limited probe — a fall-through would
/// re-probe against a throttled account every poll cycle.
@main
struct ResolveUsageTests {
    final class ProbeCounter {
        var calls = 0
    }

    static var failures = 0
    static let fixtureDir = NSTemporaryDirectory() + "codexisland-tests-\(ProcessInfo.processInfo.processIdentifier)"

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("PASS \(label)")
        } else {
            print("FAIL \(label)")
            failures += 1
        }
    }

    /// Writes (or removes) the fixture credentials file and pins KIMI_CODE_HOME
    /// to it. `expiresIn` is relative to now; negative values write an
    /// already-expired token.
    static func installFixture(accessToken: String? = "file-at", expiresIn: TimeInterval = 900) {
        try? FileManager.default.removeItem(atPath: fixtureDir)
        setenv("KIMI_CODE_HOME", fixtureDir, 1)
        guard let accessToken else { return }
        let credsDir = fixtureDir + "/credentials"
        try? FileManager.default.createDirectory(atPath: credsDir, withIntermediateDirectories: true)
        let expiresAt = Date().addingTimeInterval(expiresIn).timeIntervalSince1970
        let fixture = """
        {"access_token": "\(accessToken)", "refresh_token": "file-rt", "expires_at": \(Int(expiresAt)), "scope": "kimi-code", "token_type": "Bearer"}
        """
        FileManager.default.createFile(atPath: credsDir + "/kimi-code.json", contents: Data(fixture.utf8))
    }

    static func main() async {
        // T1 — no credentials file at all (Codex-only user, or never logged
        // in): immediate auth-required failure, no probe.
        installFixture(accessToken: nil)
        let t1 = ProbeCounter()
        let r1 = await KimiCredentials.resolveUsage { _ in
            t1.calls += 1
            return .success(AppUsage(fiveHour: .unknown, weekly: .unknown))
        }
        if case .failed(let msg) = r1 {
            expect(msg == "auth required — run kimi", "T1 resolution is .failed(auth required)")
        } else {
            expect(false, "T1 resolution is .failed(auth required)")
        }
        expect(t1.calls == 0, "T1 never probes without a credentials file (got \(t1.calls))")

        // T2 — a valid file token + successful probe passes usage through
        // untouched, probing exactly once with the file's token.
        installFixture(accessToken: "file-at")
        let t2 = ProbeCounter()
        var t2Token: String?
        let fetched = AppUsage(
            fiveHour: WindowUsage(usedPercent: 0.13, resetAt: nil, error: nil),
            weekly: WindowUsage(usedPercent: 0.14, resetAt: nil, error: nil)
        )
        let r2 = await KimiCredentials.resolveUsage { token in
            t2.calls += 1
            t2Token = token
            return .success(fetched)
        }
        if case .usage(let u) = r2 {
            expect(u.fiveHour.usedPercent == 0.13 && u.weekly.usedPercent == 0.14, "T2 usage passes through")
        } else {
            expect(false, "T2 usage passes through")
        }
        expect(t2.calls == 1, "T2 probes exactly once (got \(t2.calls))")
        expect(t2Token == "file-at", "T2 probes with the file's access token")

        // T3 — a locally-expired file token short-cuits BEFORE any probe:
        // Kimi Code rotates the access token every ~15 minutes and we never
        // refresh it ourselves, so an expired file is reported as-is.
        installFixture(expiresIn: -60)
        let t3 = ProbeCounter()
        let r3 = await KimiCredentials.resolveUsage { _ in
            t3.calls += 1
            return .success(fetched)
        }
        if case .failed(let msg) = r3 {
            expect(msg == KimiCredentials.tokenExpiredMessage, "T3 resolution is .failed(tokenExpiredMessage)")
        } else {
            expect(false, "T3 resolution is .failed(tokenExpiredMessage)")
        }
        expect(t3.calls == 0, "T3 never probes an expired token (got \(t3.calls))")

        // T4 — a rate-limited probe short-circuits the whole resolution:
        // exactly one probe and the exact error string the UI and UsageStore
        // cooldown match on.
        installFixture()
        let t4 = ProbeCounter()
        let r4 = await KimiCredentials.resolveUsage { _ in
            t4.calls += 1
            return .rateLimited
        }
        if case .failed(let msg) = r4 {
            expect(msg == KimiCredentials.rateLimitedMessage, "T4 resolution is .failed(rateLimitedMessage)")
        } else {
            expect(false, "T4 resolution is .failed(rateLimitedMessage)")
        }
        expect(t4.calls == 1, "T4 probes exactly once (got \(t4.calls))")

        // T5 — a 401 probe on a fresh-looking file means the session was
        // revoked server-side; the only remediation is a fresh `kimi login`.
        installFixture()
        let t5 = ProbeCounter()
        let r5 = await KimiCredentials.resolveUsage { _ in
            t5.calls += 1
            return .unauthorized
        }
        if case .failed(let msg) = r5 {
            expect(msg == KimiCredentials.reauthRequiredMessage, "T5 resolution is .failed(reauthRequiredMessage)")
        } else {
            expect(false, "T5 resolution is .failed(reauthRequiredMessage)")
        }
        expect(t5.calls == 1, "T5 probes exactly once (got \(t5.calls))")

        // T6 — credentials-file decoding: access_token and expires_at must
        // both come through, and a malformed file yields nil.
        installFixture(accessToken: "decode-me")
        let creds = KimiCredentials.readKimiCreds()
        expect(creds?.accessToken == "decode-me", "T6 access_token decodes")
        expect(creds != nil && creds!.expiresAt > Date(), "T6 expires_at decodes as a future date")
        FileManager.default.createFile(atPath: fixtureDir + "/credentials/kimi-code.json",
                                       contents: Data("{\"nope\": 1}".utf8))
        expect(KimiCredentials.readKimiCreds() == nil, "T6 malformed file yields nil creds")
        try? FileManager.default.removeItem(atPath: fixtureDir)

        // T7 — auth-failure classification. The usage panel swaps its chart
        // tiles for the re-auth prompt on a both-window actionable pair, so
        // both predicates must key only on the two actionable sentinels, and
        // isTerminalAuthFailure must require BOTH windows to carry one — a
        // single-window failure is a transient per-window glitch, not a
        // dead token.
        expect(KimiCredentials.isReauthActionable(KimiCredentials.tokenExpiredMessage),
               "T7 expired token is reauth-actionable")
        expect(KimiCredentials.isReauthActionable(KimiCredentials.reauthRequiredMessage),
               "T7 re-login is reauth-actionable")
        expect(!KimiCredentials.isReauthActionable(KimiCredentials.rateLimitedMessage),
               "T7 rate-limited is NOT reauth-actionable")
        expect(!KimiCredentials.isReauthActionable("no data"), "T7 no-data is NOT reauth-actionable")
        expect(!KimiCredentials.isReauthActionable(nil), "T7 nil error is NOT reauth-actionable")

        func pair(_ msg: String?) -> AppUsage {
            AppUsage(
                fiveHour: WindowUsage(usedPercent: 0, resetAt: nil, error: msg),
                weekly: WindowUsage(usedPercent: 0, resetAt: nil, error: msg))
        }
        expect(KimiCredentials.isTerminalAuthFailure(pair(KimiCredentials.tokenExpiredMessage)),
               "T7 both-window expired is a terminal auth failure")
        expect(KimiCredentials.isTerminalAuthFailure(pair(KimiCredentials.reauthRequiredMessage)),
               "T7 both-window re-login is a terminal auth failure")
        expect(!KimiCredentials.isTerminalAuthFailure(pair(KimiCredentials.rateLimitedMessage)),
               "T7 rate-limited is NOT a terminal auth failure")
        expect(!KimiCredentials.isTerminalAuthFailure(pair(nil)),
               "T7 good usage is NOT a terminal auth failure")
        expect(!KimiCredentials.isTerminalAuthFailure(AppUsage(
            fiveHour: WindowUsage(usedPercent: 0.1, resetAt: nil, error: nil),
            weekly: WindowUsage(usedPercent: 0, resetAt: nil, error: KimiCredentials.tokenExpiredMessage))),
            "T7 single-window failure is NOT terminal (needs both)")

        // T8 — server-revocation classification. UsageStore's "don't clobber
        // good values" retention makes its exception ONLY for a both-window
        // 401: a revoked session never recovers on its own. Local expiry is
        // retained through instead — the CLI's token rotation self-heals it,
        // and blanking the peek pill through every rotation gap was the bug.
        expect(KimiCredentials.isServerRevocation(pair(KimiCredentials.reauthRequiredMessage)),
               "T8 both-window re-login IS a server revocation")
        expect(!KimiCredentials.isServerRevocation(pair(KimiCredentials.tokenExpiredMessage)),
               "T8 both-window expired is NOT a server revocation (retained, self-heals)")
        expect(!KimiCredentials.isServerRevocation(pair(KimiCredentials.rateLimitedMessage)),
               "T8 rate-limited is NOT a server revocation")
        expect(!KimiCredentials.isServerRevocation(pair(nil)),
               "T8 good usage is NOT a server revocation")
        expect(!KimiCredentials.isServerRevocation(AppUsage(
            fiveHour: WindowUsage(usedPercent: 0, resetAt: nil, error: KimiCredentials.reauthRequiredMessage),
            weekly: WindowUsage(usedPercent: 0, resetAt: nil, error: nil))),
            "T8 single-window re-login is NOT a server revocation (needs both)")

        // The store and views match these exact strings; a reword is a
        // breaking change for them, not a copy edit.
        expect(KimiCredentials.rateLimitedMessage == "rate limited", "rateLimitedMessage literal is stable")
        expect(KimiCredentials.reauthRequiredMessage == "re-login: kimi login", "reauthRequiredMessage literal is stable")
        expect(KimiCredentials.tokenExpiredMessage == "token expired — run kimi", "tokenExpiredMessage literal is stable")

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all tests passed")
    }
}
