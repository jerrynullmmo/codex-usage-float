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


// Root-window accounting across descendants, including grandchildren, duplicates and cycles.
func at(_ time: String, _ bytes: Data) -> Data {
    Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "2026-09-15T00:00:00.000Z", with: time).utf8)
}
let before = "2026-09-14T23:00:00.000Z"
let after = "2026-09-15T01:00:00.000Z"
let rootLog = directory.appendingPathComponent("root.jsonl")
let childLog = directory.appendingPathComponent("child.jsonl")
let grandLog = directory.appendingPathComponent("grand.jsonl")
try (at(before, event("task_started") + count(100, 10)) + event("task_started") + at(after, count(400, 40))).write(to: rootLog)
try (at(before, event("task_started") + count(200, 20)) + event("task_started") + at(after, count(350, 35) + event("task_complete") + event("task_started") + count(500, 50) + count(500, 50))).write(to: childLog)
try (at(after, event("task_started") + count(50, 5))).write(to: grandLog)
check(sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK, "open family fixture index")
sqlite3_exec(db, "CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT,status TEXT);", nil, nil, nil)
func insertThread(_ id: String, _ path: String) {
    sqlite3_exec(db, "INSERT INTO threads (id,name,title,rollout_path) VALUES ('\(id)','\(id)','\(id)','\(path)');", nil, nil, nil)
}
insertThread("root", rootLog.path); insertThread("child", childLog.path); insertThread("grand", grandLog.path)
sqlite3_exec(db, "INSERT INTO thread_spawn_edges VALUES ('root','child','closed'),('child','grand','open'),('grand','child','open');", nil, nil, nil)
let familyRoot = ThreadEntry(id: "root", title: "root", path: rootLog.path)
let family = CodexFamilyReader(root: familyRoot, store: store)
var familySnapshot = family.poll()
check(familySnapshot.total?.input == 950 && familySnapshot.members.count == 3, "sum own counters once across closed child and cyclic grandchild relation")
check(familySnapshot.round?.input == 650, "all child followups use root turn boundary, not child last-turn baseline")
check(familySnapshot.last?.input == 400, "aggregate leaves root last call separate")
check(CodexFamilyReader(root: familyRoot, store: store, includeChildren: false).poll().total?.input == 400, "root-only option excludes child counters")
sqlite3_exec(db, "INSERT INTO thread_spawn_edges VALUES ('root','missing','open');", nil, nil, nil)
familySnapshot = family.poll()
check(familySnapshot.total?.input == nil && familySnapshot.error != nil && familySnapshot.members.count == 4, "missing descendant makes full sum unknown with visible coverage")
sqlite3_exec(db, "DELETE FROM thread_spawn_edges WHERE child_thread_id='missing';", nil, nil, nil)
try FileManager.default.removeItem(at: rootLog)
familySnapshot = family.poll()
check(familySnapshot.total?.input == nil && familySnapshot.round == nil && familySnapshot.error != nil, "unreadable root cannot mix stale parent with fresh child usage")
sqlite3_close(db)
check(Tokens(input: Int64.max).adding(Tokens(input: 1)).input == nil, "overflow is unknown instead of crashing")

