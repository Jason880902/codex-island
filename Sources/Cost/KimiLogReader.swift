import Foundation

/// Walks the local Kimi Code session wire logs and emits TokenEvents for
/// every turn that recorded usage. The data path:
///   - reads from ~/.kimi-code/sessions/wd_*/session_*/agents/*/wire.jsonl
///   - honors KIMI_CODE_HOME when set
///   - keeps only `usage.record` rows with `usageScope == "turn"` — one row
///     per API turn, so summing is exact (verified against real logs: every
///     usage.record observed in the wild carries usageScope "turn"). Any
///     future cumulative/session-scoped row is skipped rather than
///     double-counted.
///   - dedupes by content fingerprint (timestamp + model + token counts)
///
/// Per-file parse results are memoized in `~/Library/Caches/.../kimi-parse-cache.v1.json`
/// keyed by (path, mtime, size). Between two 5/15/30-minute polls almost no
/// file has changed, so the steady-state refresh skips the JSONL scan entirely
/// and only walks the events list to dedup + filter by cutoff.
enum KimiLogReader {
    /// Walk the session root and return every usage-bearing turn from the
    /// last `lookbackDays` days. Pure file IO; no network. Safe to call from
    /// a background thread.
    static func scan(lookbackDays: Int = 30) -> [TokenEvent] {
        let cutoff = Date().addingTimeInterval(-Double(lookbackDays) * 86400)
        var seen = Set<String>()
        var out: [TokenEvent] = []

        LogParseCache.walk(
            roots: [sessionsRoot()],
            cutoff: cutoff,
            cacheFilename: "kimi-parse-cache.v1.json",
            cacheVersion: cacheVersion,
            fileFilter: { $0.lastPathComponent == "wire.jsonl" },
            parse: parseFile(at:),
            emit: { (ev: CachedEvent) in
                guard ev.timestamp >= cutoff else { return }
                // Each wire.jsonl logs its own agent's turns, so no cross-file
                // duplication is expected; the fingerprint guard is cheap
                // insurance against a retried write logging the same turn
                // twice. Two genuinely different turns would need the same
                // millisecond AND identical token counts to collide.
                guard seen.insert(ev.fingerprint).inserted else { return }
                out.append(TokenEvent(
                    provider: .kimi,
                    timestamp: ev.timestamp,
                    model: ev.model,
                    inputTokens: ev.inputTokens,
                    outputTokens: ev.outputTokens,
                    cacheCreationTokens: ev.cacheCreationTokens,
                    cacheReadTokens: ev.cacheReadTokens
                ))
            }
        )
        return out
    }

    /// Kimi Code's session root. `KIMI_CODE_HOME` relocates `~/.kimi-code`
    /// (rarely set for a LaunchServices-spawned GUI app, but honored to match
    /// the CLI's resolution — and to let tests point the reader at a fixture).
    private static func sessionsRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let kimiHome = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"], !kimiHome.isEmpty {
            return URL(fileURLWithPath: kimiHome).appendingPathComponent("sessions", isDirectory: true)
        }
        return home.appendingPathComponent(".kimi-code/sessions", isDirectory: true)
    }

    /// Parse a single file end-to-end. Caller is responsible for cutoff
    /// filtering — the cache keeps everything we found so a later scan with
    /// a wider window doesn't have to re-read.
    private static func parseFile(at url: URL) -> [CachedEvent] {
        var out: [CachedEvent] = []
        LogParseCache.streamLines(at: url) { lineData in
            if let event = parseLine(lineData) {
                out.append(event)
            }
        }
        return out
    }

    /// Returns nil for non-usage rows, non-turn scopes, noop usage entries,
    /// and lines that fail to parse. A cheap byte-scan rejects everything
    /// else before paying for JSON parsing — wire files carry multi-KB
    /// prompt/config lines that are never the records we want.
    private static func parseLine(_ lineData: Data) -> CachedEvent? {
        guard lineData.range(of: usageRecordMarker) != nil,
              let raw = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              (raw["type"] as? String) == "usage.record",
              (raw["usageScope"] as? String) == "turn",
              let usage = raw["usage"] as? [String: Any],
              let model = raw["model"] as? String
        else { return nil }

        // `time` is milliseconds since epoch.
        let timeMs = (raw["time"] as? NSNumber)?.doubleValue ?? 0
        let timestamp = timeMs > 0
            ? Date(timeIntervalSince1970: timeMs / 1000.0)
            : Date.distantPast

        let input = (usage["inputOther"] as? Int) ?? 0
        let output = (usage["output"] as? Int) ?? 0
        let cacheCreate = (usage["inputCacheCreation"] as? Int) ?? 0
        let cacheRead = (usage["inputCacheRead"] as? Int) ?? 0

        // Skip noop entries — they add nothing to any total.
        if input == 0 && output == 0 && cacheCreate == 0 && cacheRead == 0 { return nil }

        return CachedEvent(
            timestamp: timestamp,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead
        )
    }

    // MARK: - Per-file cache

    /// Bump on any breaking change to `CachedEvent` to force a clean re-parse.
    private static let cacheVersion = 1

    private static let usageRecordMarker = Data("\"usage.record\"".utf8)

    private struct CachedEvent: Codable {
        let timestamp: Date
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int

        /// Content fingerprint for cross-scan dedup. Millisecond precision
        /// matches the wire format's `time` field, so two records from the
        /// same turn always collide while distinct turns (different ms or
        /// different token counts) never do.
        var fingerprint: String {
            "\(Int64(timestamp.timeIntervalSince1970 * 1000)):\(model):\(inputTokens):\(outputTokens):\(cacheCreationTokens):\(cacheReadTokens)"
        }
    }
}
