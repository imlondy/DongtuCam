import SwiftUI
import UIKit

// MARK: - 文字样式

/// 文字样式：**预览、封面、动图三处共用同一份参数**。
///
/// 这是「所见即所得」的技术前提，也是 v25 最重要的重构：
///
/// 1. **字号用比例，不用磅值**。`sizeRatio = 字号 / 画布宽度`。
///    预览的画布是屏幕上的几百 pt，静帧是 2160px，动图是 1920px ——
///    同一个比例在三种尺寸上画出来的相对大小完全一致。
/// 2. **位置用归一化中心点**。`(0.5, 0.135)` 表示水平居中、纵向 13.5% 处。
///    拖动改的就是这两个数，存下来下次直接用。
/// 3. **只有一套渲染代码**（`TextLayer`）。预览是把画布换成屏幕尺寸去调它，
///    不是另写一份 SwiftUI 文本 —— 所以字体、描边、字距、颜色永远一致。
///
/// ## v26 新增
///
/// - 文字颜色 / 描边颜色 / 背景色（`TextPalette` / `TextOutline` / `TextBackground`）；
/// - 存档向后兼容：v25 存下的「字体 + 字号 + 位置」继续沿用，新字段取默认值。
struct TextStyle: Codable, Equatable {
    /// 字体标识，见 `TextFont`
    var fontKey: String
    /// 字号 / 画布宽度。0.042 在 1080 宽的静帧上是 45px
    var sizeRatio: CGFloat
    /// 文字块中心点（归一化 0...1，相对成片画面）
    var centerX: CGFloat
    var centerY: CGFloat
    /// 行高倍数
    var lineSpacing: CGFloat
    /// 文字颜色主色（引号内的强调色由调色板自带，避免用户挑色后整段花花绿绿）
    var colorKey: String
    /// 文字底色块
    var bgKey: String
    /// 底色不透明度
    var bgOpacity: CGFloat
    /// 描边（默认深色，白字压在浅色商品上时才看得清）
    var outlineKey: String

    init(fontKey: String = TextFont.heavy.key,
         sizeRatio: CGFloat = 0.042,
         centerX: CGFloat = 0.5,
         centerY: CGFloat = 0.135,
         lineSpacing: CGFloat = 1.26,
         colorKey: String = TextPalette.white.rawValue,
         bgKey: String = TextBackground.none.rawValue,
         bgOpacity: CGFloat = 0.46,
         outlineKey: String = TextOutline.dark.rawValue) {
        self.fontKey = fontKey
        self.sizeRatio = sizeRatio
        self.centerX = centerX
        self.centerY = centerY
        self.lineSpacing = lineSpacing
        self.colorKey = colorKey
        self.bgKey = bgKey
        self.bgOpacity = bgOpacity
        self.outlineKey = outlineKey
    }

    // MARK: 解码（v25 存档兼容）

    /// 手写解码：**新增字段缺失时回落到默认值**，而不是整条存档作废。
    /// 用合成的 Codable 会怎样？只要 `colorKey` 不在存档里，`decode` 直接抛错，
    /// 于是 `TextStyleStore.load()` 退回出厂值 —— 用户辛苦调好的字体、字号、
    /// 位置全被一次版本升级抹掉。这种事不该发生。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TextStyle()
        fontKey = (try? c.decode(String.self, forKey: .fontKey)) ?? fallback.fontKey
        sizeRatio = (try? c.decode(CGFloat.self, forKey: .sizeRatio)) ?? fallback.sizeRatio
        centerX = (try? c.decode(CGFloat.self, forKey: .centerX)) ?? fallback.centerX
        centerY = (try? c.decode(CGFloat.self, forKey: .centerY)) ?? fallback.centerY
        lineSpacing = (try? c.decode(CGFloat.self, forKey: .lineSpacing)) ?? fallback.lineSpacing
        colorKey = (try? c.decode(String.self, forKey: .colorKey)) ?? fallback.colorKey
        bgKey = (try? c.decode(String.self, forKey: .bgKey)) ?? fallback.bgKey
        bgOpacity = (try? c.decode(CGFloat.self, forKey: .bgOpacity)) ?? fallback.bgOpacity
        outlineKey = (try? c.decode(String.self, forKey: .outlineKey)) ?? fallback.outlineKey
    }

    var font: TextFont { TextFont(rawValue: fontKey) ?? .heavy }
    var palette: TextPalette { TextPalette(rawValue: colorKey) ?? .white }
    var background: TextBackground { TextBackground(rawValue: bgKey) ?? .none }
    var outline: TextOutline { TextOutline(rawValue: outlineKey) ?? .dark }

    /// 字号下限/上限（占画布宽度）。再小看不清，再大会把商品盖住。
    static let minSizeRatio: CGFloat = 0.020
    static let maxSizeRatio: CGFloat = 0.110

    /// 拖动 / 缩放之后统一收口：既限制字号范围，也保证文字块**整体留在画面内**。
    /// 半宽按文字块实际尺寸算，不是拍脑袋的固定边距 —— 否则长句子会被裁掉一半。
    mutating func clampToCanvas(blockSize: CGSize, canvas: CGSize) {
        sizeRatio = min(Self.maxSizeRatio, max(Self.minSizeRatio, sizeRatio))
        guard canvas.width > 1, canvas.height > 1 else { return }
        let halfW = min(0.5, blockSize.width / canvas.width / 2)
        let halfH = min(0.5, blockSize.height / canvas.height / 2)
        centerX = min(1 - halfW, max(halfW, centerX))
        centerY = min(1 - halfH, max(halfH, centerY))
    }
}