// OpenCode uses disjoint cache/reasoning counters, so normalization must happen before summing.
let normalized = OpenCodeReader.tokens(["input": 3860, "output": 77, "reasoning": 17, "cache": ["read": 8192, "write": 0]])
check(normalized.input == 12052 && normalized.output == 94 && normalized.cached == 8192, "OpenCode inclusive normalization matches total 12146")
let ocPath = directory.appendingPathComponent("opencode.db").path
sqlite3_open(ocPath, &db)
sqlite3_exec(db, "CREATE TABLE session(id TEXT,title TEXT,parent_id TEXT,time_archived INTEGER,time_updated INTEGER); CREATE TABLE message(id TEXT,session_id TEXT,time_created INTEGER,data TEXT); INSERT INTO session VALUES('oroot','Open root',NULL,NULL,1),('och','Open child','oroot',1,1);", nil, nil, nil)
func ocMessage(_ id: String, _ session: String, _ time: Int, _ role: String, parent: String? = nil, tokens: [String: Any]? = nil) {
    var d: [String: Any] = ["role":role,"time":["created":time,"completed":time + 1]]
    d["parentID"] = parent; d["tokens"] = tokens
    let json = String(decoding: try! JSONSerialization.data(withJSONObject: d), as: UTF8.self)
    var stmt: OpaquePointer?; sqlite3_prepare_v2(db, "INSERT INTO message VALUES (?,?,?,?)", -1, &stmt, nil)
    for (i,v) in [id,session,String(time),json].enumerated() { _ = v.withCString { sqlite3_bind_text(stmt,Int32(i+1),$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)) } }
    sqlite3_step(stmt); sqlite3_finalize(stmt)
}
let ot: [String:Any] = ["input":100,"output":10,"reasoning":5,"cache":["read":20,"write":30]]
ocMessage("u0","oroot",100,"user"); ocMessage("a0","oroot",110,"assistant",parent:"u0",tokens:ot)
ocMessage("c0","och",120,"assistant",tokens:ot)
ocMessage("u1","oroot",200,"user"); ocMessage("a1","oroot",210,"assistant",parent:"u1",tokens:ot)
ocMessage("c1","och",220,"assistant",tokens:ot)
sqlite3_close(db)
let os = OpenCodeReader(root: ThreadEntry(id:"oroot",title:"Open root",path:ocPath,source:"opencode")).poll()
check(os.total?.input == 600 && os.total?.output == 60, "OpenCode aggregates root plus archived child")
check(os.round?.input == 300 && os.last?.input == 150 && os.members.count == 2, "OpenCode root user message sets shared round boundary")
sqlite3_open(ocPath, &db)
sqlite3_exec(db, "UPDATE message SET data=json_remove(data,'$.time.created') WHERE id='c1';", nil, nil, nil)
var missingOC = OpenCodeReader(root: ThreadEntry(id:"oroot",title:"Open root",path:ocPath,source:"opencode")).poll()
check(missingOC.round?.input == nil && missingOC.total?.input == 600, "missing child timestamp keeps OpenCode round unknown while preserving total")
sqlite3_exec(db, "UPDATE message SET data=json_remove(data,'$.parentID') WHERE id='a1';", nil, nil, nil)
missingOC = OpenCodeReader(root: ThreadEntry(id:"oroot",title:"Open root",path:ocPath,source:"opencode"),includeChildren:false).poll()
check(missingOC.round?.input == nil && missingOC.last == nil, "missing root message parent cannot invent a zero round")
sqlite3_close(db)
check(OpenCodeStore(path:ocPath).read(exactTitle:"Open root").first?.id == "oroot", "OpenCode exact unique title selection")

// A generic local bridge must select by explicit active ID and reject stale or malformed data.
let bridgeDir = directory.appendingPathComponent("adapters")
try FileManager.default.createDirectory(at: bridgeDir, withIntermediateDirectories:true)
let bridgeURL = bridgeDir.appendingPathComponent("example.json")
let nowISO = ISO8601DateFormatter().string(from:Date())
var bridge = UsageBridge(schemaVersion:1,id:"example",name:"Example Desktop",bundleIDs:["org.example.desktop"],updatedAt:nowISO,activeSessionID:"br",sessions:[
    BridgeSession(id:"br",title:"Example root",total:Tokens(input:100,output:10),last:Tokens(input:5),round:Tokens(input:30),roundStartedAt:nowISO),
    BridgeSession(id:"bc",title:"Example child",parentID:"br",total:Tokens(input:50,output:5),round:Tokens(input:20),roundStartedAt:nowISO)
])
bridge.childrenComplete = true
func saveBridge() { try! JSONEncoder().encode(bridge).write(to:bridgeURL,options:.atomic) }
saveBridge()
let catalog = UsageSources(bridgeDirectory:bridgeDir)
let bf = catalog.bridgeFocus(bundle:"org.example.desktop")!
check(bf.thread?.id == "br" && bf.status == "bridge", "new software follows explicit active session without changing monitor code")
let bs = BridgeReader(entry:bf.thread!,includeChildren:true).poll()
check(bs.total?.input == 150 && bs.round?.input == 50 && bs.last?.input == 5, "bridge sums own task counters and shared-boundary round")
bridge.childrenComplete = false; saveBridge()
check(BridgeReader(entry:bf.thread!,includeChildren:true).poll().total == nil, "bridge requires child completeness before presenting full sum")
bridge.childrenComplete = true; bridge.activeSessionID = "bc"; saveBridge()
check(catalog.bridgeFocus(bundle:"org.example.desktop")?.thread?.id == "bc", "bridge follows conversation change")
bridge.sessions[1].roundStartedAt = before; saveBridge()
check(BridgeReader(entry:bf.thread!,includeChildren:true).poll().round?.input == nil, "bridge rejects incomparable child round boundary")
bridge.updatedAt = before; saveBridge()
check(catalog.bridgeFocus(bundle:"org.example.desktop")?.thread == nil, "stopped bridge cannot retain stale active task")
bridge.updatedAt = nowISO; bridge.sessions[0].total?.input = -1; saveBridge()
check(UsageBridge.read(bridgeURL) == nil, "negative bridge counters reject snapshot")
bridge.sessions[0].total?.input = 100; bridge.sessions.append(bridge.sessions[0]); saveBridge()
check(UsageBridge.read(bridgeURL) == nil, "duplicate bridge task IDs reject snapshot")
bridge.sessions.removeLast(); bridge.bundleIDs = []; bridge.processNames = ["ExampleDesktop.exe"]; saveBridge()
check(UsageBridge.read(bridgeURL) != nil, "Windows-only bridge uses same schema with empty macOS bundle list")
print("\(passed) accounting checks passed")

