import Foundation
import Combine

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

// MARK: - 文案引擎

/// 两条路：
/// 1. AI（配置了 Key）：按 CopySkill 的三段式规范生成，每拍一次都是新文案；
/// 2. 本地（未配置或接口失败）：模板随机轮播，保证任何情况下都能出片。
final class CopyEngine: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var lines: [String] = []
    @Published private(set) var selected: Product?

    /// 当前文案来源，界面上显示「AI」或「本地」
    @Published private(set) var badge: String = "本地"
    /// 识别 / AI 的一句话反馈
    @Published private(set) var note: String?

    private let rules: RuleBook?
    private var lastTemplateIndex = -1
    private static let lastKey = "dtc.lastProduct"

    init() {
        self.rules = Bundle.main.decode(RuleBook.self, resource: "rules.json")
        let list = Bundle.main.decode([Product].self, resource: "products.json") ?? []
        self.products = list
        let last = UserDefaults.standard.string(forKey: Self.lastKey)
        self.selected = list.first { $0.id == last } ?? list.first
        regenerateLocal()
    }

    // MARK: 选品

    /// 关键词自动匹配商品：可传商品名、扫码结果、剪贴板文字
    @discardableResult
    func match(_ text: String) -> Product? {
        let query = text.lowercased()
        guard let hit = products.first(where: { product in
            query.contains(product.name.lowercased())
                || product.keywords.contains { query.contains($0.lowercased()) }
        }) else { return nil }
        select(hit)
        return hit
    }

    func select(_ product: Product) {
        selected = product
        UserDefaults.standard.set(product.id, forKey: Self.lastKey)
        note = nil
        regenerateLocal()
    }

    // MARK: 本地模板

    func regenerate() {
        regenerateLocal()
    }

    private func regenerateLocal() {
        guard let product = selected, let rules, !rules.templates.isEmpty else {
            lines = []
            return
        }
        var index = Int.random(in: 0..<rules.templates.count)
        if rules.templates.count > 1 {
            var guardCount = 0
            while index == lastTemplateIndex && guardCount < 8 {
                index = Int.random(in: 0..<rules.templates.count)
                guardCount += 1
            }
        }
        lastTemplateIndex = index
        lines = rules.templates[index].lines.map { Self.fill($0, with: product) }
        badge = "本地"
    }

    private static func fill(_ line: String, with product: Product) -> String {
        let map: [String: String] = [
            "{pname}": product.name,
            "{category}": product.category,
            "{point}": product.sellingPoint,
            "{person}": product.person,
            "{person2}": product.person2,
            "{change}": product.change,
            "{reaction}": product.reaction,
            "{price}": product.priceAnchor
        ]
        var out = line
        for (key, value) in map {
            out = out.replacingOccurrences(of: key, with: value)
        }
        return out
    }

    // MARK: AI 生成

    /// 生成一条 AI 文案。失败会自动回退本地模板，并写进 note 供界面提示。
    @discardableResult
    func generateWithAI(config: AIConfig,
                        recognition: Recognition?,
                        imageJPEG: Data? = nil) async -> Bool {
        let catalog = products
        guard !catalog.isEmpty else { return false }

        let system = CopySkill.systemPrompt(products: catalog)
        let user = CopySkill.userPrompt(recognition: recognition, current: selected)
        do {
            let raw = try await AIService.chat(config: config, system: system,
                                               user: user, imageJPEG: imageJPEG)
            guard let output = CopySkill.parse(raw) else {
                throw AIError.decode(raw)
            }
            await MainActor.run {
                if let id = output.productID,
                   let hit = catalog.first(where: { $0.id == id }),
                   hit.id != self.selected?.id {
                    // 直接赋値，避免走 select() 把刚生成的文案又覆盖回模板
                    self.selected = hit
                    UserDefaults.standard.set(hit.id, forKey: Self.lastKey)
                }
                self.lines = output.lines
                self.badge = "AI"
                self.note = "AI 文案 · " + (self.selected?.name ?? "")
            }
            return true
        } catch {
            await MainActor.run {
                self.badge = "本地"
                self.note = "AI 未成功，已用本地文案（\(error.localizedDescription)）"
                self.regenerateLocal()
            }
            return false
        }
    }

    /// 手动「换一条」：配了 Key 就用 AI，否则本地轮播
    func refresh(config: AIConfig, recognition: Recognition?) async {
        if config.enabled, !config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            await generateWithAI(config: config, recognition: recognition)
        } else {
            await MainActor.run { self.regenerateLocal() }
        }
    }
}
