import Foundation

// One local snapshot file is enough to connect another desktop; the monitor never executes plugin code.
struct BridgeSession: Codable {
    var id: String
    var title: String
    var parentID: String?
    var calls: [PricedCall]?
    var callsComplete: Bool?
    var total: Tokens?
    var last: Tokens?
    var round: Tokens?
    var roundStartedAt: String?
    var updatedAt: String?
    var running: Bool?
}
struct BridgeQuota: Codable {
    var plan: String?
    var updatedAt: String
    var windows: [QuotaWindow]
}
struct UsageBridge: Codable {
    var schemaVersion: Int
    var id: String
    var name: String
    var bundleIDs: [String]
    var processNames: [String]?
    var updatedAt: String
    var activeSessionID: String?
    var sessions: [BridgeSession]
    var childrenComplete: Bool?
    var quota: BridgeQuota?
    static let directory = Settings.directory.appendingPathComponent("adapters")
    static func read(_ url: URL) -> UsageBridge? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
              size.intValue <= 1024 * 1024, let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(UsageBridge.self, from: data), doc.schemaVersion == 1,
              !doc.id.isEmpty, doc.id.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil,
              !doc.name.isEmpty, (!doc.bundleIDs.isEmpty || !(doc.processNames ?? []).isEmpty), doc.sessions.count <= 1000,
              Set(doc.sessions.map(\.id)).count == doc.sessions.count,
              doc.sessions.allSatisfy({ !$0.id.isEmpty }), usageDate(doc.updatedAt) != nil else { return nil }
        if let quota = doc.quota {
            guard usageDate(quota.updatedAt) != nil, quota.windows.count <= 2,
                  quota.windows.allSatisfy({ $0.used.isFinite && $0.used >= 0 && $0.used <= 100 && $0.minutes > 0 && ($0.resets?.isFinite ?? true) }) else { return nil }
        }
        let ids = Set(doc.sessions.map(\.id))
        guard doc.sessions.allSatisfy({ $0.parentID.map { ids.contains($0) } ?? true }),
              !doc.bundleIDs.contains(where: { ["com.openai.codex", "ai.opencode.desktop"].contains($0) }) else { return nil }
        for session in doc.sessions {
            if let calls = session.calls {
                guard calls.count <= 5000, Set(calls.map(\.id)).count == calls.count,
                      calls.allSatisfy({ !$0.id.isEmpty && !$0.model.isEmpty && usageDate($0.createdAt) != nil }) else { return nil }
                for call in calls {
                    guard [call.tokens.input, call.tokens.output, call.tokens.cached, call.tokens.written, call.tokens.reasoning].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { return nil }
                }
            }
            for tokens in [session.total, session.last, session.round].compactMap({ $0 }) {
                if [tokens.input, tokens.output, tokens.cached, tokens.written, tokens.reasoning].compactMap({ $0 }).contains(where: { $0 < 0 }) { return nil }
            }
        }
        return doc
    }
    var isActiveFresh: Bool {
        guard let date = usageDate(updatedAt) else { return false }
        return (-5...15).contains(Date().timeIntervalSince(date))
    }
    func entries(path: String) -> [ThreadEntry] {
        sessions.filter { $0.parentID == nil }.map { ThreadEntry(id: $0.id, title: $0.title, path: path, source: "bridge:" + id) }
    }
}

