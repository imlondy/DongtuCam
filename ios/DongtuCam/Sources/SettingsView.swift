import SwiftUI

/// 设置页：**AI 参数全部由后台下发，这里只负责「指向后台」和「看状态」**。
///
/// 之前的版本把 Base URL / Key / 模型 / 视觉开关都摆在手机上，问题很实际：
/// 换一次 Key 就要重新签名装包；Key 明文躺在手机里；运营改不了任何东西。
/// 现在 App 只保留一个配置地址（`RemoteConfig` 的 GET 入口），
/// 其余项从后台 `config.php` 同步下来，改完刷新即可生效。
struct AISettingsView: View {
    @ObservedObject var settings: AISettings
    @ObservedObject var copyEngine: CopyEngine
    @Environment(\.dismiss) private var dismiss

    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        NavigationStack {
            Form {
                backendSection
                detectSection
                effectiveSection
                testSection
                skillSection
                productsSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: 后台

    private var backendSection: some View {
        Section {
            TextField("https://你的域名/dtc/config.php?token=…", text: $settings.remoteURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.system(size: 13, design: .monospaced))

            Button {
                Task { await settings.syncRemote() }
            } label: {
                HStack {
                    if settings.syncing { ProgressView().padding(.trailing, 6) }
                    Text(settings.syncing ? "同步中…" : "立即同步")
                }
            }
            .disabled(settings.syncing)

            if !settings.syncMessage.isEmpty {
                Text(settings.syncMessage)
                    .font(.footnote)
                    .foregroundStyle(settings.syncMessage.hasPrefix("已同步") ? .green : .orange)
            }
            if let last = settings.lastSync {
                Text("上次成功同步：" + Self.formatter.string(from: last))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("后台配置")
        } footer: {
            Text("""
            AI 的接口地址、Key、模型、识别开关都在后台改，App 里不再填。
            这里只填「配置地址」，点同步即可生效；拍之前会自动同步一次。
            拿不到配置不影响出片：AI 关闭，改用本地模板文案。
            """)
        }
    }

    // MARK: 自动识别

    private var detectSection: some View {
        Section {
            Toggle("举起商品自动识别并出文案", isOn: $settings.autoDetectOnCamera)
        } header: {
            Text("自动识别")
        } footer: {
            Text("""
            打开后，在相机里把商品对准画面停 2~3 秒，App 会自动判断是哪个商品，\
            并让 AI 写一条新文案（没配 AI 就换本地模板文案）。
            同一款商品不会重复请求 AI，换成另一款才会再次生成。
            """)
        }
    }

    // MARK: 当前生效（只读）

    private var effectiveSection: some View {
        Section {
            row("状态", settings.config.enabled ? "已启用" : "未启用（用本地模板）",
                ok: settings.config.enabled)
            row("模型", settings.config.model)
            row("接口", settings.config.baseURL)
            row("Key", maskedKey)
            row("拍摄时自动识别", settings.config.autoRecognize ? "开" : "关")
            row("画面发给视觉模型", settings.config.useVision ? "开" : "关")
            row("每次拍摄重新写文案", settings.config.autoGenerateOnShoot ? "开" : "关")
            if let note = settings.remoteNote, !note.isEmpty {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("当前生效（后台下发 · 只读）")
        }
    }

    private var maskedKey: String {
        let key = settings.config.apiKey
        guard !key.isEmpty else { return "未配置" }
        guard key.count > 10 else { return "已配置" }
        return key.prefix(4) + "…" + key.suffix(4)
    }

    private func row(_ title: String, _ value: String, ok: Bool? = nil) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Text(value)
                .font(.footnote)
                .foregroundStyle(ok == nil ? Color.secondary : (ok! ? Color.green : Color.orange))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: 自检

    private var testSection: some View {
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
            Text("用后台下发的地址/Key/模型发一句「只回复两个字：可以」，确认三者可用。")
        }
    }

    // MARK: 技能

    private var skillSection: some View {
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
    }

    private var productsSection: some View {
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

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

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
