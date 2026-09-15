import AppKit

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true; becomesKeyOnlyIfNeeded = true; hidesOnDeactivate = false
        backgroundColor = .clear; isOpaque = false; hasShadow = true; level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false; acceptsMouseMovedEvents = true
        animationBehavior = .none
    }
}

final class MonitorView: NSView {
    weak var owner: MonitorController?
    let detail: Bool
    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var dragged = false
    var actions: [(NSRect, () -> Void)] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(detail: Bool) { self.detail = detail; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func mouseDown(with event: NSEvent) {
        if detail {
            let p = convert(event.locationInWindow, from: nil)
            for (r, action) in actions where r.contains(p) { action(); return }
        } else {
            dragStart = NSEvent.mouseLocation; windowStart = window?.frame.origin; dragged = false
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard !detail, let start = dragStart, let origin = windowStart else { return }
        let point = NSEvent.mouseLocation
        if hypot(point.x - start.x, point.y - start.y) > 3 { dragged = true }
        if dragged {
            owner?.dragging = true; owner?.card.orderOut(nil)
            window?.setFrameOrigin(NSPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y))
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard !detail else { return }
        if dragged { owner?.finishDrag() } else { owner?.togglePin() }
        dragStart = nil; windowStart = nil
    }
    override func rightMouseDown(with event: NSEvent) { owner?.showMenu(at: convert(event.locationInWindow, from: nil), in: self) }

    private func rect(_ r: NSRect, _ color: NSColor, radius: CGFloat = 0) {
        color.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }
    private func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, size: CGFloat = 12,
                      color: NSColor = .white, weight: NSFont.Weight = .regular, mono: Bool = false, align: NSTextAlignment = .left) {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; p.alignment = align
        let f = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        (s as NSString).draw(in: NSRect(x: x, y: y, width: width, height: size + 7), withAttributes: [.font: f, .foregroundColor: color, .paragraphStyle: p])
    }
    private func button(_ title: String, _ r: NSRect, action: @escaping () -> Void) {
        rect(r, NSColor.white.withAlphaComponent(0.075), radius: 7)
        text(title, r.minX + 4, r.minY + 5, r.width - 8, size: 11, align: .center)
        actions.append((r, action))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        actions.removeAll()
        let base = NSColor(srgbRed: 0.075, green: 0.09, blue: 0.105, alpha: 0.98)
        let muted = NSColor(srgbRed: 0.59, green: 0.65, blue: 0.70, alpha: 1)
        let accent = owner.accent
        rect(bounds, base, radius: detail ? 17 : 18)
        NSColor.white.withAlphaComponent(0.15).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: detail ? 17 : 18, yRadius: detail ? 17 : 18).stroke()
        if !detail {
            rect(NSRect(x: 12, y: 14, width: 7, height: 7), owner.signalColor, radius: 3.5)
            text(owner.compactLabel, 27, 9, 107, size: 12, weight: .semibold, mono: true)
            return
        }
        text(owner.snapshot.sourceName + " 用量", 18, 17, 130, size: 15, weight: .semibold)
        button(owner.pinned ? "已固定" : "固定", NSRect(x: 268, y: 12, width: 56, height: 28)) { [weak owner] in owner?.togglePin() }
        button("设置", NSRect(x: 332, y: 12, width: 56, height: 28)) { [weak owner, weak self] in
            guard let self else { return }; owner?.showMenu(at: NSPoint(x: 330, y: 42), in: self)
        }
        rect(NSRect(x: 16, y: 52, width: 374, height: 57), NSColor.white.withAlphaComponent(0.045), radius: 9)
        text(owner.selected?.title ?? owner.focusReport.title ?? "等待识别当前对话", 26, 61, 326, size: 12, weight: .medium)
        text("⌄", 360, 61, 18, size: 13, color: muted)
        text(owner.followsCurrent ? owner.focusReport.message : "手动选择 · 已暂停自动跟随", 26, 84, 347, size: 10, color: owner.followsCurrent && owner.selected != nil ? accent : NSColor(srgbRed: 0.86, green: 0.71, blue: 0.45, alpha: 1))
        actions.append((NSRect(x: 16, y: 52, width: 374, height: 57), { [weak owner, weak self] in
            guard let self else { return }; owner?.showThreadMenu(at: NSPoint(x: 18, y: 110), in: self)
        }))
        text("套餐快照" + (owner.snapshot.plan.map { " · " + $0.uppercased() } ?? ""), 18, 122, 210, size: 10, color: muted, weight: .medium)
        text(owner.ageLabel(owner.snapshot.quotaUpdatedAt), 230, 122, 158, size: 10, color: muted, align: .right)
        var y: CGFloat = 144
        if owner.snapshot.windows.isEmpty {
            text("暂无套餐额度记录", 18, y, 355, size: 13, color: muted); y += 44
        } else {
            for w in owner.snapshot.windows {
                let expired = w.resets.map { $0 <= Date().timeIntervalSince1970 } ?? false
                text(w.label, 18, y, 120, size: 12, color: muted)
                text(expired ? "待更新" : String(format: "剩余 %.0f%%", w.remaining), 160, y - 2, 228, size: 15, color: expired ? muted : accent, weight: .semibold, mono: true, align: .right)
                rect(NSRect(x: 18, y: y + 24, width: 370, height: 4), NSColor.white.withAlphaComponent(0.09), radius: 2)
                if !expired { rect(NSRect(x: 18, y: y + 24, width: 370 * w.remaining / 100, height: 4), w.remaining <= 10 ? .systemOrange : accent, radius: 2) }
                text(owner.resetLabel(w), 18, y + 34, 370, size: 10, color: muted)
                y += 62
            }
        }
        y += 4
        rect(NSRect(x: 18, y: y, width: 370, height: 1), NSColor.white.withAlphaComponent(0.08)); y += 14
        text("TOKEN", 18, y, 84, size: 10, color: muted, weight: .semibold)
        for (label, x) in [("任务合计", CGFloat(108)), ("本轮", CGFloat(204)), ("主任务最近", CGFloat(298))] {
            text(label, x, y, 90, size: 10, color: muted, align: .right)
        }
        y += 24
        for (i, metric) in owner.settings.metrics.enumerated() {
            if i % 2 == 0 { rect(NSRect(x: 12, y: y - 4, width: 382, height: 29), NSColor.white.withAlphaComponent(0.025), radius: 5) }
            text(metric.label, 18, y, 92, size: 11, color: muted)
            for (tokens, x) in [(owner.snapshot.total, CGFloat(108)), (owner.snapshot.round, CGFloat(204)), (owner.snapshot.last, CGFloat(298))] {
                text(metric.value(tokens), x, y, 90, size: 11, color: metric == .input || metric == .output ? .white : muted, mono: true, align: .right)
            }
            y += 29
        }
        y += 10
        text("输入含缓存；输出含推理，勿重复相加。", 18, y, 371, size: 10, color: muted); y += 18
        text("— 表示未提供或不完整；0 为数据源上报值。", 18, y, 371, size: 10, color: muted); y += 18
        text(owner.snapshot.scopeNote, 18, y, 371, size: 10, color: muted); y += 25
        rect(NSRect(x: 18, y: y, width: 370, height: 1), NSColor.white.withAlphaComponent(0.08)); y += 12
        let status = owner.snapshot.error ?? (owner.loading ? "正在读取记录…" : (owner.snapshot.running ? "任务执行中" : "等待下一轮"))
        text(status, 18, y, 220, size: 10, color: owner.snapshot.error == nil ? accent : .systemOrange)
        text(owner.ageLabel(owner.snapshot.updatedAt), 220, y, 168, size: 10, color: muted, align: .right)
    }
}

