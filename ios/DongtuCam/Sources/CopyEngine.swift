import Foundation

// MARK: - 数据模型（与 skill 的三段式公式一一对应）

struct Product: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let sellingPoint: String
    let person: String
    let person2: String
    let change: String
    let reaction: String
    let priceAnchor: String
    let keywords: [String]
}

struct CopyTemplate: Codable {
    let id: String
    let lines: [String]
}

struct RuleBook: Codable {
    let version: String
    let source: String
    let formula: String
    let principles: [String]
    let placeholders: [String]
    let templates: [CopyTemplate]
}

private extension Bundle {
    func decode<T: Decodable>(_ type: T.Type, resource: String) -> T? {
        let name = (resource as NSString).deletingPathExtension
        let ext = (resource as NSString).pathExtension
        guard let url = self.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - 自动匹配商品文案

/// 完全离线：商品库 + 规则模板，不依赖网络、不依赖工作台。
/// 需要 LLM 时把 remoteEndpoint 填成自己的 PHP/Node 接口，失败自动回退离线模板。
final class CopyEngine: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var lines: [String] = []
    @Published var selected: Product? {
        didSet { regenerate() }
    }

    /// POST {"product":...,"category":...,"selling_point":...,"keywords":[...]}
    /// 返回 {"lines":["...","..."]}；不填则纯离线
    var remoteEndpoint: String?

    private let rules: RuleBook?
    private var cursor = 0
    private static let lastKey = "dtc.lastProduct"

    init() {
        self.rules = Bundle.main.decode(RuleBook.self, resource: "rules.json")
        let list = Bundle.main.decode([Product].self, resource: "products.json") ?? []
        self.products = list
        let last = UserDefaults.standard.string(forKey: Self.lastKey)
        self.selected = list.first { $0.id == last } ?? list.first
        regenerate()
    }

    /// 关键词自动匹配商品：可传商品名、扫码结果、剪贴板文字
    @discardableResult
    func match(_ text: String) -> Product? {
        let q = text.lowercased()
        guard let hit = products.first(where: { p in
            q.contains(p.name.lowercased()) || p.keywords.contains { q.contains($0.lowercased()) }
        }) else { return nil }
        select(hit)
        return hit
    }

    func select(_ product: Product) {
        selected = product
        UserDefaults.standard.set(product.id, forKey: Self.lastKey)
    }

    /// 换一条：按模板轮播，每次都是「具体的人 + 已发生的变化 + 第三方反应」
    func regenerate() {
        guard let product = selected,
              let rules = rules,
              !rules.templates.isEmpty else {
            lines = []
            return
        }
        let template = rules.templates[cursor % rules.templates.count]
        cursor += 1
        lines = template.lines.map { Self.fill($0, with: product) }
    }

    /// 后端文案（可选）。任何失败都回退到离线模板，保证拍完一定能出片。
    func regenerateFromServer() async {
        guard let endpoint = remoteEndpoint,
              let url = URL(string: endpoint),
              let product = selected else {
            await MainActor.run { self.regenerate() }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 6
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "product": product.name,
            "category": product.category,
            "selling_point": product.sellingPoint,
            "keywords": product.keywords
        ])
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let payload = try JSONDecoder().decode([String: [String]].self, from: data)
            let remote = (payload["lines"] ?? []).filter { !$0.isEmpty }
            await MainActor.run {
                if remote.isEmpty { self.regenerate() } else { self.lines = remote }
            }
        } catch {
            await MainActor.run { self.regenerate() }
        }
    }

    private static func fill(_ line: String, with p: Product) -> String {
        let map: [String: String] = [
            "{pname}": p.name,
            "{category}": p.category,
            "{point}": p.sellingPoint,
            "{person}": p.person,
            "{person2}": p.person2,
            "{change}": p.change,
            "{reaction}": p.reaction,
            "{price}": p.priceAnchor
        ]
        var out = line
        for (key, value) in map {
            out = out.replacingOccurrences(of: key, with: value)
        }
        return out
    }
}
