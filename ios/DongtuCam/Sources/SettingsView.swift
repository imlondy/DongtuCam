import SwiftUI

/// AI 文案设置：接口配置 + 连接自检 + 内置技能说明
struct AISettingsView: View {
    @ObservedObject var settings: AISettings
    @ObservedObject var copyEngine: CopyEngine
    @Environment(\.dismiss) private var dismiss

    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false
    /// 与 VideoBurner/OutputPrefs 共用同一个 key
    @AppStorage("dtc.burn.into.video") private var burnIntoVideo = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("启用 AI 文案", isOn: $settings.config.enabled)
                    Toggle("拍摄时自动识别商品", isOn: $settings.config.autoRecognize)
                    Toggle("每次拍摄重新生成文案", isOn: $settings.config.autoGenerateOnShoot)
                } header: {
                    Text("开关")
                } footer: {
                    Text("关闭 AI 时用内置模板（10 条轮换，并会随机避开上一条）。开启后每次拍摄都会按画面重新写一条。")
                }

                Section {
                    Toggle("文案也压进动图", isOn: $burnIntoVideo)
                } header: {
                    Text("输出")
                } footer: {
                    Text("""
                    开启：动图播放时也能看到文案，文字每一帧贴在同一位置，钉住不晃。
                    · 照片（封面）永远清晰，用原始首帧 1:1 合成
                    · 动图里的字要重新编码一次视频，画质有一次性轻微压缩
                    · 处理时间会多 1~3 秒；压字失败会自动退回「字只印在照片上」，不会让这一拍白费
                    关闭：只输出原始视频 + 带字照片（最快、最省电）
                    """)
                }

                Section {
                    TextField("接口地址", text: $settings.config.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API Key（sk-…）", text: $settings.config.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("模型名", text: $settings.config.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("把画面直接发给视觉模型", isOn: $settings.config.useVision)
                } header: {
                    Text("接口（OpenAI 格式通用）")
                } footer: {
                    Text("""
                    常用组合：
                    · DeepSeek：https://api.deepseek.com ＋ deepseek-chat（便宜、国内直连）
                    · 通义千问：https://dashscope.aliyuncs.com/compatible-mode/v1 ＋ qwen-plus，视觉用 qwen-vl-max
                    · 豆包：https://ark.cn-beijing.volces.com/api/v3 ＋ 你的推理接入点 id
                    · 自建 PHP/Node 代理：填自己的地址即可
                    """)
                }

                Section {
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack {
                            if testing { ProgressView().padding(.trailing, 6) }
                            Text(testing ? "测试中…" : "测试连接")
                        }
                    }
                    .disabled(testing || settings.config.apiKey.isEmpty)

                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(testOK ? .green : .red)
                    }
                } header: {
                    Text("自检")
                } footer: {
                    Text("测试只发一句「只回复 ok」，用来确认地址、Key、模型名三者是否可用。")
                }

                Section {
                    Text("具体的人 + 已发生的变化 + 第三方的反应")
                        .font(.subheadline.weight(.semibold))
                    ForEach(CopySkill.skillRules, id: \.self) { rule in
                        Text("· " + rule).font(.footnote)
                    }
                } header: {
                    Text("内置文案技能 \(CopySkill.version)")
                } footer: {
                    Text("AI 生成时会强制带上这套规范：正好 3 行、每行 6~14 字、禁医疗功效与极限词。")
                }

                Section("商品库（\(copyEngine.products.count) 个）") {
                    ForEach(copyEngine.products) { product in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.name).font(.subheadline.weight(.semibold))
                            Text(product.keywords.joined(separator: " / "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("AI 文案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func runTest() async {
        testing = true
        testResult = nil
        var config = settings.config
        config.enabled = true
        do {
            let reply = try await AIService.chat(config: config,
                                                 system: "你是连接测试助手。",
                                                 user: "只回复两个字：可以",
                                                 timeout: 20)
            testOK = true
            let snippet = String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            testResult = "连接成功，模型回复：" + snippet
        } catch {
            testOK = false
            testResult = "失败：" + error.localizedDescription
        }
        testing = false
    }
}

extension CopySkill {
    /// 设置页展示用的规范摘要
    static let skillRules: [String] = [
        "正好 3 行，每行 6~14 个汉字，行末不加句号",
        "第 1 行必须出现一个具体的人，不许「很多人/大家」",
        "第 2 行写已发生、看得见的具体变化（带时间或数量）",
        "第 3 行是第三方的反应，用引号包住一句口语或索要链接",
        "只写结果不写过程，不出现「因为/所以」",
        "禁止医疗功效（治疗、降三高、抗癌、增强免疫）",
        "禁止极限词（最、第一、绝对、百分百）",
        "最多一个价格锚点，不用 emoji 和话题标签"
    ]
}