// MARK: - 文字颜色

/// 文字配色。每项带**主色 + 强调色**：
/// 引号内的卖点、行尾「!!」用强调色，正文用主色 ——
/// 这样挑任意颜色都还是一套设计，不会变成「一半红一半黄」的混乱。
enum TextPalette: String, CaseIterable, Identifiable {
    case white
    case cream
    case yellow
    case pink
    case red
    case blue
    case green
    case ink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "珍珠白"
        case .cream: return "奶油"
        case .yellow: return "亮黄"
        case .pink: return "樱粉"
        case .red: return "朱红"
        case .blue: return "冰蓝"
        case .green: return "薄荷"
        case .ink: return "墨黑"
        }
    }

    var color: UIColor {
        switch self {
        case .white: return UIColor(red: 1.0, green: 0.992, blue: 0.976, alpha: 1.0)
        case .cream: return UIColor(red: 1.0, green: 0.945, blue: 0.878, alpha: 1.0)
        case .yellow: return UIColor(red: 1.0, green: 0.855, blue: 0.235, alpha: 1.0)
        case .pink: return UIColor(red: 1.0, green: 0.592, blue: 0.706, alpha: 1.0)
        case .red: return UIColor(red: 1.0, green: 0.345, blue: 0.298, alpha: 1.0)
        case .blue: return UIColor(red: 0.612, green: 0.847, blue: 1.0, alpha: 1.0)
        case .green: return UIColor(red: 0.643, green: 0.965, blue: 0.667, alpha: 1.0)
        case .ink: return UIColor(red: 0.106, green: 0.102, blue: 0.114, alpha: 1.0)
        }
    }

    /// 引号内高亮 / 行尾双叹号
    var accent: UIColor {
        switch self {
        case .white, .ink: return UIColor(red: 1.0, green: 0.784, blue: 0.310, alpha: 1.0)
        case .cream: return UIColor(red: 1.0, green: 0.706, blue: 0.341, alpha: 1.0)
        case .yellow: return UIColor(red: 1.0, green: 0.976, blue: 0.780, alpha: 1.0)
        case .pink: return UIColor(red: 1.0, green: 0.870, blue: 0.918, alpha: 1.0)
        case .red: return UIColor(red: 1.0, green: 0.788, blue: 0.435, alpha: 1.0)
        case .blue: return UIColor(red: 1.0, green: 0.976, blue: 0.898, alpha: 1.0)
        case .green: return UIColor(red: 1.0, green: 0.949, blue: 0.616, alpha: 1.0)
        }
    }

    var swiftUIColor: Color { Color(color) }
}

// MARK: - 描边

/// 描边颜色。白字压浅色商品（奶白碗、米色桌布）时，黑边是唯一能保住辨识度的东西；
/// 反之深色字压在深色背景上要换白边。
enum TextOutline: String, CaseIterable, Identifiable {
    case dark
    case light
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "深描边"
        case .light: return "白描边"
        case .none: return "无描边"
        }
    }

    var color: UIColor? {
        switch self {
        case .dark: return UIColor(red: 0.09, green: 0.055, blue: 0.045, alpha: 1.0)
        case .light: return UIColor(white: 1.0, alpha: 0.94)
        case .none: return nil
        }
    }
}