final class BridgeReader: SnapshotReader {
    let entry: ThreadEntry
    let includeChildren: Bool
    init(entry: ThreadEntry, includeChildren: Bool) { self.entry = entry; self.includeChildren = includeChildren }
    func poll() -> UsageSnapshot {
        var result = UsageSnapshot(); result.sourceName = "外部接入"
        guard let doc = UsageBridge.read(URL(fileURLWithPath: entry.path)), entry.source == "bridge:" + doc.id,
              let root = doc.sessions.first(where: { $0.id == entry.id }) else {
            result.error = "接入文件无效或所选任务已移除"; return result
        }
        result.sourceName = doc.name; result.updatedAt = root.updatedAt ?? doc.updatedAt
        result.windows = doc.quota?.windows ?? []; result.plan = doc.quota?.plan; result.quotaUpdatedAt = doc.quota?.updatedAt
        result.last = root.last; result.turnStartedAt = root.roundStartedAt; result.hasTurn = root.roundStartedAt != nil
        result.running = root.running ?? false
        var ids: Set<String> = [root.id]
        if includeChildren {
            while true {
                let old = ids.count
                for session in doc.sessions where session.parentID.map({ ids.contains($0) }) ?? false { ids.insert(session.id) }
                if old == ids.count { break }
            }
        }
        var total = Tokens.zero; var round = Tokens.zero
        result.costTotal = APICost(); result.costRound = APICost()
        result.costLast = bridgeCosts(root, boundary: usageDate(root.roundStartedAt)).2
        for session in doc.sessions where ids.contains(session.id) {
            let sameRound = usageDate(root.roundStartedAt) != nil && usageDate(root.roundStartedAt) == usageDate(session.roundStartedAt)
            let current = sameRound ? session.round : nil
            total = total.adding(session.total ?? Tokens()); round = round.adding(current ?? Tokens())
            let costs = bridgeCosts(session, boundary: usageDate(root.roundStartedAt))
            result.costTotal = result.costTotal?.adding(costs.0); result.costRound = result.costRound?.adding(costs.1)
            result.members.append(UsageMember(id: session.id, title: session.title, total: session.total, round: current, costTotal: costs.0, costRound: costs.1))
            result.running = result.running || (session.running ?? false)
        }
        result.total = total; result.aggregated = true; result.aggregateRound = result.hasTurn ? round : nil
        result.scopeNote = "\(doc.name) 提供；含 \(ids.count - 1) 个子代理。"
        if includeChildren && doc.childrenComplete != true {
            result.costTotal = result.costTotal?.adding(.unknown("子代理完整性未确认")); result.costRound = result.costRound?.adding(.unknown("子代理完整性未确认"))
            result.total = nil; result.aggregateRound = nil; result.error = "接入程序未确认子代理完整性，请查看明细或关闭汇总"
        }
        if !doc.isActiveFresh { result.error = "接入数据超过 15 秒未更新，请检查接入程序" }
        return result
    }
}

struct UsageSources {
    var bridgeDirectory = UsageBridge.directory
    var bridges: [(URL, UsageBridge)] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: bridgeDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.prefix(32)
        let docs = files.compactMap { url in UsageBridge.read(url).map { (url, $0) } }
        // Duplicate source identities are ambiguous, so neither is selectable.
        return docs.filter { doc in docs.filter { $0.1.id == doc.1.id }.count == 1 }
    }
    func supports(bundle: String) -> Bool {
        ["com.openai.codex", "ai.opencode.desktop"].contains(bundle) || bridges.contains { $0.1.bundleIDs.contains(bundle) }
    }
    func recent() -> [ThreadEntry] {
        ThreadStore().read() + OpenCodeStore().read() + bridges.flatMap { $0.1.entries(path: $0.0.path) }
    }
    func read(id: String, source: String) -> ThreadEntry? {
        if source == "codex" { return ThreadStore().read(id: id).first }
        if source == "opencode" { return OpenCodeStore().read(id: id).first }
        return bridges.first(where: { "bridge:" + $0.1.id == source }).flatMap { url, doc in
            doc.sessions.first(where: { $0.id == id }).map { ThreadEntry(id: $0.id, title: $0.title, path: url.path, source: source) }
        }
    }
    func reader(for entry: ThreadEntry, includeChildren: Bool) -> SnapshotReader {
        if entry.source == "codex" { return CodexFamilyReader(root: entry, includeChildren: includeChildren) }
        if entry.source == "opencode" { return OpenCodeReader(root: entry, includeChildren: includeChildren) }
        return BridgeReader(entry: entry, includeChildren: includeChildren)
    }
    func bridgeFocus(bundle: String) -> FocusReport? {
        let matches = bridges.filter { $0.1.bundleIDs.contains(bundle) }
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1 else { return FocusReport(status: "ambiguous") }
        let (url, doc) = matches[0]
        guard doc.isActiveFresh, let id = doc.activeSessionID, let session = doc.sessions.first(where: { $0.id == id }) else {
            return FocusReport(status: "unavailable")
        }
        return FocusReport(status: "bridge", title: session.title, thread: ThreadEntry(id: id, title: session.title, path: url.path, source: "bridge:" + doc.id))
    }
}
