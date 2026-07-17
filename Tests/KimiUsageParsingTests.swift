import Foundation

/// Fixture tests for UsageFetcher.parseKimiUsage — the pure parse half of
/// the Kimi `/coding/v1/usages` integration. The shapes below mirror a real
/// 200 response captured against api.kimi.com (2026-07): quota fields are
/// STRING numbers, resetTime is ISO8601 with fractional seconds, the weekly
/// quota is the top-level `usage` object and the 5h window rides in
/// `limits[]` as a 300-minute entry.
@main
struct KimiUsageParsingTests {
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
        // T1 — full real-world payload: both windows + plan chip decode.
        let real: [String: Any] = [
            "user": ["userId": "u1", "region": "REGION_CN",
                     "membership": ["level": "LEVEL_INTERMEDIATE"]],
            "usage": ["limit": "100", "used": "2", "remaining": "98",
                      "resetTime": "2026-07-24T01:41:57.351169Z"],
            "limits": [
                ["window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                 "detail": ["limit": "100", "used": "8", "remaining": "92",
                            "resetTime": "2026-07-17T11:41:57.351169Z"]],
            ],
        ]
        let u1 = UsageFetcher.parseKimiUsage(real)
        expect(abs(u1.fiveHour.usedPercent - 0.08) < 0.0001, "T1 5h window maps the 300-minute limits[] entry")
        expect(abs(u1.weekly.usedPercent - 0.02) < 0.0001, "T1 weekly maps the top-level usage object")
        expect(u1.plan == "Intermediate", "T1 membership level prettified (got \(u1.plan ?? "nil"))")
        expect(u1.fiveHour.resetAt != nil && u1.weekly.resetAt != nil, "T1 fractional-second resetTimes parse")
        expect(u1.fiveHour.error == nil && u1.weekly.error == nil, "T1 no window errors on a full payload")

        // T2 — limits[] absent (fresh account / quiet period): the 5h tile
        // must show its passive state (.unknown), not a fabricated 0%.
        let u2 = UsageFetcher.parseKimiUsage([
            "usage": ["limit": "100", "used": "5", "remaining": "95"],
        ])
        expect(u2.fiveHour.error == "no data", "T2 missing limits[] yields .unknown 5h window")
        expect(abs(u2.weekly.usedPercent - 0.05) < 0.0001, "T2 weekly still parses")
        expect(u2.plan == nil, "T2 missing membership yields nil plan")

        // T3 — a limits[] entry in another unit/duration must NOT be picked
        // up as the 5h window.
        let u3 = UsageFetcher.parseKimiUsage([
            "usage": ["limit": "100", "used": "1", "remaining": "99"],
            "limits": [
                ["window": ["duration": 1, "timeUnit": "TIME_UNIT_DAY"],
                 "detail": ["limit": "10", "used": "9", "remaining": "1"]],
            ],
        ])
        expect(u3.fiveHour.error == "no data", "T3 non-300-minute limits[] entry is ignored")

        // T4 — numeric (non-string) quota fields are tolerated so a
        // server-side type change doesn't blank the panel.
        let u4 = UsageFetcher.parseKimiUsage([
            "usage": ["limit": 50, "used": 25, "remaining": 25],
        ])
        expect(abs(u4.weekly.usedPercent - 0.5) < 0.0001, "T4 numeric quota fields tolerated")

        // T5 — a zero limit reads as 0%, never a divide-by-zero.
        let u5 = UsageFetcher.parseKimiUsage([
            "usage": ["limit": "0", "used": "0", "remaining": "0"],
        ])
        expect(u5.weekly.usedPercent == 0, "T5 zero limit yields 0%")

        // T6 — plan prettifying: strips LEVEL_, capitalizes; passes through
        // strings without the prefix untouched beyond capitalization.
        expect(UsageFetcher.prettyKimiPlan("LEVEL_INTERMEDIATE") == "Intermediate", "T6 LEVEL_INTERMEDIATE → Intermediate")
        expect(UsageFetcher.prettyKimiPlan("LEVEL_BASIC") == "Basic", "T6 LEVEL_BASIC → Basic")
        expect(UsageFetcher.prettyKimiPlan("pro") == "Pro", "T6 prefix-less value capitalized")

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all tests passed")
    }
}
