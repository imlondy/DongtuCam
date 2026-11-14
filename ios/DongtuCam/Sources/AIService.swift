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

    @Published var config: AIConfig = AIConfig() {
        didSet { persist() }
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
