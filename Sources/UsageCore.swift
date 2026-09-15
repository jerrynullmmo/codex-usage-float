import Foundation
import SQLite3

// Counters are snapshots, not additive events. Missing counters stay unknown.
struct Tokens: Codable, Equatable {
    var input: Int64?
    var output: Int64?
    var cached: Int64?
    var written: Int64?
    var reasoning: Int64?
    static let zero = Tokens(input: 0, output: 0, cached: 0, written: 0, reasoning: 0)
    init(input: Int64? = nil, output: Int64? = nil, cached: Int64? = nil, written: Int64? = nil, reasoning: Int64? = nil) {
        self.input = input; self.output = output; self.cached = cached; self.written = written; self.reasoning = reasoning
    }
    init(_ d: [String: Any]) {
        func value(_ k: String) -> Int64? { (d[k] as? NSNumber).flatMap { $0.int64Value >= 0 ? $0.int64Value : nil } }
        input = value("input_tokens"); output = value("output_tokens")
        cached = value("cached_input_tokens"); written = value("cache_write_input_tokens")
        reasoning = value("reasoning_output_tokens")
    }
    func subtracting(_ old: Tokens) -> Tokens {
        func delta(_ a: Int64?, _ b: Int64?) -> Int64? {
            guard let a, let b, a >= b else { return nil }; return a - b
        }
        return Tokens(input: delta(input, old.input), output: delta(output, old.output),
                      cached: delta(cached, old.cached), written: delta(written, old.written), reasoning: delta(reasoning, old.reasoning))
    }
    var hitRate: Double? {
        guard let input, let cached, input > 0, cached <= input else { return nil }
        return Double(cached) / Double(input) * 100
    }
}

struct QuotaWindow: Codable, Equatable {
    var used: Double
    var minutes: Int
    var resets: Double?
    var remaining: Double { max(0, min(100, 100 - used)) }
    var label: String {
        if minutes == 10080 { return "每周额度" }
        if minutes % 1440 == 0 && minutes > 0 { return "\(minutes / 1440) 天额度" }
        if minutes % 60 == 0 && minutes > 0 { return "\(minutes / 60) 小时额度" }
        return minutes > 0 ? "\(minutes) 分钟额度" : "套餐额度"
    }
}

struct UsageSnapshot: Codable {
    var total: Tokens?
    var last: Tokens?
    var baseline: Tokens?
    var hasTurn = false
    var running = false
    var updatedAt: String?
    var quotaUpdatedAt: String?
    var windows: [QuotaWindow] = []
    var plan: String?
    var contextWindow: Int64?
    var partialHistory = false
    var error: String?
    var round: Tokens? {
        guard hasTurn, let total, let baseline else { return nil }
        return total.subtracting(baseline)
    }
}

