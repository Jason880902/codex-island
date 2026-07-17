import Foundation

/// Fixture tests for UsageFetcher.parseClaudeWindow — the pure parse half of
/// the Claude `/api/oauth/usage` integration. The shapes below mirror a real
/// 200 response: `utilization` is a percentage in [0, 100] (NOT a 0–1
/// fraction) and `resets_at` arrives either as an ISO8601 string with
/// fractional seconds or as unix seconds.
@main
struct ClaudeUsageParsingTests {
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
        // T1 — full real-world payload, decoded through JSONSerialization and
        // walked exactly the way fetchClaudeUsage does (obj["five_hour"] /
        // obj["seven_day"]): percent → fraction, ISO resets_at with
        // fractional seconds parses.
        let json = """
        {
          "five_hour": { "utilization": 73.0, "resets_at": "2026-07-17T21:00:00.351169Z" },
          "seven_day": { "utilization": 12.5, "resets_at": "2026-07-24T01:41:57.123456Z" }
        }
        """
        let obj = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let five = UsageFetcher.parseClaudeWindow(obj["five_hour"])
        let seven = UsageFetcher.parseClaudeWindow(obj["seven_day"])
        expect(abs(five.usedPercent - 0.73) < 0.0001, "T1 5h utilization percent → fraction")
        expect(abs(seven.usedPercent - 0.125) < 0.0001, "T1 7d utilization percent → fraction")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        expect(five.resetAt == iso.date(from: "2026-07-17T21:00:00.351169Z"),
               "T1 5h ISO resets_at (fractional seconds) parses")
        expect(seven.resetAt == iso.date(from: "2026-07-24T01:41:57.123456Z"),
               "T1 7d ISO resets_at (fractional seconds) parses")
        expect(five.error == nil && seven.error == nil, "T1 no window errors on a full payload")

        // T2 — resets_at as unix seconds (Double) instead of a string.
        let w2 = UsageFetcher.parseClaudeWindow(["utilization": 40.0, "resets_at": 1_784_320_800.0])
        expect(abs(w2.usedPercent - 0.40) < 0.0001, "T2 percent → fraction")
        expect(w2.resetAt == Date(timeIntervalSince1970: 1_784_320_800), "T2 unix-seconds resets_at parses")

        // T3 — regression: utilization 0.5 is a PERCENT (0.5% used), not an
        // already-normalized fraction. The retired `raw > 1` heuristic
        // rendered this as 50%; always divide by 100.
        let w3 = UsageFetcher.parseClaudeWindow(["utilization": 0.5])
        expect(abs(w3.usedPercent - 0.005) < 0.000001, "T3 0.5% stays 0.005 (divide-by-100 regression)")

        // T4 — five_hour key absent (fresh account / quiet period): the tile
        // must show its passive state (.unknown), not a fabricated 0%.
        let emptyObj = try! JSONSerialization.jsonObject(with: Data("{}".utf8)) as! [String: Any]
        let w4 = UsageFetcher.parseClaudeWindow(emptyObj["five_hour"])
        expect(w4.error == "no data", "T4 missing five_hour yields .unknown")
        expect(w4.usedPercent == 0 && w4.resetAt == nil, "T4 .unknown carries no fabricated data")

        // T5 — window present but utilization missing entirely reads as 0%,
        // and is not an error.
        let w5 = UsageFetcher.parseClaudeWindow(["resets_at": "2026-07-17T21:00:00Z"])
        expect(w5.usedPercent == 0, "T5 missing utilization reads as 0%")
        expect(w5.error == nil, "T5 present-but-empty window is not an error")
        expect(w5.resetAt != nil, "T5 plain (non-fractional) ISO resets_at parses")

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("all tests passed")
    }
}
