import Foundation

// A partial subtotal remains useful, but must never masquerade as the complete bill.
struct APICost: Codable {
    var usd: Double = 0
    var complete = true
    var reasons: [String] = []
    var models: [String] = []
    static func unknown(_ reason: String) -> APICost { APICost(complete: false, reasons: [reason]) }
    func adding(_ other: APICost) -> APICost {
        let value = usd + other.usd
        guard value.isFinite else { return .unknown("费用数值溢出") }
        return APICost(usd: value, complete: complete && other.complete,
                       reasons: Array(Set(reasons + other.reasons)).sorted(), models: Array(Set(models + other.models)).sorted())
    }
    var label: String {
        if !complete && usd == 0 { return "—" }
        return (usd > 0 && usd < 0.0001 ? "<$0.0001" : String(format: "$%.4f", usd)) + (complete ? "" : " + ?")
    }
}

struct APIPrice: Codable {
    var provider: String
    var model: String
    var aliases: [String]
    // USD per million: uncached input, cache read, cache write, inclusive output.
    var rates: [Double?]
    var longRates: [Double?]?
    var threshold: Int64?
    var note: String
    var source: String
}
struct PriceDocument: Codable {
    var schemaVersion: Int
    var currency: String
    var verifiedAt: String
    var models: [APIPrice]
}
final class PriceBook {
    static let shared = PriceBook()
    static var customURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Usage Float/pricing.json")
    }
    let document: PriceDocument?
    let custom: Bool
    init(url: URL? = nil) {
        let local = url ?? Self.customURL
        custom = FileManager.default.fileExists(atPath: local.path)
        let bundled = Bundle.main.url(forResource: "prices", withExtension: "json")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("windows/prices.json")
        let source = custom ? local : bundled
        let data = try? Data(contentsOf: source)
        let value = data.flatMap { $0.count <= 1024 * 1024 ? try? JSONDecoder().decode(PriceDocument.self, from: $0) : nil }
        func valid(_ r: [Double?]) -> Bool { r.count == 4 && r[0] != nil && r[3] != nil && r.allSatisfy { $0.map { $0.isFinite && $0 >= 0 } ?? true } }
        var identities: Set<String> = []
        let validRows = value?.models.allSatisfy { row in
            guard !row.provider.isEmpty, !row.model.isEmpty, row.source.hasPrefix("https://"), valid(row.rates),
                  row.longRates.map(valid) ?? true, (row.longRates == nil) == (row.threshold == nil), row.threshold.map({ $0 > 0 }) ?? true else { return false }
            return ([row.model] + row.aliases).allSatisfy { identities.insert(row.provider + "/" + $0).inserted }
        } ?? false
        document = value?.schemaVersion == 1 && value?.currency == "USD" && validRows ? value : nil
    }
    var label: String { (custom ? "自定义价目" : "官方价目") + " · " + (document?.verifiedAt ?? "无效") }
    func quote(_ tokens: Tokens?, model: String?, provider: String? = nil) -> APICost {
        guard let document else { return .unknown("价目文件缺失或无效") }
        guard let model, !model.isEmpty else { return .unknown("记录未提供模型名称") }
        let provider = provider == "google-generative-ai" ? "google" : provider
        let recognizedProvider = document.models.contains { $0.provider == provider }
        let matches = document.models.filter { row in
            (!recognizedProvider || row.provider == provider) && ([row.model] + row.aliases).contains(model)
        }
        guard matches.count == 1, let row = matches.first else { return .unknown("价格未知：" + model) }
        guard let t = tokens, let input = t.input, let output = t.output, let cached = t.cached,
              input >= 0, output >= 0, cached >= 0, cached <= input else { return .unknown("缺少或不一致的计费 Token") }
        let r = row.threshold.map { input > $0 } == true ? row.longRates! : row.rates
        // Writes need not be reported if they have the same price as ordinary input.
        let written = t.written ?? (r[2] == r[0] ? 0 : -1)
        guard written >= 0, written <= input - cached else { return .unknown("缺少或不一致的缓存写入量") }
        let parts = [input - cached - written, cached, written, output]
        var usd = 0.0
        for i in 0..<4 where parts[i] > 0 {
            guard let rate = r[i] else { return .unknown("该模型未公布此计费项") }
            usd += Double(parts[i]) * rate / 1_000_000
        }
        guard usd.isFinite else { return .unknown("费用数值溢出") }
        return APICost(usd: usd, models: [row.provider + "/" + row.model])
    }
}