// Price arithmetic is verified against independent hand calculations for multiple vendors.
let book = PriceBook(url: directory.appendingPathComponent("no-custom-prices.json"))
check(book.document?.models.count == 50, "shared multi-provider official price catalog loads")
let pricedTokens = Tokens(input: 100000, output: 1000, cached: 60000, written: 10000, reasoning: 800)
let astra = book.quote(pricedTokens, model: "gpt-6-astra")
check(astra.complete && abs(astra.usd - 0.535) < 0.00000001, "OpenAI cache writes replace input charge; reasoning not charged twice")
let claude = book.quote(pricedTokens, model: "claude-sonnet-5", provider: "anthropic")
check(claude.complete && abs(claude.usd - 0.107) < 0.00000001, "Anthropic own write/read/output prices")
let gemini = book.quote(pricedTokens, model: "gemini-2.5-flash", provider: "google")
check(gemini.complete && abs(gemini.usd - 0.0163) < 0.00000001, "Gemini paid token reference excludes storage fees")
let deepseek = book.quote(pricedTokens, model: "deepseek-flash", provider: "deepseek")
check(deepseek.complete && abs(deepseek.usd - 0.01356) < 0.00000001, "DeepSeek own peak reference rate")
check(!book.quote(pricedTokens, model: "unverified-model").complete, "unknown models never borrow OpenAI prices")
check(!book.quote(pricedTokens, model: "gpt-6-astra", provider: "anthropic").complete, "explicit known provider cannot select another provider price")
check(!book.quote(Tokens(input: 100, output: 1, cached: 10), model: "gpt-6-astra").complete, "unknown paid cache write tokens cannot be assumed zero")
check(book.quote(Tokens(input: 100, output: 1, cached: 10), model: "gpt-4.1").complete, "no separate cache write rate allows missing writes")
check(!book.quote(Tokens(input: 100, output: 1, cached: 90, written: 20), model: "gpt-6-astra").complete, "overlapping cache categories reject impossible usage")
let longPrice = book.quote(Tokens(input: 300000, output: 1000, cached: 0, written: 0), model: "gpt-6-astra")
check(abs(longPrice.usd - 6.075) < 0.00000001, "long context uses per-request input threshold and all long rates")
func pricingContext(_ model: String) -> Data {
    let object: [String: Any] = ["type": "turn_context", "payload": ["model": model]]
    return try! JSONSerialization.data(withJSONObject: object) + Data([10])
}
func pricedCount(_ total: Tokens, _ last: Tokens) -> Data {
    func raw(_ t: Tokens) -> [String: Int64] { ["input_tokens":t.input!,"output_tokens":t.output!,"cached_input_tokens":t.cached!,"cache_write_input_tokens":t.written!] }
    return event("token_count", ["info": ["total_token_usage":raw(total),"last_token_usage":raw(last)]])
}
let costFile = directory.appendingPathComponent("costs.jsonl")
let firstCost = event("task_started") + pricingContext("gpt-6-astra") + pricedCount(pricedTokens, pricedTokens)
try firstCost.write(to: costFile)
let costReader = UsageReader(path: costFile.path)
var priced = costReader.poll()
check(priced.costTotal?.complete == true && abs(priced.costTotal!.usd - 0.535) < 0.00000001, "full log metadata generates usable API estimate")
let costHandle = try! FileHandle(forWritingTo: costFile); try! costHandle.seekToEnd()
try! costHandle.write(contentsOf: pricedCount(pricedTokens, pricedTokens))
try! costHandle.write(contentsOf: event("task_started") + pricingContext("claude-sonnet-5") + pricedCount(pricedTokens.adding(pricedTokens), pricedTokens)); try! costHandle.close()
priced = costReader.poll()
check(abs(priced.costTotal!.usd - 0.642) < 0.00000001 && abs(priced.costRound!.usd - 0.107) < 0.00000001, "model switch prices each call once and resets round cost")
check(priced.costTotal?.models.count == 2, "mixed-model total keeps attribution")
let partialCost = APICost(usd: 1).adding(.unknown("unknown model"))
check(!partialCost.complete && partialCost.label.contains(" + ?"), "partial subtotal is never presented as a complete bill")
let smallTail = UsageReader(path: costFile.path, initialBytes: 100).poll()
check(smallTail.partialHistory && smallTail.costTotal?.complete == true, "cost replay recovers full history beyond token display tail")
print("\(passed) total accounting and pricing checks passed")

