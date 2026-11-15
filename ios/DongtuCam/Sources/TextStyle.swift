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
///    以前是「预览 13pt → 按屏宽换算成像素」，只要预览的排版和成片的排版
///    有半点不一样（字体、行高、描边），两边就会慢慢对不上。
/// 2. **位置用归一化中心点**。`(0.5, 0.135)` 表示水平居中、纵向 13.5% 处。
///    拖动改的就是这两个数，存下来下次直接用。
/// 3. **只有一套渲染代码**（`TextLayer`）。预览是把画布换成屏幕尺寸去调它，
///    不是另写一份 SwiftUI 文本 —— 所以字体、描边、字距永远一致。
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

    init(fontKey: String = TextFont.heavy.key,
         sizeRatio: CGFloat = 0.042,
         centerX: CGFloat = 0.5,
         centerY: CGFloat = 0.135,
         lineSpacing: CGFloat = 1.26) {
        self.fontKey = fontKey
        self.sizeRatio = sizeRatio
        self.centerX = centerX
        self.centerY = centerY
        self.lineSpacing = lineSpacing
    }

    var font: TextFont { TextFont(rawValue: fontKey) ?? .heavy }

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

/// 样式记忆：字体、字号、位置存本地，下次打开直接沿用。
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

    private static let storageKey = "dtc.textStyle.v1"
    /// 拖动/捏合时每秒会产生几十次变更，没必要每次都写盘。
    /// 合并成「停手 0.35 秒后写一次」，手感更稳，也不会有写丢的风险。
    private var saveWork: DispatchWorkItem?

    init() {
        style = Self.load()
    }

    /// 一键回到出厂排版（位置回到画面上部居中、粗黑 4.2%）
    func reset() {
        style = TextStyle()
    }

    private static func load() -> TextStyle {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(TextStyle.self, from: data) else {
            return TextStyle()
        }
        return decoded
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
