import Foundation
import CryptoKit

// Summaries only: persisted locally, never conversation text. Each session is read without descendants.
struct AllUsageSummary: Codable {
    var total = Tokens()
    var missing: [String: Int] = [:]
    var cost = APICost.unknown("正在汇总历史")
    var count = 0
    var loaded = 0
    var issues: [String] = []
    var updatedAt: String?
    func value(_ metric: Metric) -> String {
        if metric == .hitRate {
            return missing["input", default: 0] + missing["cached", default: 0] == 0 ? metric.value(total) : "—"
        }
        let text = metric.value(total)
        return text + (text != "—" && missing[metric.rawValue, default: 0] > 0 ? " + ?" : "")
    }
    var tokenLabel: String {
        guard let input = total.input, let output = total.output else { return "—" }
        let sum = input.addingReportingOverflow(output)
        guard !sum.overflow else { return "—" }
        return Metric.input.value(Tokens(input: sum.partialValue)) + (missing["input", default: 0] + missing["output", default: 0] > 0 ? " + ?" : "")
    }
    var status: String { if count == 0 && updatedAt == nil { return "正在读取本机历史…" }; return loaded < count ? "正在汇总 \(loaded) / \(count) 条记录" : "已汇总 \(count) 条记录 · 含归档与子代理" }
}