let pricedRoot = directory.appendingPathComponent("priced-root.jsonl")
let pricedChild = directory.appendingPathComponent("priced-child.jsonl")
try (at(before, firstCost) + event("task_started") + pricingContext("gpt-6-astra") + at(after, pricedCount(pricedTokens.adding(pricedTokens), pricedTokens))).write(to: pricedRoot)
try (at(before, event("task_started") + pricingContext("claude-sonnet-5") + pricedCount(pricedTokens, pricedTokens)) + at(after, event("task_started") + pricingContext("claude-sonnet-5") + pricedCount(pricedTokens.adding(pricedTokens), pricedTokens))).write(to: pricedChild)
check(sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK, "open priced family fixture")
sqlite3_exec(db, "INSERT INTO threads VALUES ('priced-root','p','p','\(pricedRoot.path)'),('priced-child','c','c','\(pricedChild.path)'); INSERT INTO thread_spawn_edges VALUES ('priced-root','priced-child','closed');", nil, nil, nil)
sqlite3_close(db)
let pricedFamily = CodexFamilyReader(root: ThreadEntry(id: "priced-root", title: "p", path: pricedRoot.path), store: store).poll()
check(pricedFamily.costTotal?.complete == true && abs(pricedFamily.costTotal!.usd - 1.284) < 0.00000001, "mixed-provider child costs sum once")
check(abs(pricedFamily.costRound!.usd - 0.642) < 0.00000001 && abs(pricedFamily.costLast!.usd - 0.535) < 0.00000001, "child cost uses root boundary while recent cost stays root-only")
print("\(passed) final checks passed")