// MARK: - 文字底色

/// 文字底色块。压在花哨的商品牌面/桌布上时，一整块底色比描边更稳。
enum TextBackground: String, CaseIterable, Identifiable {
    case none
    case dark
    case white
    case yellow
    case pink
    case blue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "无"
        case .dark: return "墨黑"
        case .white: return "奶白"
        case .yellow: return "亮黄"
        case .pink: return "樱粉"
        case .blue: return "冰蓝"
        }
    }

    var color: UIColor? {
        switch self {
        case .none: return nil
        case .dark: return UIColor(red: 0.055, green: 0.047, blue: 0.043, alpha: 1.0)
        case .white: return UIColor(red: 1.0, green: 0.988, blue: 0.965, alpha: 1.0)
        case .yellow: return UIColor(red: 1.0, green: 0.831, blue: 0.188, alpha: 1.0)
        case .pink: return UIColor(red: 1.0, green: 0.596, blue: 0.706, alpha: 1.0)
        case .blue: return UIColor(red: 0.549, green: 0.808, blue: 1.0, alpha: 1.0)
        }
    }
}

// MARK: - 字体

/// 可选字体。中文的宋/楷/手写必须用**具体字族**（named font），
/// `withDesign(.serif)` 只对拉丁字母生效，对汉字无效 —— 选了等于没选。
enum TextFont: String, CaseIterable, Identifiable {
    case heavy
    case rounded
    case songti
    case kaiti
    case hannotate

    var id: String { rawValue }
    /// 存进 UserDefaults 的键
    var key: String { rawValue }

    var title: String {
        switch self {
        case .heavy: return "粗黑"
        case .rounded: return "圆体"
        case .songti: return "宋体"
        case .kaiti: return "楷体"
        case .hannotate: return "手写"
        }
    }

    /// 系统里是否真的有这套字。个别机型/系统版本缺字族，
    /// 那种字体就不出现在选择器里 —— 免得「选了宋体却显示黑体」这种说不清的坑。
    var isAvailable: Bool {
        switch self {
        case .heavy:
            return true
        case .rounded:
            return UIFont.systemFont(ofSize: 12, weight: .bold)
                .fontDescriptor.withDesign(.rounded) != nil
        default:
            return candidates.contains { UIFont(name: $0, size: 12) != nil }
        }
    }

    /// 字族的候选 PostScript 名。老系统/新系统的命名不一样，逐个试。
    private var candidates: [String] {
        switch self {
        case .songti:
            return ["SongtiSC-Bold", "STSongti-SC-Bold", "SongtiSC-Black", "STSongti-SC-Black"]
        case .kaiti:
            return ["KaitiSC-Bold", "STKaiti-SC-Bold", "KaitiSC-Black"]
        case .hannotate:
            return ["HannotateSC-W5", "HannotateSC-W7", "HanziPenSC-W5", "HanziPenSC-W3"]
        case .heavy, .rounded:
            return []
        }
    }

    func uiFont(size: CGFloat) -> UIFont {
        switch self {
        case .heavy:
            return UIFont.systemFont(ofSize: size, weight: .heavy)
        case .rounded:
            let base = UIFont.systemFont(ofSize: size, weight: .bold)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
            return UIFont(descriptor: descriptor, size: size)
        case .songti, .kaiti, .hannotate:
            for name in candidates {
                if let font = UIFont(name: name, size: size) { return font }
            }
            // 找不到就退回粗黑，至少不会出豆腐块
            return UIFont.systemFont(ofSize: size, weight: .heavy)
        }
    }

    /// 选择器里要显示的字体。当前选中的一定带上，
    /// 否则界面会出现「没有任何一项被选中」的空白状态。
    static func pickable(including key: String) -> [TextFont] {
        var list = allCases.filter { $0.isAvailable }
        if let current = TextFont(rawValue: key), !list.contains(current) {
            list.insert(current, at: 0)
        }
        return list.isEmpty ? [.heavy] : list
    }
}

// MARK: - 持久化

