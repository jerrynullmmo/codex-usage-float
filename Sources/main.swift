import AppKit

let args = CommandLine.arguments
func argument(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }; return args[i + 1]
}
if args.contains("--focus-probe") {
    let report = ActiveConversation.probe()
    let data = try! JSONEncoder().encode(report)
    print(String(decoding: data, as: UTF8.self))
    if let path = argument("--diagnostic-output") { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
} else if let thread = argument("--snapshot") {
    if let entry = ThreadStore().read(id: thread).first {
        let snapshot = UsageReader(path: entry.path).poll()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let bytes = try? encoder.encode(snapshot) { print(String(decoding: bytes, as: UTF8.self)) }
    } else { fputs("本地任务不存在\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    // LaunchServices normally prevents duplicates; direct launches also leave the existing monitor alone.
    if !args.contains("--ui-test"), let id = Bundle.main.bundleIdentifier,
       NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { exit(0) }
    let delegate = MonitorController(thread: argument("--thread"), uiTest: args.contains("--ui-test"))
    app.delegate = delegate
    app.run()
}