// Consume each cumulative delta once. Retain priced increments for the root's turn window.
final class CostLedger {
    var total = APICost()
    var round = APICost.unknown("尚无本轮记录")
    var last = APICost.unknown("尚无最近调用")
    var model: String?
    var previous: Tokens = .zero
    var points: [(Date, APICost)] = []
    var droppedThrough: Date?
    let book: PriceBook
    init(book: PriceBook = .shared) { self.book = book }
    func since(_ boundary: Date?) -> APICost {
        guard let boundary else { return .unknown("缺少主任务时间边界") }
        guard droppedThrough.map({ boundary > $0 }) ?? true else { return .unknown("本轮费用超出保留的历史范围") }
        return points.filter { $0.0 >= boundary }.reduce(APICost()) { $0.adding($1.1) }
    }
    func consume(_ d: [String: Any]) {
        guard let p = d["payload"] as? [String: Any] else { return }
        if d["type"] as? String == "turn_context" { model = p["model"] as? String; return }
        guard d["type"] as? String == "event_msg" else { return }
        if p["type"] as? String == "task_started" {
            round = APICost(); last = .unknown("尚无最近调用"); model = nil; return
        }
        guard p["type"] as? String == "token_count", let info = p["info"] as? [String: Any],
              let cumulative = info["total_token_usage"] as? [String: Any] else { return }
        let next = Tokens(cumulative)
        guard next != previous else { return }
        let delta = next.subtracting(previous)
        let recent = (info["last_token_usage"] as? [String: Any]).map(Tokens.init)
        last = book.quote(recent, model: model)
        // A missing event can span models/context tiers; never price it as one call.
        let continuous = recent.map { $0.input == delta.input && $0.output == delta.output && $0.cached == delta.cached && $0.written == delta.written } ?? false
        let cost = continuous ? last : APICost.unknown("调用明细与累计增量不一致")
        total = total.adding(cost); round = round.adding(cost); previous = next
        if let date = usageDate(d["timestamp"] as? String) { points.append((date, cost)) }
        else { droppedThrough = .distantFuture }
        if points.count > 8192 { droppedThrough = max(droppedThrough ?? .distantPast, points[points.count - 8192 - 1].0); points.removeFirst(points.count - 8192) }
    }
}

// Read history in bounded chunks in the existing background worker. Never scan bodies into a database.
final class CostLogReader {
    let path: String
    private var offset: UInt64 = 0
    private var identity: UInt64?
    private var buffer = Data()
    private var dropping = false
    private(set) var ledger = CostLedger()
    private(set) var ready = false
    init(path: String) { self.path = path }
    func poll() {
        ready = false
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
            if identity != inode || size < offset { offset = 0; buffer.removeAll(); dropping = false; ledger = CostLedger(); identity = inode }
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: Int(min(size - offset, 8 * 1024 * 1024))) ?? Data(); offset += UInt64(data.count)
            for chunk in data.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
                if chunk.offset > 0 {
                    if !dropping, (buffer.range(of: Data("\"event_msg\"".utf8)) != nil || buffer.range(of: Data("\"turn_context\"".utf8)) != nil),
                       let d = (try? JSONSerialization.jsonObject(with: buffer)) as? [String: Any] { ledger.consume(d) }
                    buffer.removeAll(keepingCapacity: true); dropping = false
                }
                if !dropping { buffer.append(contentsOf: chunk.element); if buffer.count > 2 * 1024 * 1024 { buffer.removeAll(); dropping = true } }
            }
            ready = offset == size && buffer.isEmpty && !dropping
        } catch { ready = false }
    }
    var hasMore: Bool { ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber).map { offset < $0.uint64Value } ?? false }
    var total: APICost { ready ? ledger.total : .unknown("正在回溯费用或记录不可读") }
    var round: APICost { ready ? ledger.round : .unknown("正在回溯费用或记录不可读") }
    var last: APICost { ready ? ledger.last : .unknown("正在回溯费用或记录不可读") }
    func since(_ date: Date?) -> APICost { ready ? ledger.since(date) : .unknown("正在回溯子代理费用") }
}

struct PricedCall: Codable {
    var id: String
    var model: String
    var provider: String?
    var createdAt: String
    var tokens: Tokens
}
func bridgeCosts(_ session: BridgeSession, boundary: Date?) -> (APICost, APICost, APICost) {
    guard let calls = session.calls else { return (.unknown("接入程序未提供逐次调用"), .unknown("接入程序未提供逐次调用"), .unknown("接入程序未提供逐次调用")) }
    var total = APICost(); var round = boundary == nil ? APICost.unknown("缺少主任务时间边界") : APICost()
    var summed = Tokens.zero
    for call in calls {
        let value = PriceBook.shared.quote(call.tokens, model: call.model, provider: call.provider)
        total = total.adding(value); summed = summed.adding(call.tokens)
        if let boundary, let stamp = usageDate(call.createdAt), stamp >= boundary { round = round.adding(value) }
    }
    if session.callsComplete != true || summed.input != session.total?.input || summed.output != session.total?.output || summed.cached != session.total?.cached || summed.written != session.total?.written {
        total = total.adding(.unknown("逐次调用未覆盖完整用量")); round = round.adding(.unknown("逐次调用未覆盖完整用量"))
    }
    let last = calls.max { (usageDate($0.createdAt) ?? .distantPast) < (usageDate($1.createdAt) ?? .distantPast) }
    let recent = last.flatMap { call in session.last == call.tokens && session.callsComplete == true ? PriceBook.shared.quote(call.tokens, model: call.model, provider: call.provider) : nil }
    return (total, round, recent ?? .unknown("接入记录未确认最近调用"))
}
