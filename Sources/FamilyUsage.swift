import Foundation

final class CodexFamilyReader: SnapshotReader {
    let root: ThreadEntry
    let store: ThreadStore
    let includeChildren: Bool
    private var readers: [String: UsageReader] = [:]
    init(root: ThreadEntry, store: ThreadStore = ThreadStore(), includeChildren: Bool = true) {
        self.root = root; self.store = store; self.includeChildren = includeChildren
        readers[root.id] = UsageReader(path: root.path)
    }
    func poll() -> UsageSnapshot {
        var main = readers[root.id]!.poll()
        guard includeChildren else { return main }
        let entries = store.read(familyRoot: root.id)
        guard !entries.isEmpty else {
            main.error = "无法读取子代理关系，当前仅显示主任务"; return main
        }
        let boundary = usageDate(main.turnStartedAt)
        var total = main.error == nil ? main.total : nil
        var round = main.error == nil ? main.round : nil
        main.members = [UsageMember(id: root.id, title: root.title, total: total, round: round, error: main.error, costTotal: main.costTotal, costRound: main.costRound)]
        let ids = Set(entries.map(\.id))
        readers = readers.filter { ids.contains($0.key) }
        for entry in entries where entry.id != root.id {
            if readers[entry.id]?.path != entry.path { readers[entry.id] = UsageReader(path: entry.path) }
            let reader = readers[entry.id]!
            let child = reader.poll()
            let childTotal = child.error == nil ? child.total : nil
            let childRound = boundary.flatMap { reader.usage(since: $0) }
            main.members.append(UsageMember(id: entry.id, title: entry.title, total: childTotal, round: childRound, error: child.error, costTotal: child.costTotal, costRound: reader.costs.since(boundary)))
            main.costTotal = (main.costTotal ?? .unknown("缺少主任务费用")).adding(child.costTotal ?? .unknown("缺少子代理费用"))
            main.costRound = (main.costRound ?? .unknown("缺少主任务费用")).adding(reader.costs.since(boundary))
            total = total?.adding(childTotal ?? Tokens())
            round = round?.adding(childRound ?? Tokens())
            main.running = main.running || child.running
            main.partialHistory = main.partialHistory || child.partialHistory
            if let date = usageDate(child.updatedAt), date > (usageDate(main.updatedAt) ?? .distantPast) { main.updatedAt = child.updatedAt }
        }
        main.aggregated = true; main.total = total; main.aggregateRound = round
        let missing = main.members.filter { $0.total == nil || $0.error != nil }.count
        main.scopeNote = "含 \(entries.count - 1) 个子代理；最近调用仅指主任务。"
        if missing > 0 { main.error = "\(missing) 个任务记录缺失，汇总不完整（—）" }
        return main
    }
}