/// 样式记忆：字体、字号、位置、颜色存本地，下次打开直接沿用。
///
/// 只存样式，**不存文字内容** —— 内容每次由 AI / 模板 / 手动编辑产生，
/// 存下来会让人下次打开看到昨天那句不相干的话。
final class TextStyleStore: ObservableObject {
    @Published var style: TextStyle {
        didSet {
            guard style != oldValue else { return }
            scheduleSave()
        }
    }

    /// v2：字段变多了，但**键名不变**（解码兼容 v1 存档）。
    private static let storageKey = "dtc.textStyle.v2"
    private static let legacyKey = "dtc.textStyle.v1"
    /// 拖动/捏合时每秒会产生几十次变更，没必要每次都写盘。
    /// 合并成「停手 0.35 秒后写一次」，手感更稳，也不会有写丢的风险。
    private var saveWork: DispatchWorkItem?

    init() {
        style = Self.load()
    }

    /// 一键回到出厂排版（位置回到画面上部居中、粗黑 4.2%、白字黑边无底）
    func reset() {
        style = TextStyle()
    }

    private static func load() -> TextStyle {
        let decoder = JSONDecoder()
        // 先读 v2；没有就继承 v1 里用户调好的字体/字号/位置（新字段自动取默认值）
        for key in [storageKey, legacyKey] {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? decoder.decode(TextStyle.self, from: data) else { continue }
            return decoded
        }
        return TextStyle()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        // 捕捉当前值，不依赖执行时的 self.style（那时可能又变了）
        let snapshot = style
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

// MARK: - 预览坐标映射

extension TextStyle {
    /// 成片画面在预览里占据的矩形（`resizeAspectFill`）。
    ///
    /// 相机预览层按 aspectFill 铺满全屏，会裁掉两边；文字必须按**同一个映射**
    /// 摆上去，否则「预览里在商品左上角、成片里跑到中间」。
    ///
    /// v26 起预览改成 **3:4 取景框**（画面完整可见），这个函数的结果
    /// 就是取景框本身；保留 aspectFill 的写法，是为了格式回落到 16:9 时也不跑偏。
    ///
    /// - Parameters:
    ///   - aspect: 成片画面的 宽/高（显示方向，3:4 = 0.75）
    ///   - view: 预览视图尺寸
    static func filledRect(aspect: CGFloat, in view: CGSize) -> CGRect {
        let safeAspect = (aspect.isFinite && aspect > 0.05) ? aspect : 0.75
        guard view.width > 1, view.height > 1 else { return .zero }
        let scale = max(view.width / safeAspect, view.height)
        let size = CGSize(width: safeAspect * scale, height: scale)
        return CGRect(x: (view.width - size.width) / 2,
                      y: (view.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

// MARK: - 安全区

/// 抖音发布后的「安全区」。
///
/// 同一张 3:4 画面，在不同机型上按 aspectFill 铺满屏幕：屏幕越窄，两边裁得越多；
/// 底部的文案条/音乐条、右侧的头像+点赞评论按钮则永远压在画面上。
/// 文字落进这些位置，用户在自己手机上看得到，发出去就被挡了 —— 所以拖动时
/// 要有一条看得见的边界。
///
/// 比例是**相对成片画面**的，不是屏幕：这样在任何机型上提示都一致。
enum TextSafeZone {
    /// 顶部：抖音顶部有「关注 / 推荐」和搜索，约占 5%
    static let top: CGFloat = 0.05
    /// 底部：文案 + 音乐 + 进度条，约占 24%
    static let bottom: CGFloat = 0.76
    /// 左右：窄屏 aspectFill 会裁边，右侧还有功能按钮
    static let left: CGFloat = 0.04
    static let right: CGFloat = 0.84

    static func rect(in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + frame.width * left,
               y: frame.minY + frame.height * top,
               width: frame.width * max(0.1, right - left),
               height: frame.height * max(0.1, bottom - top))
    }

    /// 文字块是否完整落在安全区内（容差 0.5pt，避免浮点抖动一直报警）
    static func contains(_ block: CGRect, in frame: CGRect) -> Bool {
        guard block.width > 1, block.height > 1 else { return true }
        return rect(in: frame).insetBy(dx: -0.5, dy: -0.5).contains(block)
    }
}
