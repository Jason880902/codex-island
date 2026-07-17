import Foundation

/// Fixture tests for UsageFetcher.parseGLMUsage — the pure parse half of
/// the GLM (Zhipu) coding-plan quota integration. The shapes below mirror
/// the publicly reported response ({code, data.limits[]}) from cc-switch-
/// style integrations; they are FIXTURES, not a live capture — no GLM key
/// was available at implementation time. If a live capture disagrees,
/// update the fixtures together with the parser.
@main
struct GLMUsageParsingTests {
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
        // T1 — full payload: both limits, Int percentages, ISO resetTime
        // (fractional seconds on one, plain on the other).
        let full: [String: Any] = [
            "code": 200,
            "data": [
                "limits": [
                    ["type": "TIME_LIMIT", "percentage": 33,
                     "resetTime": "2026-07-17T20:00:00.000Z"],
                    ["type": "TOKENS_LIMIT", "percentage": 75,
                     "resetTime": "2026-07-24T00:00:00Z"],
                ],
            ],
        ]
        let u1 = UsageFetcher.parseGLMUsage(full)
        expect(abs(u1.fiveHour.usedPercent - 0.33) < 0.0001, "T1 TIME_LIMIT maps to the 5h window")
        expect(abs(u1.weekly.usedPercent - 0.75) < 0.0001, "T1 TOKENS_LIMIT maps to the weekly window")
        expect(u1.fiveHour.resetAt != nil && u1.weekly.resetAt != nil, "T1 ISO resetTimes parse (fractional + plain)")
        expect(u1.fiveHour.error == nil && u1.weekly.error == nil, "T1 no window errors on a full payload")
        expect(u1.plan == nil, "T1 plan stays nil (endpoint reports no tier)")

        // T2 — TIME_LIMIT only: the weekly tile must read .unknown, not a
        // fabricated 0%.
        let u2 = UsageFetcher.parseGLMUsage([
            "code": 200,
            "data": ["limits": [["type": "TIME_LIMIT", "percentage": 10]]],
        ])
        expect(abs(u2.fiveHour.usedPercent - 0.10) < 0.0001, "T2 5h window still parses")
        expect(u2.weekly.error == "no data", "T2 missing TOKENS_LIMIT yields .unknown weekly")

        // T3 — percentage as String (and code as String): a server-side
        // type change must not blank the panel.
        let u3 = UsageFetcher.parseGLMUsage([
            "code": "200",
            "data": ["limits": [["type": "TIME_LIMIT", "percentage": "42"]]],
        ])
        expect(abs(u3.fiveHour.usedPercent - 0.42) < 0.0001, "T3 string percentage + string code tolerated")

        // T4 — boundaries: 0% is a real reading (not .unknown), 100%
        // saturates at 1.0.
        let u4 = UsageFetcher.parseGLMUsage([
            "code": 200,
            "data": ["limits": [
                ["type": "TIME_LIMIT", "percentage": 0],
                ["type": "TOKENS_LIMIT", "percentage": 100],
            ]],
        ])
        expect(u4.fiveHour.usedPercent == 0 && u4.fiveHour.error == nil, "T4 0% is a real reading, not .unknown")
        expect(u4.weekly.usedPercent == 1, "T4 100% saturates at 1.0")

        // T5 — missing data object: both windows .unknown.
        let u5 = UsageFetcher.parseGLMUsage(["code": 200])
        expect(u5.fiveHour.error == "no data" && u5.weekly.error == "no data", "T5 missing data yields .unknown windows")

        // T6 — Double percentage + unix-seconds reset under the
        // nextResetTime alias.
        let u6 = UsageFetcher.parseGLMUsage([
            "code": 200,
            "data": ["limits": [
                ["type": "TIME_LIMIT", "percentage": 12.5, "nextResetTime": 1785000000],
            ]],
        ])
        expect(abs(u6.fiveHour.usedPercent - 0.125) < 0.0001, "T6 Double percentage tolerated")
        expect(u6.fiveHour.resetAt == Date(timeIntervalSince1970: 1785000000), "T6 unix-seconds nextResetTime parses")

        // T7 — non-200 business code surfaces a visible error pair, not 0%.
        let u7 = UsageFetcher.parseGLMUsage(["code": 401, "message": "invalid api key"])
        expect(u7.fiveHour.error != nil && u7.weekly.error != nil, "T7 non-200 code yields error windows")
        expect(u7.fiveHour.error == "GLM error 401: invalid api key", "T7 error carries code + server message")

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all tests passed")
    }
}
