import Foundation
import Combine

// MARK: - 配置

/// 兼容任意 OpenAI 格式的对话接口（DeepSeek / 通义 / 豆包 / Moonshot / OpenAI / 自建代理）
struct AIConfig: Codable, Equatable {
    var enabled: Bool = false
    var baseURL: String = "https://api.deepseek.com"
    var apiKey: String = ""
    var model: String = "deepseek-chat"
    var temperature: Double = 0.9

    /// 拍摄时用 OCR + 图像分类自动识别商品
    var autoRecognize: Bool = true
    /// 把画面帧直接发给支持视觉的模型（qwen-vl / doubao-vision / gpt-4o…）
    var useVision: Bool = false
    /// 每次拍摄都重新生成一条文案（关掉则沿用当前文案）
    var autoGenerateOnShoot: Bool = true
}

final class AISettings: ObservableObject {
    private static let storageKey = "dtc.ai.config.v1"
    private static let remoteKey = "dtc.ai.remote"
    private static let lastSyncKey = "dtc.ai.lastSync"

    @Published var config: AIConfig = AIConfig() {
        didSet { persist() }
    }

    /// 后台配置地址。这是唯一还留在 App 里的「参数」——它只决定去**哪里**拿参数，
    /// Base URL / Key / 模型 / 识别开关全部由后台下发（见 RemoteConfig）。
    @Published var remoteURL: String = UserDefaults.standard.string(forKey: AISettings.remoteKey) ?? "" {
        didSet { UserDefaults.standard.set(remoteURL, forKey: Self.remoteKey) }
    }
    @Published private(set) var lastSync: Date? =
        UserDefaults.standard.object(forKey: AISettings.lastSyncKey) as? Date
    @Published private(set) var syncMessage: String = ""
    @Published private(set) var syncing = false
    /// 后台附带的运营提示（如「本周主推陶瓷碗」）
    @Published private(set) var remoteNote: String?

    /// 打开相机就自动识别商品并匹配文案。
    ///
    /// 特意**不放进 `AIConfig`**：那个结构是从 UserDefaults 整体解码的，
    /// 加字段会让老版本存下的数据解码失败，用户的 Key 直接丢光。
    /// 单独一个键零风险。
    @Published var autoDetectOnCamera: Bool =
        (UserDefaults.standard.object(forKey: "dtc.ai.autoDetect") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoDetectOnCamera, forKey: "dtc.ai.autoDetect") }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(AIConfig.self, from: data) {
            config = saved
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// 有开关 + 有 Key 才算可用
    var isReady: Bool {
        config.enabled && !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 后台同步

    /// 拉一次后台配置。失败不影响任何功能：沿用上一次成功同步的值（或本地模板）。
    @MainActor
    func syncRemote() async {
        let address = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            syncMessage = "还没填后台地址，当前用上一次的配置"
            return
        }
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let remote = try await RemoteConfig.fetch(address: address)
            apply(remote)
            let now = Date()
            lastSync = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
            remoteNote = remote.note
            syncMessage = "已同步 · \(config.enabled ? "AI 开启" : "AI 关闭") · \(config.model)"
            Diagnostics.mark("remote.sync-ok")
        } catch {
            syncMessage = "同步失败：\(error.localizedDescription)"
            Diagnostics.mark("remote.sync-failed")
        }
    }

    /// 后台字段都是可选的：只覆盖它明确给了的项。
    @MainActor
    func apply(_ remote: RemoteAIConfig) {
        var next = config
        if let value = remote.enabled { next.enabled = value }
        if let value = remote.baseURL, !value.isEmpty { next.baseURL = value }
        if let value = remote.apiKey, !value.isEmpty { next.apiKey = value }
        if let value = remote.model, !value.isEmpty { next.model = value }
        if let value = remote.temperature { next.temperature = value }
        if let value = remote.autoRecognize { next.autoRecognize = value }
        if let value = remote.useVision { next.useVision = value }
        if let value = remote.autoGenerateOnShoot { next.autoGenerateOnShoot = value }
        config = next
    }
}

// MARK: - 网络

enum AIError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)
    case empty
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没填 API Key（右上齿轮 → AI 文案）"
        case .badURL:
            return "接口地址格式不对，应形如 https://api.deepseek.com"
        case .http(let code, let body):
            switch code {
            case 401, 403: return "API Key 无效或没有权限（\(code)）"
            case 402: return "账户余额不足（402）"
            case 404: return "接口地址不存在（404），检查 Base URL 末尾不要带 /v1/chat/completions"
            case 429: return "请求太频繁，稍后再试（429）"
            case 400, 415: return "模型不支持该请求（\(code)）：\(body.prefix(80))"
            default: return "接口返回 \(code)：\(body.prefix(80))"
            }
        case .empty:
            return "模型返回空内容"
        case .decode(let raw):
            return "模型返回格式异常：\(raw.prefix(80))"
        }
    }
}

enum AIService {
    /// 把用户填的 Base URL 补全成 /chat/completions
    static func endpoint(_ base: String) -> URL? {
        var text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        if text.lowercased().contains("/chat/completions") {
            return URL(string: text)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text + "/chat/completions")
    }

    /// 调用对话接口；imageJPEG 不为 nil 且开启 vision 时走多模态
    static func chat(config: AIConfig,
                     system: String,
                     user: String,
                     imageJPEG: Data? = nil,
                     timeout: TimeInterval = 30) async throws -> String {
        guard config.enabled else { throw AIError.notConfigured }
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIError.notConfigured }
        guard let url = endpoint(config.baseURL) else { throw AIError.badURL }

        let wantsVision = config.useVision && imageJPEG != nil
        do {
            return try await send(url: url, key: key, config: config,
                                  system: system, user: user,
                                  imageJPEG: wantsVision ? imageJPEG : nil,
                                  timeout: timeout)
        } catch AIError.http(let code, _) where wantsVision && (code == 400 || code == 415 || code == 422) {
            // 该模型多数情况下不支持图文混排，自动退回纯文本再试一次
            return try await send(url: url, key: key, config: config,
                                  system: system, user: user,
                                  imageJPEG: nil, timeout: timeout)
        }
    }

    private static func send(url: URL, key: String, config: AIConfig,
                             system: String, user: String,
                             imageJPEG: Data?, timeout: TimeInterval) async throws -> String {
        var userContent: Any = user
        if let data = imageJPEG {
            let parts: [[String: Any]] = [
                ["type": "text", "text": user],
                ["type": "image_url",
                 "image_url": ["url": "data:image/jpeg;base64,\(data.base64EncodedString())"]]
            ]
            userContent = parts
        }
        let messages: [[String: Any]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": userContent]
        ]
        let payload: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "temperature": config.temperature,
            "max_tokens": 600,
            "stream": false
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw AIError.http(http.statusCode, body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AIError.decode(String(data: data.prefix(300), encoding: .utf8) ?? "")
        }

        if let text = message["content"] as? String, !text.isEmpty {
            return text
        }
        // 部分网关会把 content 返回成分片数组
        if let parts = message["content"] as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            if !joined.isEmpty { return joined }
        }
        throw AIError.empty
    }
}
