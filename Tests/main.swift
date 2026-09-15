import Foundation
import SQLite3

var passed = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { fputs("FAIL: \(label)\n", stderr); exit(1) }
    passed += 1; print("PASS: \(label)")
}
func event(_ kind: String, _ fields: [String: Any] = [:]) -> Data {
    var payload = fields; payload["type"] = kind
    let object: [String: Any] = ["type": "event_msg", "timestamp": "2026-09-15T00:00:00.000Z", "payload": payload]
    var data = try! JSONSerialization.data(withJSONObject: object); data.append(10); return data
}
func count(_ input: Int, _ output: Int, _ cached: Int = 0, written: Int? = 0) -> Data {
    var tokens: [String: Any] = ["input_tokens": input, "output_tokens": output, "cached_input_tokens": cached, "reasoning_output_tokens": 5]
    if let written { tokens["cache_write_input_tokens"] = written }
    return event("token_count", ["info": ["total_token_usage": tokens, "last_token_usage": tokens]])
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-usage-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let log = directory.appendingPathComponent("rollout.jsonl")
try Data().write(to: log)
func append(_ data: Data) { let f = try! FileHandle(forWritingTo: log); try! f.seekToEnd(); try! f.write(contentsOf: data); try! f.close() }
let reader = UsageReader(path: log.path)
append(event("task_started")); append(count(1000, 100, 600))
var s = reader.poll()
check(s.total?.input == 1000 && s.round?.input == 1000, "first turn starts at zero")
append(count(1000, 100, 600)); s = reader.poll()
check(s.total?.input == 1000 && s.round?.input == 1000, "duplicate cumulative snapshots do not double count")
append(event("task_complete")); append(event("task_started")); s = reader.poll()
check(s.round?.input == 0 && s.last == nil && s.running, "new turn resets round and recent-call display")
append(count(1600, 160, 900)); s = reader.poll()
check(s.round?.input == 600 && s.round?.output == 60 && s.round?.cached == 300, "round uses cumulative delta")
check(s.total?.hitRate == 56.25, "cache hit rate uses input denominator")
append(event("task_complete")); check(!reader.poll().running, "completion clears running state")
append(count(1800, 180, 1000, written: nil)); s = reader.poll()
check(s.total?.written == nil && Metric.written.value(s.total) == "—", "missing cache writes are unknown, never zero")
append(count(1900, 190, 1100, written: 0)); s = reader.poll()
check(s.total?.written == 0 && Metric.written.value(s.total) == "0", "explicit zero stays zero")
let next = count(2000, 200, 1200)
append(next.prefix(next.count / 2)); s = reader.poll()
check(s.total?.input == 1900, "incomplete JSON line is held until complete")
append(next.suffix(next.count - next.count / 2)); s = reader.poll()
check(s.total?.input == 2000, "split append is decoded once complete")
append(Data("broken json\n".utf8)); append(count(2100, 210, 1200)); s = reader.poll()
check(s.total?.input == 2100, "malformed line does not block later accounting")
append(event("token_count", ["info": NSNull(), "rate_limits": ["limit_id": "codex", "plan_type": "pro", "primary": ["used_percent": 46.0, "window_minutes": 10080, "resets_at": 1893456000.0], "secondary": NSNull()]])); s = reader.poll()
check(s.total?.input == 2100 && s.windows.first?.remaining == 54 && s.windows.first?.label == "每周额度", "quota-only event preserves tokens and reads window duration")
append(event("token_count", ["info": NSNull(), "rate_limits": ["limit_id": "other", "primary": ["used_percent": 99.0]]])); s = reader.poll()
check(s.windows.first?.remaining == 54, "other quota buckets cannot overwrite Codex quota")
append(event("task_started")); append(count(50, 5)); s = reader.poll()
check(s.round?.input == nil, "counter reset cannot produce negative or invented round usage")
try (event("task_started") + count(20, 2)).write(to: log, options: .atomic); s = reader.poll()
check(s.total?.input == 20 && s.round?.input == 20, "file replacement starts a fresh reader")
let tailLog = directory.appendingPathComponent("tail.jsonl")
try (Data(repeating: 32, count: 800) + Data([10]) + count(9000, 900)).write(to: tailLog)
let tail = UsageReader(path: tailLog.path, initialBytes: 600).poll()
check(tail.total?.input == 9000 && tail.round == nil && tail.partialHistory, "bounded history shows total but unknown turn without boundary")
try FileManager.default.removeItem(at: log)
s = reader.poll()
check(s.error != nil && s.total?.input == 20, "missing log keeps last snapshot with explicit error")
check(Tokens(input: 0, cached: 0).hitRate == nil, "zero input has no invented hit rate")
check(Tokens(input: 10, cached: 20).hitRate == nil, "inconsistent cache ratio is unknown")
var db: OpaquePointer?
check(sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK, "create isolated task index")
sqlite3_exec(db, "CREATE TABLE threads (id TEXT, name TEXT, title TEXT, rollout_path TEXT); INSERT INTO threads VALUES ('a','任务甲','first','/tmp/a'),('b','任务乙','second','/tmp/b');", nil, nil, nil)
let store = ThreadStore(home: directory)
check(FocusReport.resolve(title: "任务甲", store: store).thread?.id == "a", "visible title selects task A")
check(FocusReport.resolve(title: "任务乙", store: store).thread?.id == "b", "changed title selects task B")
check(FocusReport.resolve(title: "不存在", store: store).status == "unmatched", "unknown visible title never chooses recent task")
check(FocusReport.resolve(title: "ChatGPT", store: store).thread == nil, "generic home title has no selected task")
sqlite3_exec(db, "INSERT INTO threads VALUES ('c','任务甲','third','/tmp/c');", nil, nil, nil)
check(FocusReport.resolve(title: "任务甲", store: store).status == "ambiguous", "duplicate title is rejected instead of guessing")
check(FocusReport.resolve(title: "任务乙' OR 1=1 --", store: store).thread == nil, "title is a bound value, not SQL")
sqlite3_close(db)
let oldSettings = Data("{\"onlyCodex\":false,\"metrics\":[\"output\"],\"compact\":\"totalOutput\",\"accent\":\"rose\",\"x\":120,\"y\":150}".utf8)
let migrated = try! JSONDecoder().decode(Settings.self, from: oldSettings)
check((migrated.autoFollow ?? true) && !migrated.onlyCodex && migrated.x == 120 && migrated.metrics == [.output], "auto-follow defaults on while preserving old preferences")
print("\(passed) accounting checks passed")
