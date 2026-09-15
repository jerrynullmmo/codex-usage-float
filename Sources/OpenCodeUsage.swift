import Foundation
import SQLite3

// Read only metadata and accounting columns; never read credential/account tables or message bodies.
final class UsageDatabase {
    private var db: OpaquePointer?
    init(path: String) throws {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil; throw CocoaError(.fileReadUnknown)
        }
        sqlite3_busy_timeout(db, 150)
    }
    deinit { sqlite3_close(db) }
    func rows(_ query: String, _ bindings: [String] = []) throws -> [[String: String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in bindings.enumerated() {
            _ = value.withCString { sqlite3_bind_text(stmt, Int32(i + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        var result: [[String: String]] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW, result.count < 50000 else { throw CocoaError(.fileReadTooLarge) }
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                if let value = sqlite3_column_text(stmt, i) { row[String(cString: sqlite3_column_name(stmt, i))] = String(cString: value) }
            }
            result.append(row)
        }
    }
}

struct OpenCodeStore {
    var path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db").path
    func read(id: String? = nil, exactTitle: String? = nil) -> [ThreadEntry] {
        guard let db = try? UsageDatabase(path: path), let rows = try? db.rows(
            "SELECT id,title FROM session " + (id != nil ? "WHERE id = ?" : exactTitle != nil ? "WHERE title = ? LIMIT 2" : "WHERE parent_id IS NULL AND time_archived IS NULL ORDER BY time_updated DESC LIMIT 40"),
            (id ?? exactTitle).map { [$0] } ?? []) else { return [] }
        return rows.compactMap { r in r["id"].map { ThreadEntry(id: $0, title: r["title"] ?? $0, path: path, source: "opencode") } }
    }
}

final class OpenCodeReader: SnapshotReader {
    let root: ThreadEntry
    let includeChildren: Bool
    init(root: ThreadEntry, includeChildren: Bool = true) { self.root = root; self.includeChildren = includeChildren }
    static func tokens(_ data: [String: Any]) -> Tokens {
        func number(_ v: Any?) -> Int64? { (v as? NSNumber).flatMap { $0.int64Value >= 0 ? $0.int64Value : nil } }
        let cache = data["cache"] as? [String: Any] ?? [:]
        let base = Tokens(input: number(data["input"]), output: number(data["output"]), cached: number(cache["read"]), written: number(cache["write"]), reasoning: number(data["reasoning"]))
        // OpenCode excludes cache from input and reasoning from output. Normalize to inclusive counters.
        let input = Tokens(input: base.input).adding(Tokens(input: base.cached)).adding(Tokens(input: base.written)).input
        let output = Tokens(output: base.output).adding(Tokens(output: base.reasoning)).output
        return Tokens(input: input, output: output, cached: base.cached, written: base.written, reasoning: base.reasoning)
    }
    func poll() -> UsageSnapshot {
        var result = UsageSnapshot(); result.sourceName = "OpenCode"
        result.scopeNote = "本地消息记录；未提供套餐额度。"
        do {
            let db = try UsageDatabase(path: root.path)
            _ = try db.rows("BEGIN")
            defer { _ = try? db.rows("ROLLBACK") }
            let sessions = try db.rows(includeChildren ? """
                WITH RECURSIVE family(id) AS (SELECT ? UNION SELECT s.id FROM session s JOIN family f ON s.parent_id=f.id)
                SELECT s.id,s.title FROM session s JOIN family f ON s.id=f.id
                """ : "SELECT id,title FROM session WHERE id = ?", [root.id])
            guard sessions.contains(where: { $0["id"] == root.id }) else { throw CocoaError(.fileNoSuchFile) }
            var messages: [String: [[String: String]]] = [:]
            for s in sessions {
                let id = s["id"]!
                messages[id] = try db.rows("""
                    SELECT id, json_extract(data,'$.role') AS role, json_extract(data,'$.tokens') AS tokens,
                    json_extract(data,'$.time.created') AS created, json_extract(data,'$.time.completed') AS completed,
                    json_extract(data,'$.parentID') AS parent FROM message WHERE session_id = ? ORDER BY time_created,id
                    """, [id])
            }
            let rootMessages = messages[root.id] ?? []
            let user = rootMessages.last(where: { $0["role"] == "user" })
            let boundary = user?["created"].flatMap(Double.init)
            result.hasTurn = user != nil
            result.turnStartedAt = boundary.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0 / 1000)) }
            var total = Tokens.zero; var round = Tokens.zero
            for session in sessions {
                let id = session["id"]!
                var ownTotal = Tokens.zero; var ownRound = Tokens.zero
                for message in messages[id] ?? [] where message["role"] == "assistant" {
                    let decoded = message["tokens"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
                    let value = decoded.map(Self.tokens) ?? Tokens()
                    ownTotal = ownTotal.adding(value)
                    let created = message["created"].flatMap(Double.init)
                    // Root parentID is stronger than time; child calls use the root time boundary.
                    let inRound: Bool?
                    if id == root.id {
                        inRound = message["parent"].flatMap { parent in user?["id"].map { parent == $0 } }
                    } else {
                        inRound = created.flatMap { time in boundary.map { time >= $0 } }
                    }
                    if inRound == true { ownRound = ownRound.adding(value) }
                    if inRound == nil { ownRound = Tokens() }
                    if id == root.id, inRound != false { result.last = inRound == true ? value : nil }
                    if message["completed"] == nil && inRound == true { result.running = true }
                    if let time = (message["completed"] ?? message["created"]).flatMap(Double.init) {
                        let date = Date(timeIntervalSince1970: time / 1000)
                        if date > (usageDate(result.updatedAt) ?? .distantPast) { result.updatedAt = ISO8601DateFormatter().string(from: date) }
                    }
                }
                result.members.append(UsageMember(id: id, title: session["title"] ?? id, total: ownTotal, round: boundary == nil ? nil : ownRound))
                total = total.adding(ownTotal); round = round.adding(ownRound)
            }
            result.total = total; result.aggregated = true; result.aggregateRound = boundary == nil ? nil : round
            result.scopeNote = "含 \(sessions.count - 1) 个子代理；最近调用仅指主任务。"
        } catch { result.error = "无法完整读取 OpenCode 本地计量记录" }
        return result
    }
}