// Overview must enumerate the full catalog and sum individual sessions, never recursive families.
sqlite3_open(directory.appendingPathComponent("state_5.sqlite").path, &db)
sqlite3_exec(db, "ALTER TABLE threads ADD COLUMN updated_at INTEGER DEFAULT 1; ALTER TABLE threads ADD COLUMN archived INTEGER DEFAULT 1; ALTER TABLE threads ADD COLUMN agent_path TEXT DEFAULT '/root/child';", nil, nil, nil)
for i in 0..<45 { insertThread("archive-\(i)", childLog.path) }
sqlite3_close(db)
let allEntries = try UsageSources(bridgeDirectory: directory.appendingPathComponent("absent")).allEntries(codexHome: directory, openCodePath: ocPath)
check(allEntries.count > 45 && allEntries.contains(where: { $0.id == "och" }), "overview catalog includes all archived children beyond recent 40")
let ae = [ThreadEntry(id:"p",title:"",path:pricedRoot.path),ThreadEntry(id:"c",title:"",path:pricedChild.path)]
let allReader = AllUsageReader(cacheURL:nil,catalog:{ ae + [ae[0]] })
var overviewResult = allReader.poll()
while overviewResult.loaded < overviewResult.count { overviewResult = allReader.poll() }
check(overviewResult.count == 2 && overviewResult.total.input == 400000 && abs(overviewResult.cost.usd - 1.284) < 0.00000001, "all-task total deduplicates sessions and includes mixed-provider child costs once")
let allAgain = allReader.poll(force:true)
check(allAgain.total == overviewResult.total && allAgain.cost.usd == overviewResult.cost.usd, "overview refresh cannot accumulate snapshots twice")
try FileManager.default.removeItem(at: pricedChild)
overviewResult = allReader.poll(force:true)
check(overviewResult.total.input == 200000 && overviewResult.value(.input).contains("+ ?") && !overviewResult.cost.complete, "unreadable history retains marked known subtotal instead of a false complete sum")
let aeOther = ThreadEntry(id:"p",title:"",path:"",source:"bridge:other")
let zeroCache: [String: AllUsageReader.Cached] = ["codex:p": .init(signature:"",tokens:.zero,cost:APICost()), "bridge:other:p": .init(signature:"",tokens:Tokens(input:10,output:5),cost:APICost(usd:2))]
let namespaceResult = AllUsageReader.summarize(entries:[ae[0],aeOther],cache:zeroCache)
check(namespaceResult.count == 2 && namespaceResult.total.input == 10 && namespaceResult.tokenLabel == "15", "source namespace separates equal task IDs and total tokens excludes cache and reasoning")
check(namespaceResult.value(.written).contains("+ ?") && namespaceResult.value(.hitRate) == "—", "unknown metrics remain partial and incomplete cache ratios stay unknown")
check(migrated.notesExpanded == nil && migrated.overview == nil, "new UI preferences preserve old settings with collapsed notes and overview defaults")
print("\(passed) final checks including all-history overview passed")

// Synthetic account responses only; tests never use a real key or contact a provider.
func walletData(_ s: String) -> Data { Data(s.utf8) }
let walletUsage = walletData("{\"object\":\"list\",\"total_usage\":456}")
let walletBudget = walletData("{\"object\":\"billing_subscription\",\"hard_limit_usd\":16.9}")
var walletCalls: [String] = []
let wallet = try YonshoreClient.read { name in walletCalls.append(name); return name == "usage" ? walletUsage : walletBudget }
check(wallet.available == Decimal(string:"12.34") && wallet.spent == Decimal(string:"4.56"), "Yonshore available balance and actual charges use cents exactly")
check(YonshoreWallet.money(wallet.spent) == "$4.56" && YonshoreWallet.money(.zero) == "$0.00" && YonshoreWallet.money(Decimal(string: "-1234.56")) == "$-1,234.56" && YonshoreWallet.money(nil) == "—", "wallet display uses exactly two decimal places and preserves unknown values")
check(walletCalls == ["usage","subscription","usage"], "account balance is bracketed by consumption reads")
var sequence = [walletUsage,walletBudget,walletData("{\"object\":\"list\",\"total_usage\":457}"),walletData("{\"object\":\"list\",\"total_usage\":457}"),walletBudget,walletData("{\"object\":\"list\",\"total_usage\":457}")]
let concurrentWallet = try YonshoreClient.read { _ in sequence.removeFirst() }
check(concurrentWallet.available == Decimal(string:"12.33"), "concurrent settlement retries a consistent snapshot")
check((try? YonshoreClient.usage(walletData("{\"error\":{\"message\":\"synthetic secret never exposed\"}}"))) == nil, "HTTP 200 provider errors are not zero balances")
check((try? YonshoreClient.usage(walletData("{\"object\":\"list\",\"total_usage\":true}"))) == nil, "boolean money is rejected")
check((try? YonshoreClient.usage(walletData("{\"object\":\"list\",\"total_usage\":0.01}"))) == nil, "fractional cents are rejected")
check((try? YonshoreClient.subscription(walletData("{\"object\":\"billing_subscription\",\"hard_limit_usd\":12.345}"))) == nil, "unsupported money precision is rejected")
check((try? yonshoreKey("sk-invalid\r\nkey")) == nil && (try? yonshoreKey("sk-valid-synthetic-key")) != nil, "API key validation rejects whitespace/header injection")
var walletState = YonshoreAccountState();walletState.accept(.success(wallet));walletState.accept(.failure(.authentication))
check(walletState.wallet == wallet && walletState.status.contains("上次成功"), "stale account numbers are explicitly marked after an error")
check(YonshoreAccountState().wallet == nil, "account change begins without another account's figures")
print("\(passed) final accounting and account checks passed")