final class UsageReader {
    private(set) var snapshot = UsageSnapshot()
    private var offset: UInt64 = 0
    private var buffer = Data()
    private var droppingLine = false
    private var fileIdentity: UInt64?
    private var initialized = false
    let path: String
    // Read a bounded tail on first attachment; do not scan huge conversation bodies.
    let initialBytes: UInt64
    init(path: String, initialBytes: UInt64 = 8 * 1024 * 1024) { self.path = path; self.initialBytes = initialBytes }
    func poll() -> UsageSnapshot {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let identity = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
            if !initialized || size < offset || identity != fileIdentity {
                snapshot = UsageSnapshot(); buffer.removeAll(); fileIdentity = identity
                offset = size > initialBytes ? size - initialBytes : 0
                droppingLine = offset > 0; snapshot.partialHistory = offset > 0; initialized = true
                // A complete history starts at zero; a truncated tail must not invent a baseline.
                snapshot.baseline = offset == 0 ? .zero : nil
            }
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? file.close() }
            try file.seek(toOffset: offset)
            var remaining = min(size - offset, 16 * 1024 * 1024)
            while remaining > 0 {
                let data = try file.read(upToCount: Int(min(remaining, 128 * 1024))) ?? Data()
                if data.isEmpty { break }
                offset += UInt64(data.count); remaining -= UInt64(data.count)
                ingest(data)
            }
            snapshot.error = nil
        } catch { snapshot.error = "暂时无法读取所选任务的本地记录" }
        return snapshot
    }
    func ingest(_ bytes: Data) {
        for chunk in bytes.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
            if chunk.offset > 0 {
                if !droppingLine { processLine(buffer) }
                buffer.removeAll(keepingCapacity: true); droppingLine = false
            }
            if !droppingLine {
                buffer.append(contentsOf: chunk.element)
                // Tool output lines can be enormous. They contain no usable accounting event.
                if buffer.count > 2 * 1024 * 1024 { buffer.removeAll(keepingCapacity: false); droppingLine = true }
            }
        }
    }
    private func processLine(_ line: Data) {
        guard line.range(of: Data("\"event_msg\"".utf8)) != nil || line.range(of: Data("\"turn_context\"".utf8)) != nil,
              let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let p = d["payload"] as? [String: Any] else { return }
        if d["type"] as? String == "turn_context" { return }
        guard d["type"] as? String == "event_msg" else { return }
        let kind = p["type"] as? String
        if kind == "task_started" {
            snapshot.baseline = snapshot.total ?? (snapshot.partialHistory ? nil : .zero)
            snapshot.hasTurn = true; snapshot.running = true; snapshot.last = nil
            snapshot.contextWindow = (p["model_context_window"] as? NSNumber)?.int64Value
        } else if ["task_complete", "task_aborted", "turn_aborted"].contains(kind ?? "") {
            snapshot.running = false
        } else if kind == "token_count" {
            if let info = p["info"] as? [String: Any] {
                if let t = info["total_token_usage"] as? [String: Any] { snapshot.total = Tokens(t) }
                if let t = info["last_token_usage"] as? [String: Any] { snapshot.last = Tokens(t) }
                snapshot.contextWindow = (info["model_context_window"] as? NSNumber)?.int64Value ?? snapshot.contextWindow
                snapshot.updatedAt = d["timestamp"] as? String
            }
            if let limits = p["rate_limits"] as? [String: Any],
               (limits["limit_id"] as? String == "codex" || limits["limit_id"] == nil) {
                snapshot.windows = ["primary", "secondary"].compactMap { key in
                    guard let w = limits[key] as? [String: Any], let used = w["used_percent"] as? Double, used.isFinite else { return nil }
                    return QuotaWindow(used: used, minutes: w["window_minutes"] as? Int ?? 0, resets: w["resets_at"] as? Double)
                }
                snapshot.plan = limits["plan_type"] as? String
                snapshot.quotaUpdatedAt = d["timestamp"] as? String
            }
        }
    }
}

struct ThreadEntry: Codable, Equatable {
    let id: String
    let title: String
    let path: String
}

struct ThreadStore {
    let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) { self.home = home }
    func read(id: String? = nil, exactTitle: String? = nil) -> [ThreadEntry] {
        let databases = ((try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
        guard let path = databases.first?.path else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 150)
        let query = "SELECT id, COALESCE(NULLIF(name,''), title), rollout_path FROM threads " +
            (id != nil ? "WHERE id = ?" : (exactTitle != nil ? "WHERE COALESCE(NULLIF(name,''), title) = ? LIMIT 2" : "WHERE archived = 0 AND (agent_path IS NULL OR agent_path = '/root') ORDER BY updated_at DESC LIMIT 40"))
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        if let value = id ?? exactTitle { _ = value.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
        var entries: [ThreadEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func str(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
            let name = str(1).replacingOccurrences(of: "\n", with: " ")
            entries.append(ThreadEntry(id: str(0), title: String(name.prefix(100)), path: str(2)))
        }
        return entries
    }
}

enum Metric: String, Codable, CaseIterable {
    case input, output, cached, written, reasoning, hitRate
    var label: String {
        switch self {
        case .input: return "输入"; case .output: return "输出"; case .cached: return "缓存读取"
        case .written: return "缓存写入"; case .reasoning: return "推理输出"; case .hitRate: return "缓存命中"
        }
    }
    func value(_ tokens: Tokens?) -> String {
        guard let tokens else { return "—" }
        if self == .hitRate { return tokens.hitRate.map { String(format: "%.1f%%", $0) } ?? "—" }
        let n: Int64?
        switch self {
        case .input: n = tokens.input; case .output: n = tokens.output; case .cached: n = tokens.cached
        case .written: n = tokens.written; case .reasoning: n = tokens.reasoning; case .hitRate: n = nil
        }
        return n.map { NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal) } ?? "—"
    }
}

struct Settings: Codable {
    // Optional so existing preferences migrate without losing position or metric choices.
    var autoFollow: Bool?
    var threadID: String?
    var onlyCodex = true
    var metrics = Metric.allCases
    var compact = "quota"
    var accent = "mint"
    var x: Double?
    var y: Double?
    static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Usage Float") }
    static var url: URL { directory.appendingPathComponent("settings.json") }
    static func load() -> Settings { (try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))) ?? Settings() }
    func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }
}
