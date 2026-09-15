import AppKit
import ApplicationServices

struct FocusReport: Codable {
    var status: String
    var title: String?
    var thread: ThreadEntry?
    var message: String {
        switch status {
        case "matched": return "自动跟随 · 标题唯一匹配"
        case "permission": return "需要辅助功能权限以读取对话标题"
        case "ambiguous": return "存在同名任务，无法确认当前对话"
        case "unmatched": return "未找到对应本地任务，可能是远程或新对话"
        case "background": return "Codex 不在前台，等待返回"
        default: return "未识别到对话，暂不显示任务用量"
        }
    }
    static func resolve(title: String, store: ThreadStore = ThreadStore()) -> FocusReport {
        guard !title.isEmpty, !["ChatGPT", "Codex"].contains(title) else { return FocusReport(status: "unavailable") }
        let matches = store.read(exactTitle: title)
        guard matches.count == 1 else { return FocusReport(status: matches.isEmpty ? "unmatched" : "ambiguous", title: title) }
        return FocusReport(status: "matched", title: title, thread: matches[0])
    }
}

enum ActiveConversation {
    static func read(pid: pid_t, store: ThreadStore = ThreadStore()) -> FocusReport {
        guard AXIsProcessTrusted() else { return FocusReport(status: "permission") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
            return value
        }
        guard let value = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return FocusReport(status: "unavailable") }
        let window = value as! AXUIElement
        var budget = 80
        var titles: [String] = []
        let deadline = Date().addingTimeInterval(0.6)
        func visit(_ element: AXUIElement, depth: Int) {
            guard budget > 0, depth < 12, Date() < deadline else { return }; budget -= 1
            let role = attribute(element, kAXRoleAttribute) as? String
            if role == "AXWebArea" {
                // Only the Codex app shell. Do not inspect conversation text or embedded browser pages.
                let url = attribute(element, kAXURLAttribute)
                let address = (url as? URL)?.absoluteString ?? (url as? String) ?? ""
                if address == "app://-/index.html", let title = attribute(element, kAXTitleAttribute) as? String { titles.append(title) }
                return
            }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        guard budget > 0, Date() < deadline, titles.count == 1 else { return FocusReport(status: "unavailable") }
        return FocusReport.resolve(title: titles[0], store: store)
    }
    static func probe() -> FocusReport {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.openai.codex" else { return FocusReport(status: "background") }
        return read(pid: app.processIdentifier)
    }
}