final class MonitorController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let pill = PassivePanel(size: NSSize(width: 144, height: 36))
    let card = PassivePanel(size: NSSize(width: 406, height: 530))
    let pillView = MonitorView(detail: false)
    let cardView = MonitorView(detail: true)
    var settings = Settings.load()
    var snapshot = UsageSnapshot()
    var selected: ThreadEntry?
    var recent: [ThreadEntry] = []
    var loading = false
    var pinned = false
    var dragging = false
    var focusReport = FocusReport(status: "unavailable")
    var followsCurrent: Bool { settings.autoFollow ?? true }
    private let focusQueue = DispatchQueue(label: "com.yonshore.codex-usage.focus", qos: .utility)
    private var checkingFocus = false
    private var lastFocusCheck = Date.distantPast
    private var menuOpen = false
    private var hidden = false
    private var reader: SnapshotReader?
    private let queue = DispatchQueue(label: "com.yonshore.codex-usage.reader", qos: .utility)
    private var reading = false
    private var selectionGeneration = 0
    private var insideSince: Date?
    private var outsideSince: Date?
    private var hoverTimer: Timer?
    private var readTimer: Timer?
    private var statusItem: NSStatusItem?
    private var menuActions: [Int: () -> Void] = [:]
    private let initialThread: String?
    private let uiTest: Bool
    init(thread: String?, uiTest: Bool = false) { self.initialThread = thread; self.uiTest = uiTest; super.init() }
    var accent: NSColor {
        switch settings.accent {
        case "blue": return NSColor(srgbRed: 0.46, green: 0.69, blue: 1, alpha: 1)
        case "rose": return NSColor(srgbRed: 0.96, green: 0.57, blue: 0.73, alpha: 1)
        default: return NSColor(srgbRed: 0.46, green: 0.87, blue: 0.73, alpha: 1)
        }
    }
    var validQuota: QuotaWindow? {
        snapshot.windows.filter { ($0.resets ?? .greatestFiniteMagnitude) > Date().timeIntervalSince1970 }.min { $0.remaining < $1.remaining }
    }
    var signalColor: NSColor { snapshot.error != nil ? .systemOrange : (validQuota.map { $0.remaining <= 10 ? .systemOrange : accent } ?? .gray) }
    var compactLabel: String {
        if followsCurrent && selected == nil { return focusReport.status == "permission" ? "需辅助功能权限" : "待识别对话" }
        if settings.compact == "quota" {
            let stale = ageSeconds(snapshot.quotaUpdatedAt).map { $0 >= 300 } ?? true
            return validQuota.map { String(format: "额度 %.0f%%", $0.remaining) + (stale ? "·旧" : "") } ?? "额度待更新"
        }
        let tokens = settings.compact.hasPrefix("round") ? snapshot.round : snapshot.total
        let output = settings.compact.hasSuffix("Output")
        let v = output ? tokens?.output : tokens?.input
        let label = settings.compact.hasPrefix("round") ? "本轮" : "累计"
        return label + (output ? "出 " : "入 ") + (v.map { compactNumber($0) } ?? "—")
    }
    private func compactNumber(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return String(n)
    }
    private func ageSeconds(_ iso: String?) -> Int? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        return date.map { max(0, Int(Date().timeIntervalSince($0))) }
    }
    func ageLabel(_ iso: String?) -> String {
        guard let age = ageSeconds(iso) else { return "尚未上报" }
        if age < 60 { return "\(age) 秒前更新" }
        if age < 3600 { return "\(age / 60) 分钟前更新" }
        if age < 86400 { return "\(age / 3600) 小时前更新" }
        return "\(age / 86400) 天前更新"
    }
    func resetLabel(_ w: QuotaWindow) -> String {
        guard let reset = w.resets else { return "来自所选任务快照 · 重置时间未知" }
        let seconds = Int(reset - Date().timeIntervalSince1970)
        guard seconds > 0 else { return "快照已跨重置时间，等待新的额度记录" }
        let hours = seconds / 3600
        let remaining = hours >= 24 ? "\(hours / 24) 天 \(hours % 24) 小时" : "\(hours) 小时 \((seconds % 3600) / 60) 分钟"
        return "约 \(remaining)后重置 · 来自所选任务快照"
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        pillView.owner = self; cardView.owner = self
        pill.contentView = pillView; card.contentView = cardView
        pill.title = "Codex 用量浮标"; card.title = "Codex 用量详情"
        pillView.setAccessibilityLabel("Codex 用量浮标：悬停查看，拖动移动，点击固定，右键设置")
        cardView.setAccessibilityLabel("Codex 用量详情")
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: settings.x ?? Double(screen.maxX - 164), y: settings.y ?? Double(screen.minY + 170))
        pill.setFrameOrigin(clamped(origin, size: pill.frame.size))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Codex 用量")
        statusItem?.button?.toolTip = "Codex 用量：显示、隐藏或退出浮窗"
        statusItem?.button?.target = self; statusItem?.button?.action = #selector(statusClicked)
        reloadThreads()
        let wanted = initialThread ?? settings.threadID
        if uiTest { settings.autoFollow = false }
        if !followsCurrent, let wanted, let entry = UsageSources().read(id: wanted, source: settings.sourceID ?? "codex") { select(entry) }
        else { selected = nil }
        hoverTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        readTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(hoverTimer!, forMode: .common); RunLoop.main.add(readTimer!, forMode: .common)
        tick()
        if uiTest { runUITest() }
    }
    func select(_ entry: ThreadEntry) {
        selected = entry; settings.threadID = entry.id; settings.sourceID = entry.source
        if !uiTest { settings.save() }
        selectionGeneration += 1; snapshot = UsageSnapshot(); reader = UsageSources().reader(for: entry, includeChildren: settings.includeSubagents ?? true); loading = true
        refresh()
    }
    private func reloadThreads() { recent = UsageSources().recent() }
    func applyFocus(_ report: FocusReport) {
        guard followsCurrent else { return }
        focusReport = report
        if let entry = report.thread {
            if selected?.id != entry.id || selected?.path != entry.path || selected?.source != entry.source { select(entry) }
            else { selected = entry }
        } else {
            // Invalidate an in-flight read before clearing the UI; old callbacks cannot repopulate it.
            if selected != nil || reader != nil { selectionGeneration += 1 }
            selected = nil; reader = nil; snapshot = UsageSnapshot(); loading = false
        }
        repaint(); writeDiagnostic()
    }
    private func refreshFocus() {
        guard followsCurrent, !uiTest, !checkingFocus, !menuOpen, Date().timeIntervalSince(lastFocusCheck) >= 0.5 else { return }
        lastFocusCheck = Date()
        guard let app = NSWorkspace.shared.frontmostApplication, UsageSources().supports(bundle: app.bundleIdentifier ?? "") else {
            applyFocus(FocusReport(status: "background")); return
        }
        checkingFocus = true
        let pid = app.processIdentifier
        focusQueue.async { [weak self] in
            let report = ActiveConversation.read(pid: pid, bundle: app.bundleIdentifier ?? "")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.checkingFocus = false
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { self.applyFocus(FocusReport(status: "background")); return }
                self.applyFocus(report)
            }
        }
    }
    private func writeDiagnostic() {
        guard let i = CommandLine.arguments.firstIndex(of: "--diagnostic-output"), i + 1 < CommandLine.arguments.count else { return }
        let info: [String: Any] = ["status": focusReport.status, "threadID": selected?.id ?? "", "title": selected?.title ?? "", "hasUsage": snapshot.total != nil, "timestamp": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) { try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]), options: .atomic) }
    }
    func refresh() {
        guard !reading, let reader else { return }
        reading = true
        let generation = selectionGeneration
        queue.async { [weak self] in
            let result = reader.poll()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.reading = false
                self.acceptUsage(result, generation: generation)
            }
        }
    }
    private func acceptUsage(_ result: UsageSnapshot, generation: Int) {
        guard generation == selectionGeneration else { refresh(); return }
        snapshot = result; loading = false; repaint(); writeDiagnostic()
    }
    private func hostIsFrontmost() -> Bool {
        let identifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return UsageSources().supports(bundle: identifier) || identifier == Bundle.main.bundleIdentifier
    }
    private func tick() {
        refreshFocus()
        let visible = !hidden && (!settings.onlyCodex || hostIsFrontmost() || menuOpen || uiTest)
        if !visible { pill.orderOut(nil); card.orderOut(nil); insideSince = nil; outsideSince = nil; return }
        if !pill.isVisible { pill.orderFrontRegardless() }
        guard !dragging, !menuOpen else { return }
        let point = NSEvent.mouseLocation
        updateHover(inside: pill.frame.contains(point) || (card.isVisible && card.frame.contains(point)), now: Date())
        pillView.needsDisplay = true
    }
    // Shared by live mouse tracking and interaction tests; timers never activate the app.
    func updateHover(inside: Bool, now: Date) {
        if pinned { showCard(); return }
        if inside {
            outsideSince = nil
            if insideSince == nil { insideSince = now }
            if now.timeIntervalSince(insideSince!) >= 0.3 { showCard() }
        } else {
            insideSince = nil
            if outsideSince == nil { outsideSince = now }
            if now.timeIntervalSince(outsideSince!) >= 0.5 { card.orderOut(nil) }
        }
    }
    func togglePin() {
        pinned.toggle(); insideSince = nil; outsideSince = nil
        if pinned { showCard() } else { card.orderOut(nil) }
        repaint()
    }
    private func cardHeight() -> CGFloat { 300 + CGFloat(max(1, snapshot.windows.count)) * 62 + CGFloat(settings.metrics.count) * 29 - (snapshot.windows.isEmpty ? 18 : 0) }
    func showCard() {
        placeCard(); if !card.isVisible { card.orderFrontRegardless() }; cardView.needsDisplay = true
    }
    private func placeCard() {
        let size = NSSize(width: 406, height: cardHeight())
        let screen = screenForPill()
        let x = min(max(pill.frame.maxX - size.width, screen.minX + 6), screen.maxX - size.width - 6)
        let above = pill.frame.maxY + 6
        let below = pill.frame.minY - 6 - size.height
        var point = NSPoint(x: x, y: above)
        if above + size.height > screen.maxY {
            if below >= screen.minY { point.y = below }
            else if pill.frame.minX - size.width - 6 >= screen.minX {
                point = NSPoint(x: pill.frame.minX - size.width - 6, y: pill.frame.midY - size.height / 2)
            } else if pill.frame.maxX + size.width + 6 <= screen.maxX {
                point = NSPoint(x: pill.frame.maxX + 6, y: pill.frame.midY - size.height / 2)
            } else { point.y = below }
        }
        card.setFrame(NSRect(origin: clamped(point, size: size), size: size), display: true)
    }
    private func screenForPill() -> NSRect {
        (NSScreen.screens.first { $0.frame.contains(NSPoint(x: pill.frame.midX, y: pill.frame.midY)) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
    private func clamped(_ point: NSPoint, size: NSSize) -> NSPoint {
        let screen = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: min(max(point.x, screen.minX + 6), screen.maxX - size.width - 6), y: min(max(point.y, screen.minY + 6), screen.maxY - size.height - 6))
    }
    func finishDrag() {
        dragging = false; pill.setFrameOrigin(clamped(pill.frame.origin, size: pill.frame.size))
        settings.x = pill.frame.minX; settings.y = pill.frame.minY; settings.save()
        if pinned { showCard() }
    }
    private func repaint() { pillView.needsDisplay = true; cardView.needsDisplay = true; if card.isVisible { placeCard() } }
    private func save() { if !uiTest { settings.save() }; repaint() }
    private func item(_ title: String, checked: Bool = false, action: @escaping () -> Void) -> NSMenuItem {
        let id = menuActions.count + 1; menuActions[id] = action
        let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
        item.target = self; item.tag = id; item.state = checked ? .on : .off
        return item
    }
    @objc private func menuAction(_ sender: NSMenuItem) { menuActions[sender.tag]?() }
    @objc private func statusClicked() {
        guard let button = statusItem?.button else { return }
        showMenu(at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }
    private func threadMenu() -> NSMenu {
        reloadThreads()
        let menu = NSMenu()
        let explanation = NSMenuItem(title: "手动选择监控任务（仅本机）", action: nil, keyEquivalent: ""); menu.addItem(explanation)
        for entry in recent {
            menu.addItem(item("[" + entry.source + "] " + String(entry.title.prefix(30)) + " · " + String(entry.id.suffix(6)), checked: selected?.id == entry.id && selected?.source == entry.source) { [weak self] in self?.settings.autoFollow = false; self?.select(entry) })
        }
        return menu
    }
    func showThreadMenu(at point: NSPoint, in view: NSView) {
        menuActions.removeAll(); let menu = threadMenu(); menu.delegate = self
        menu.popUp(positioning: nil, at: point, in: view)
    }
    func showMenu(at point: NSPoint, in view: NSView) {
        menuActions.removeAll(); let menu = NSMenu(); menu.delegate = self
        menu.addItem(item(hidden ? "显示浮窗" : "隐藏浮窗", action: { [weak self] in
            guard let self else { return }; self.hidden.toggle(); self.tick()
        }))
        menu.addItem(item("固定详情", checked: pinned, action: { [weak self] in self?.togglePin() }))
        menu.addItem(item("自动跟随当前对话", checked: followsCurrent, action: { [weak self] in
            guard let self else { return }; self.settings.autoFollow = !self.followsCurrent
            if self.followsCurrent { self.applyFocus(FocusReport(status: "unavailable")); self.lastFocusCheck = .distantPast; self.refreshFocus() }
            self.save()
        }))
        if focusReport.status == "permission" {
            menu.addItem(item("打开辅助功能设置…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            })
        }
        menu.addItem(item("仅已接入的软件在前台时显示", checked: settings.onlyCodex, action: { [weak self] in
            guard let self else { return }; self.settings.onlyCodex.toggle(); self.save()
        }))
        menu.addItem(.separator())
        let tasks = NSMenuItem(title: "选择监控任务", action: nil, keyEquivalent: ""); tasks.submenu = threadMenu(); menu.addItem(tasks)
        menu.addItem(item("汇总全部子代理", checked: settings.includeSubagents ?? true) { [weak self] in
            guard let self else { return }; self.settings.includeSubagents = !(self.settings.includeSubagents ?? true)
            if let selected = self.selected { self.select(selected) }; self.save()
        })
        if !snapshot.members.isEmpty {
            let members = NSMenuItem(title: "查看各任务用量", action: nil, keyEquivalent: ""); members.submenu = NSMenu()
            for member in snapshot.members {
                let row = NSMenuItem(title: String(member.title.prefix(32)) + " · " + String(member.id.suffix(6)), action: nil, keyEquivalent: "")
                row.submenu = NSMenu()
                for metric in Metric.allCases {
                    row.submenu?.addItem(NSMenuItem(title: metric.label + "：" + metric.value(member.total) + " · 本轮 " + metric.value(member.round), action: nil, keyEquivalent: ""))
                }
                members.submenu?.addItem(row)
            }
            menu.addItem(members)
        }
        menu.addItem(item("打开软件接入目录") {
            try? FileManager.default.createDirectory(at: UsageBridge.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(UsageBridge.directory)
        })
        let compact = NSMenuItem(title: "浮标显示内容", action: nil, keyEquivalent: ""); compact.submenu = NSMenu()
        for (key, label) in [("quota", "套餐剩余比例"), ("totalInput", "任务累计输入"), ("totalOutput", "任务累计输出"), ("roundInput", "本轮输入"), ("roundOutput", "本轮输出")] {
            compact.submenu?.addItem(item(label, checked: settings.compact == key) { [weak self] in self?.settings.compact = key; self?.save() })
        }
        menu.addItem(compact)
        let metrics = NSMenuItem(title: "详情指标与顺序", action: nil, keyEquivalent: ""); metrics.submenu = NSMenu()
        for metric in settings.metrics + Metric.allCases.filter({ !settings.metrics.contains($0) }) {
            let row = NSMenuItem(title: metric.label, action: nil, keyEquivalent: ""); row.state = settings.metrics.contains(metric) ? .on : .off; row.submenu = NSMenu()
            row.submenu?.addItem(item(settings.metrics.contains(metric) ? "隐藏" : "显示") { [weak self] in
                guard let self else { return }
                if self.settings.metrics.contains(metric) { self.settings.metrics.removeAll { $0 == metric } } else { self.settings.metrics.append(metric) }; self.save()
            })
            if let index = settings.metrics.firstIndex(of: metric), index > 0 {
                row.submenu?.addItem(item("向上移动") { [weak self] in self?.settings.metrics.swapAt(index, index - 1); self?.save() })
            }
            metrics.submenu?.addItem(row)
        }
        menu.addItem(metrics)
        let colors = NSMenuItem(title: "强调颜色", action: nil, keyEquivalent: ""); colors.submenu = NSMenu()
        for (key, label) in [("mint", "薄荷绿"), ("blue", "晴空蓝"), ("rose", "玫瑰粉")] {
            colors.submenu?.addItem(item(label, checked: settings.accent == key) { [weak self] in self?.settings.accent = key; self?.save() })
        }
        menu.addItem(colors); menu.addItem(.separator())
        menu.addItem(item("使用说明") { NSWorkspace.shared.open(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/README.md")) })
        menu.addItem(item("退出用量浮窗") { NSApp.terminate(nil) })
        menu.popUp(positioning: nil, at: point, in: view)
    }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; outsideSince = Date() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func runUITest() {
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            // Tests use the same state transitions as real mouse tracking, without controlling other apps.
            hoverTimer?.invalidate()
            var checks: [String: Bool] = [:]
            card.orderOut(nil); insideSince = nil; outsideSince = nil
            let now = Date()
            updateHover(inside: true, now: now)
            checks["hover_delayed"] = !card.isVisible
            updateHover(inside: true, now: now.addingTimeInterval(0.31))
            checks["hover_expands"] = card.isVisible
            checks["never_key_window"] = !pill.isKeyWindow && !card.isKeyWindow && !pill.canBecomeKey && !card.canBecomeKey
            checks["frontmost_unchanged"] = before == NSWorkspace.shared.frontmostApplication?.processIdentifier
            capture(cardView, name: "detail.png"); capture(pillView, name: "pill.png")
            updateHover(inside: false, now: now.addingTimeInterval(0.4))
            checks["leave_delayed"] = card.isVisible
            updateHover(inside: false, now: now.addingTimeInterval(0.91))
            checks["leave_collapses"] = !card.isVisible
            togglePin(); updateHover(inside: false, now: now.addingTimeInterval(2))
            checks["pin_keeps_open"] = pinned && card.isVisible
            togglePin(); checks["unpin_closes"] = !card.isVisible
            checks["card_on_screen"] = screenForPill().contains(card.frame)
            checks["card_does_not_cover_pill"] = !card.frame.intersects(pill.frame)
            checks["live_tokens_loaded"] = snapshot.total?.input != nil
            let originalSnapshot = snapshot
            snapshot.windows = [QuotaWindow(used: 40, minutes: 300, resets: Date().timeIntervalSince1970 - 1)]
            checks["expired_quota_is_unknown"] = validQuota == nil && compactLabel == "额度待更新"
            snapshot = originalSnapshot
            let originalOrigin = pill.frame.origin
            let screen = screenForPill()
            for (index, position) in [NSPoint(x: screen.minX + 8, y: screen.minY + 8),
                                      NSPoint(x: screen.maxX - 152, y: screen.maxY - 44),
                                      NSPoint(x: screen.maxX - 152, y: screen.midY)].enumerated() {
                pill.setFrameOrigin(position); placeCard()
                checks["placement_\(index)_contained"] = screen.contains(card.frame)
                checks["placement_\(index)_no_overlap"] = !card.frame.intersects(pill.frame)
            }
            pill.setFrameOrigin(originalOrigin)
            settings.autoFollow = true
            let previousGeneration = selectionGeneration
            applyFocus(FocusReport(status: "unmatched", title: "未识别页面"))
            checks["unknown_focus_clears_usage"] = selected == nil && snapshot.total == nil
            acceptUsage(originalSnapshot, generation: previousGeneration)
            checks["late_previous_task_result_ignored"] = selected == nil && snapshot.total == nil
            checks["unknown_focus_pill_is_explicit"] = compactLabel == "待识别对话"
            applyFocus(FocusReport(status: "permission"))
            checks["missing_permission_is_explicit"] = compactLabel == "需辅助功能权限"
            settings.autoFollow = false
            if let bytes = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: bytes, as: UTF8.self))
            }
            fflush(stdout)
            if checks.values.allSatisfy({ $0 }) { NSApp.terminate(nil) } else { exit(1) }
        }
    }
    private func capture(_ view: NSView, name: String) {
        view.layoutSubtreeIfNeeded(); view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            let path = ProcessInfo.processInfo.environment["USAGE_TEST_OUTPUT"] ?? NSTemporaryDirectory()
            try? data.write(to: URL(fileURLWithPath: path).appendingPathComponent(name))
        }
    }
}