final class AllUsageReader {
    struct Cached: Codable { var signature: String; var tokens: Tokens?; var cost: APICost }
    private var cache: [String: Cached] = [:]
    private var entries: [ThreadEntry] = []
    private var pending: [ThreadEntry] = []
    private var current: (ThreadEntry, UsageReader)?
    private var refreshed = Date.distantPast
    private var issues: [String] = []
    private var updatedAt: String?
    private var dirty = false
    private var lastSaved = Date.distantPast
    private let cacheURL: URL?
    private let priceFingerprint: String
    private let catalog: () throws -> [ThreadEntry]
    init(cacheURL: URL? = Settings.directory.appendingPathComponent("all-usage-cache.json"), catalog: @escaping () throws -> [ThreadEntry] = { try UsageSources().allEntries() }) {
        self.cacheURL = cacheURL; self.catalog = catalog
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        priceFingerprint = SHA256.hash(data: (try? encoder.encode(PriceBook.shared.document)) ?? Data()).description
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), data.count <= 20 * 1024 * 1024 {
            cache = (try? JSONDecoder().decode([String: Cached].self, from: data)) ?? [:]
        }
    }
    private func key(_ e: ThreadEntry) -> String { e.source + ":" + e.id }
    private func signature(_ e: ThreadEntry) -> String {
        func stamp(_ path: String) -> String {
            guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return "missing" }
            return "\(a[.size] ?? "")|\(a[.modificationDate] ?? "")|\(a[.systemFileNumber] ?? "")"
        }
        return e.path + "|" + stamp(e.path) + (e.source == "opencode" ? stamp(e.path + "-wal") : "") + "|" + priceFingerprint
    }
    func poll(force: Bool = false) -> AllUsageSummary { autoreleasepool { pollBatch(force: force) } }
    private func pollBatch(force: Bool) -> AllUsageSummary {
        if current == nil && pending.isEmpty && (force || Date().timeIntervalSince(refreshed) >= 30) {
            refreshed = Date(); issues = []
            do {
                var seen: Set<String> = []
                entries = try catalog().filter { seen.insert(key($0)).inserted }
                let ids = Set(entries.map(key)); cache = cache.filter { ids.contains($0.key) }
                pending = entries.filter { cache[key($0)]?.signature != signature($0) }
                for e in pending { cache.removeValue(forKey: key(e)) }; dirty = true
            } catch { issues = ["部分数据源无法读取，汇总范围待核"] }
        }
        let deadline = Date().addingTimeInterval(0.15)
        repeat {
            if current == nil {
                guard !pending.isEmpty else { break }
                let e = pending.removeFirst()
                if e.source == "codex" { current = (e, UsageReader(path: e.path)) }
                else {
                    let before = signature(e)
                    let s = UsageSources().reader(for: e, includeChildren: false).poll()
                    dirty = true
                    cache[key(e)] = Cached(signature: before, tokens: s.total, cost: s.costTotal ?? .unknown("缺少费用记录"))
                    continue
                }
            }
            if let (e, reader) = current {
                let before = signature(e)
                let s = reader.poll()
                if reader.costs.hasMore { break }
                // If an actively written record changed, retry it next cycle rather than cache it as current.
                cache[key(e)] = Cached(signature: before, tokens: s.error == nil ? s.total : nil, cost: s.error == nil ? s.costTotal ?? .unknown("缺少费用记录") : .unknown("任务记录不可读"))
                current = nil; dirty = true
            }
        } while Date() < deadline
        if dirty && ((current == nil && pending.isEmpty) || Date().timeIntervalSince(lastSaved) >= 5) {
            dirty = false; lastSaved = Date()
            if current == nil && pending.isEmpty { updatedAt = ISO8601DateFormatter().string(from: Date()) }
            if let cacheURL, let data = try? JSONEncoder().encode(cache) {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Avoid rewriting an unchanged summary on every UI refresh.
                if (try? Data(contentsOf: cacheURL)) != data { try? data.write(to: cacheURL, options: .atomic) }
            }
        }
        return Self.summarize(entries: entries, cache: cache, issues: issues, updatedAt: updatedAt)
    }
    static func summarize(entries: [ThreadEntry], cache: [String: Cached], issues: [String] = [], updatedAt: String? = nil) -> AllUsageSummary {
        var s = AllUsageSummary(); s.issues = issues; s.updatedAt = updatedAt; s.cost = APICost()
        var seen: Set<String> = []
        let fields: [(String, WritableKeyPath<Tokens, Int64?>)] = [("input", \.input), ("output", \.output), ("cached", \.cached), ("written", \.written), ("reasoning", \.reasoning)]
        for e in entries where seen.insert(e.source + ":" + e.id).inserted {
            s.count += 1
            let row = cache[e.source + ":" + e.id]; if row != nil { s.loaded += 1 }
            s.cost = s.cost.adding(row?.cost ?? .unknown("历史尚未全部读取"))
            for (name, path) in fields {
                if let n = row?.tokens?[keyPath: path] {
                    let sum = (s.total[keyPath: path] ?? 0).addingReportingOverflow(n)
                    if sum.overflow { s.missing[name, default: 0] += 1 } else { s.total[keyPath: path] = sum.partialValue }
                } else { s.missing[name, default: 0] += 1 }
            }
        }
        if !issues.isEmpty { s.cost = s.cost.adding(.unknown(issues.joined(separator: "；"))); for (name, _) in fields { s.missing[name, default: 0] += 1 } }
        if s.count == 0 { s.cost = .unknown("未找到已接入的本地记录") }
        return s
    }
}

extension UsageSources {
    // No recent-menu limit or archive filter. Descendants are individual rows, so never recursively summed here.
    func allEntries(codexHome: URL? = nil, openCodePath: String? = nil) throws -> [ThreadEntry] {
        var result: [ThreadEntry] = []
        let home = codexHome ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let databases = ((try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.range(of: "^state_[0-9]+\\.sqlite$", options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
        if let path = databases.first?.path {
            let rows = try UsageDatabase(path: path).rows("SELECT id,COALESCE(NULLIF(name,''),title) AS title,rollout_path FROM threads ORDER BY updated_at DESC")
            result += rows.map { ThreadEntry(id: $0["id"]!, title: $0["title"] ?? "", path: $0["rollout_path"] ?? "") }
        }
        let path = openCodePath ?? OpenCodeStore().path
        if FileManager.default.fileExists(atPath: path) {
            result += try UsageDatabase(path: path).rows("SELECT id,title FROM session").map { ThreadEntry(id: $0["id"]!, title: $0["title"] ?? "", path: path, source: "opencode") }
        }
        for (url, doc) in bridges {
            result += doc.sessions.map { ThreadEntry(id: $0.id, title: $0.title, path: url.path, source: "bridge:" + doc.id) }
        }
        return result
    }
}
