import Foundation
import Security
import LocalAuthentication

// YonshoreAPI's compatibility endpoints expose the account wallet, not a single key/task bill.
struct YonshoreWallet: Equatable {
    let available: Decimal
    let spent: Decimal
    static func money(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let format = NumberFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.numberStyle = .decimal
        format.usesGroupingSeparator = true; format.groupingSize = 3
        format.minimumFractionDigits = 2; format.maximumFractionDigits = 2
        return "$" + (format.string(from: NSDecimalNumber(decimal: value)) ?? "—")
    }
}
enum YonshoreError: Error {
    case key, credential, authentication, forbidden, limited, unavailable, response, changing
    var message: String {
        switch self {
        case .key: return "请在设置中连接 YonshoreAPI"
        case .credential: return "无法读取系统钥匙串，请重新连接"
        case .authentication: return "API Key 无效、过期或不可用，请重新连接"
        case .forbidden: return "账户或密钥访问受限，请检查权限/IP 限制"
        case .limited: return "查询过于频繁，稍后自动重试"
        case .unavailable: return "暂时无法连接 YonshoreAPI"
        case .response: return "账单响应无效，未更新金额"
        case .changing: return "账户正在结算，稍后重新获取一致余额"
        }
    }
}
struct YonshoreAccountState {
    var wallet: YonshoreWallet?
    var updatedAt: Date?
    var error: String?
    var loading = false
    mutating func accept(_ result: Result<YonshoreWallet, YonshoreError>, now: Date = Date()) {
        loading = false
        switch result {
        case .success(let wallet): self.wallet = wallet; updatedAt = now; error = nil
        case .failure(let failure): error = failure.message
        }
    }
    var status: String {
        if let error { return error + (wallet == nil ? "" : " · 显示上次成功结果") }
        if loading && wallet == nil { return "正在查询账户…" }
        if let updatedAt { return "账户范围 · \(max(0, Int(Date().timeIntervalSince(updatedAt)))) 秒前更新" }
        return "未连接 · 设置中添加 API Key"
    }
}
func yonshoreKey(_ raw: String) throws -> String {
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard key.hasPrefix("sk-"), (16...512).contains(key.utf8.count), key.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw YonshoreError.key }
    return key
}

final class YonshoreClient: NSObject, URLSessionTaskDelegate {
    static let origin = "https://api.yonshore.com"
    // Never forward an API key to a redirect destination, including a login page.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func fetch(key: String) -> Result<YonshoreWallet, YonshoreError> {
        do {
            let key = try yonshoreKey(key)
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCache = nil; config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 15
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            return .success(try Self.read { endpoint in
                var request = URLRequest(url: URL(string: Self.origin + "/v1/dashboard/billing/" + endpoint)!)
                request.httpMethod = "GET"; request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("AI-Usage-Float", forHTTPHeaderField: "User-Agent")
                let sem = DispatchSemaphore(value: 0)
                var result: Result<Data, YonshoreError> = .failure(.unavailable)
                let task = session.dataTask(with: request) { data, response, error in
                    defer { sem.signal() }
                    guard error == nil, let response = response as? HTTPURLResponse else { return }
                    let code = response.statusCode
                    if code == 401 { result = .failure(.authentication); return }
                    if code == 403 || code == 451 { result = .failure(.forbidden); return }
                    if code == 429 { result = .failure(.limited); return }
                    guard code == 200 else { result = .failure(code >= 500 ? .unavailable : .response); return }
                    guard let data, data.count <= 64 * 1024, response.mimeType == "application/json" else { result = .failure(.response); return }
                    result = .success(data)
                }
                task.resume(); sem.wait()
                return try result.get()
            })
        } catch let error as YonshoreError { return .failure(error) }
        catch { return .failure(.response) }
    }
    static func read(get: (String) throws -> Data) throws -> YonshoreWallet {
        // Bracket the balance read with consumption reads so concurrent charges cannot mix snapshots.
        for _ in 0..<2 {
            let before = try usage(get("usage"))
            let budget = try subscription(get("subscription"))
            let after = try usage(get("usage"))
            if before == after { return YonshoreWallet(available: (budget - after) / 100, spent: after / 100) }
        }
        throw YonshoreError.changing
    }
    private struct Usage: Decodable { let object: String; let total_usage: Decimal }
    private struct Subscription: Decodable { let object: String; let hard_limit_usd: Decimal }
    private static func cents(_ n: Decimal, nonnegative: Bool) throws -> Decimal {
        var value = n; var rounded = Decimal(); NSDecimalRound(&rounded, &value, 0, .plain)
        guard !n.isNaN, n == rounded, n >= (nonnegative ? 0 : -9_007_199_254_740_991), n <= 9_007_199_254_740_991 else { throw YonshoreError.response }
        return n
    }
    static func usage(_ bytes: Data) throws -> Decimal {
        guard bytes.count <= 64 * 1024, let decoded = try? JSONDecoder().decode(Usage.self, from: bytes), decoded.object == "list" else { throw YonshoreError.response }
        return try cents(decoded.total_usage, nonnegative: true)
    }
    static func subscription(_ bytes: Data) throws -> Decimal {
        guard bytes.count <= 64 * 1024, let decoded = try? JSONDecoder().decode(Subscription.self, from: bytes), decoded.object == "billing_subscription" else { throw YonshoreError.response }
        return try cents(decoded.hard_limit_usd * 100, nonnegative: false)
    }
}

enum YonshoreSecret {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.yonshore.codex-usage-float.yonshoreapi", kSecAttrAccount as String: "default"] }
    static func load() throws -> String {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let code = SecItemCopyMatching(q as CFDictionary, &item)
        guard code != errSecItemNotFound else { throw YonshoreError.key }
        guard code == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else { throw YonshoreError.credential }
        return try yonshoreKey(key)
    }
    static func save(_ raw: String) throws {
        let key = try yonshoreKey(raw)
        let value = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q.merge(value) { _, new in new }; q[kSecAttrLabel as String] = "YonshoreAPI 用量浮窗"
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw YonshoreError.credential }
        } else if status != errSecSuccess { throw YonshoreError.credential }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw YonshoreError.credential }
    }
}
