import Foundation

/// 后台下发的 AI 配置。
///
/// ## 为什么要把参数搬出 App
///
/// 换模型、换 Key、调温度、开关识别，这些是**运营参数**，不是拍摄现场该碰的东西。
/// 放在 App 里意味着：每换一次 Key 都要重新签名装包，而且 Key 明文躺在手机上。
///
/// 现在 App 只保留一个「配置地址」，其余全部由后台 `/config.php` 下发：
///
/// ```json
/// {
///   "enabled": true,
///   "baseURL": "https://api.deepseek.com",
///   "apiKey": "sk-...",
///   "model": "deepseek-chat",
///   "temperature": 0.9,
///   "autoRecognize": true,
///   "useVision": false,
///   "autoGenerateOnShoot": true,
///   "burnIntoVideo": true,
///   "note": "本周主推：陶瓷碗"
/// }
/// ```
///
/// 所有字段都可选：后台只改想改的，其余沿用上一次成功同步的值。
/// 拉不到配置时**完全不影响出片**——AI 关掉，走本地模板。
struct RemoteAIConfig: Codable {
    var enabled: Bool?
    var baseURL: String?
    var apiKey: String?
    var model: String?
    var temperature: Double?
    var autoRecognize: Bool?
    var useVision: Bool?
    var autoGenerateOnShoot: Bool?
    var burnIntoVideo: Bool?
    /// 后台附带的提示语（如「本周主推陶瓷碗」），会显示在预览区
    var note: String?
}

enum RemoteConfigError: LocalizedError {
    case badURL
    case http(Int)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "配置地址格式不对（需 http/https 开头）"
        case .http(let code): return "后台返回 \(code)，检查地址与 token"
        case .decode(let raw): return "后台返回的不是 JSON：\(raw.prefix(60))"
        }
    }
}

enum RemoteConfig {
    /// 只做一件事：GET 一个 JSON 回来。
    ///
    /// 不做重试、不排队、不缓存到磁盘——它必须在任何情况下都很快返回，
    /// 因为调用方是「拍摄前的一次顺手刷新」，不能拖慢快门。
    static func fetch(address: String, timeout: TimeInterval = 12) async throws -> RemoteAIConfig {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RemoteConfigError.badURL }
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard let url = URL(string: text) else { throw RemoteConfigError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        // 每次都拿最新的：配置是运营随时改的，缓存没有意义
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RemoteConfigError.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(RemoteAIConfig.self, from: data)
        } catch {
            throw RemoteConfigError.decode(String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
    }
}
