import Foundation

/// 「动图带货文案」技能：把 dongtu-viral-copy 的三段式公式 + 合规红线
/// 固化成提示词，任何 OpenAI 兼容模型都能按同一套标准写。
enum CopySkill {
    static let version = "dongtu-copy v2"

    struct Output {
        var productID: String?
        var lines: [String] = []
    }

    /// 单行最大字数（超过就压字号，会看不清，所以生成前先卡住）
    static let maxLineLength = 16

    // MARK: - 提示词

    static func systemPrompt(products: [Product]) -> String {
        let catalog = products.map { product -> String in
            let keywords = product.keywords.joined(separator: "/")
            return "- id=\(product.id) | 名称=\(product.name) | 类别=\(product.category)"
                + " | 卖点=\(product.sellingPoint) | 关键词=\(keywords)"
        }.joined(separator: "\n")

        return """
        你是一名抖音「动图带货」文案写手。用户拍的是 5 秒实况照片，你的文案会整段常驻画面顶部。

        # 结构公式（必须严格遵守）
        具体的人 + 已发生的变化 + 第三方的反应
        · 第 1 行：出现一个具体的人（我妈 / 婆婆 / 室友 / 同事 / 楼下阿姨 / 送快递的小哥…），禁止「很多人、大家、朋友、有人」
        · 第 2 行：一件已经发生、能被看见的具体变化，带时间、数量或动作细节
        · 第 3 行：由另一个人发出的反应，用中文引号包住一句口语，或写一个立刻索要链接的动作

        # 硬性约束
        · 正好 3 行，每行 6~14 个汉字，行末不加句号
        · 只写结果，不写过程，不出现「因为、所以」
        · 不用 emoji、不加话题标签、感叹号最多一个「!!」
        · 禁止任何医疗或功效承诺：治疗、调理、降三高、降糖、抗癌、增强免疫 一律不许出现
        · 禁止极限词：最、第一、绝对、百分百、国家级
        · 最多出现一个价格锚点（例如「一顿不到二十」）
        · 口语化，主谓宾清楚，10 秒内能读完
        · 商品名必须照抄清单里的「名称」，不要自创

        # 商品清单
        \(catalog)

        # 输出格式
        只输出一个 JSON，不要解释、不要 Markdown 代码块：
        {"product_id":"<清单里的 id；画面看不出就填 null>","lines":["第1行","第2行","第3行"]}
        """
    }

    static func userPrompt(recognition: Recognition?, current: Product?) -> String {
        var parts: [String] = []
        let ocr = recognition?.ocrLines.joined(separator: " / ") ?? ""
        parts.append("画面识别到的文字：" + (ocr.isEmpty ? "（无）" : ocr))
        let labels = recognition?.labels.joined(separator: ", ") ?? ""
        parts.append("图像识别标签：" + (labels.isEmpty ? "（无）" : labels))
        if let current {
            parts.append("当前选中的商品：\(current.name)")
        }
        parts.append("请判断画面里是哪个商品，并按公式写 3 行文案。")
        return parts.joined(separator: "\n")
    }

    // MARK: - 解析

    static func parse(_ raw: String) -> Output? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var output = Output()
        if let id = object["product_id"] as? String,
           !id.isEmpty, id.lowercased() != "null" {
            output.productID = id
        }

        if let lines = object["lines"] as? [String] {
            output.lines = lines
        } else if let lines = object["lines"] as? [Any] {
            output.lines = lines.compactMap { $0 as? String }
        }

        output.lines = output.lines
            .map(clean)
            .filter { !$0.isEmpty }
            .prefix(5)
            .map { $0 }

        guard !output.lines.isEmpty else { return nil }
        return output
    }

    private static func clean(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉模型常加的序号/项目符号
        while let first = text.first, "-•·*、".contains(first) {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("1.") || text.hasPrefix("2.") || text.hasPrefix("3.") {
            text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        if text.count > maxLineLength {
            text = String(text.prefix(maxLineLength))
        }
        return text
    }
}
