import Foundation

/// Fixture tests for UsageFetcher.parseGrokUsage — the pure parse half of
/// the grok.com /rest/rate-limits integration. The response shape is
/// UNVERIFIED (no cookie was available at implementation time), so the
/// parser is defensive: these tests pin the contract that plausible shapes
/// parse to a 5h reading and unrecognizable shapes fail VISIBLY with the
/// parse-error sentinel — never crash, never silently render 0%.
@main
struct GrokUsageParsingTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("PASS \(label)")
        } else {
            print("FAIL \(label)")
            failures += 1
        }
    }

    static func main() {
        // T1 — plausible nested payload: a remaining/total pair one level
        // down maps to the 5h window as 1 - remaining/total.
        let u1 = UsageFetcher.parseGrokUsage([
            "rateLimits": ["remainingQueries": 40, "totalQueries": 100],
        ])
        expect(abs(u1.fiveHour.usedPercent - 0.6) < 0.0001, "T1 nested remaining/total pair maps to 5h window")
        expect(u1.fiveHour.error == nil, "T1 no error on a recognized payload")
        expect(u1.weekly.error == "no data", "T1 weekly stays .unknown (no known weekly figure)")

        // T2 — pair at the top level, values as strings.
        let u2 = UsageFetcher.parseGrokUsage(["remaining": "25", "total": "50"])
        expect(abs(u2.fiveHour.usedPercent - 0.5) < 0.0001, "T2 top-level string pair tolerated")

        // T3 — alternate key spellings (remainingTokens against limit)
        // inside an arbitrarily named group.
        let u3 = UsageFetcher.parseGrokUsage([
            "quota": ["remainingTokens": 90, "limit": 100],
        ])
        expect(abs(u3.fiveHour.usedPercent - 0.1) < 0.0001, "T3 remainingTokens/limit spelling recognized")

        // T4 — empty dict: the parse-error sentinel on both windows, not a
        // crash, not 0%.
        let u4 = UsageFetcher.parseGrokUsage([:])
        expect(u4.fiveHour.error == "parse error — grok response changed", "T4 empty dict yields the parse-error sentinel")
        expect(u4.weekly.error == "parse error — grok response changed", "T4 sentinel on both windows")

        // T5 — totally unrelated shape: same sentinel.
        let u5 = UsageFetcher.parseGrokUsage(["foo": "bar"])
        expect(u5.fiveHour.error == "parse error — grok response changed", "T5 unrelated shape yields the sentinel")
        expect(u5.weekly.error == "parse error — grok response changed", "T5 sentinel on both windows here too")

        // T6 — a zero total must not divide-by-zero; the shape falls
        // through to the sentinel like any unrecognizable one.
        let u6 = UsageFetcher.parseGrokUsage(["remaining": 0, "total": 0])
        expect(u6.fiveHour.error == "parse error — grok response changed", "T6 zero total rejected before dividing")

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all tests passed")
    }
}
