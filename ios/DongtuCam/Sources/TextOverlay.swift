import SwiftUI
import UIKit

// MARK: - 屏幕上的文字层

/// 画面上的文字层：渲染 + 拖动改位置 + 捏合改大小 + 点一下打开编辑。
///
/// ## 为什么不用 SwiftUI 的 `Text` 画预览
///
/// 因为成片是 `TextLayer` 画的（两遍绘制、自定义描边、自绘双叹号）。
/// 如果预览用 SwiftUI 的 `Text` + `.shadow`，字重、字距、描边厚度、换行位置
/// 全都不一样 —— 那就是「预览一个样、成片另一个样」，改字体时差得更明显。
///
/// 这里直接调 `TextLayer.renderBlock` 把文字画成一张图贴到屏幕上，
/// **和成片是同一段代码**，只是画布尺寸换成了屏幕上的矩形。
///
/// ## v26：安全区提示
///
/// 拖动（或打开编辑面板）时显示抖音的安全区虚线框。文字块一旦越界，
/// 框变红、底部弹出提示 —— 因为越界的字在用户的手机上看得见，
/// 发出去却被底部的文案条、右侧的按钮盖住。
struct TextOverlay: View {
    let lines: [String]
    @Binding var style: TextStyle
    /// 成片画面的宽高比（显示方向：3:4 = 0.75）
    let aspect: CGFloat
    /// 是否常显安全区（编辑面板打开时由父视图打开）
    var showGuides: Bool = false
    /// 点文字触发（打开编辑面板）
    var onTap: () -> Void = {}

    @Environment(\.displayScale) private var displayScale

    /// 文字块在屏幕上的实际尺寸，拖动时用来防止把字拖出画面 / 判断安全区
    @State private var blockSize: CGSize = .zero
    @State private var dragOrigin: CGPoint?
    @State private var pinchOrigin: CGFloat?
    /// 正在拖：即便面板没开也临时显示安全区
    @State private var dragging = false
    /// 用户动过文字没有。
    ///
    /// 为什么要这个开关：默认位置本来就贴着画面上部，5 行的长文案会有一点
    /// 探进顶部区域。一打开面板就满屏红光报「超出」，属于狼来了 ——
    /// 真正的语义是「你**移动**文字时告诉你边界在哪」。
    @State private var interacted = false

    var body: some View {
        GeometryReader { geo in
            // 成片画面在预览里占据的矩形（v26 起就是 3:4 取景框本身）
            let filled = TextStyle.filledRect(aspect: aspect, in: geo.size)
            let scale = min(max(displayScale, 1), 3)
            // 取景框完整可见后，可用宽度就是整幅画面（0.92 是左右各留 4% 的呼吸位）
            let ratio = Self.widthRatio(visible: geo.size.width, canvas: filled.width)
            let block = blockRect(in: filled)
            let guides = showGuides || dragging
            let unsafe = guides && (dragging || interacted)
                && !TextSafeZone.contains(block, in: filled)

            ZStack {
                if guides {
                    safeGuide(filled: filled, unsafe: unsafe)
                }

                TextBlockImage(lines: lines,
                               style: style,
                               canvas: filled.size,
                               scale: scale,
                               maxWidthRatio: ratio)
                .equatable()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: TextBlockSizeKey.self, value: proxy.size)
                    }
                )
                .position(x: filled.minX + style.centerX * filled.width,
                          y: filled.minY + style.centerY * filled.height)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                .gesture(dragGesture(filled: filled))
                .simultaneousGesture(magnifyGesture(filled: filled))
                .onPreferenceChange(TextBlockSizeKey.self) { size in
                    blockSize = size
                }

                if unsafe {
                    warningBadge(filled: filled)
                }
            }
            // 刚越界时给一次轻微震动：手指挡着画面，光靠视觉不一定看得到虚线变色
            .onChange(of: unsafe) { now in
                guard now else { return }
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            }
            // 把「看得见的宽度占比」上报给主界面：出片时要用同一个数，
            // 否则预览里不溢出的句子，成片里可能被挤小或溢出
            .preference(key: TextWidthRatioKey.self, value: ratio)
        }
        .allowsHitTesting(!lines.isEmpty)
    }

    /// 文字块在屏幕上的矩形（用于安全区判断）
    private func blockRect(in filled: CGRect) -> CGRect {
        guard blockSize.width > 1, blockSize.height > 1 else { return .zero }
        let cx = filled.minX + style.centerX * filled.width
        let cy = filled.minY + style.centerY * filled.height
        return CGRect(x: cx - blockSize.width / 2,
                      y: cy - blockSize.height / 2,
                      width: blockSize.width,
                      height: blockSize.height)
    }

    /// 文字块可用宽度占画面的比例。
    ///
    /// v26 起取景框就是完整的 3:4 画面（不再 aspectFill 裁边），
    /// 所以这个值稳定在 0.96 → 收口到 0.92。保留这套算法是为了
    /// 相机格式回落到别的比例时依然自洽。
    static func widthRatio(visible: CGFloat, canvas: CGFloat) -> CGFloat {
        guard canvas > 1, visible > 1 else { return 0.92 }
        return min(0.92, max(0.42, (visible / canvas) * 0.96))
    }

    // MARK: 安全区

    private func safeGuide(filled: CGRect, unsafe: Bool) -> some View {
        let rect = TextSafeZone.rect(in: filled)
        return ZStack(alignment: .topLeading) {
            // 越界时把安全区外部压暗一点：一眼看出「字跑到危险地带了」
            if unsafe {
                Path { path in
                    path.addRect(filled)
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.28), style: FillStyle(eoFill: true))
            }
            Path { path in
                path.addRect(rect)
            }
            .stroke(unsafe ? Color.red.opacity(0.95) : Color.white.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            Text("安全区")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(unsafe ? Color.red.opacity(0.95) : Color.white.opacity(0.6))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(.black.opacity(0.35), in: Capsule())
                .offset(x: rect.minX + 6, y: rect.minY + 6)
        }
        .allowsHitTesting(false)
    }

    private func warningBadge(filled: CGRect) -> some View {
        Text("文字超出安全区 · 发抖音可能被按钮/文案条遮挡")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.red.opacity(0.86), in: Capsule())
            .position(x: filled.midX, y: max(filled.minY + 16, filled.maxY - 22))
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: 手势

    /// 拖动改位置。归一化增量按**画面矩形**算，不是按屏幕 ——
    /// 屏幕比画面宽（aspectFill 裁掉两边），按屏幕算会「拖一点跑很远」。
    private func dragGesture(filled: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard filled.width > 1, filled.height > 1 else { return }
                dragging = true
                interacted = true
                if dragOrigin == nil {
                    dragOrigin = CGPoint(x: style.centerX, y: style.centerY)
                }
                guard let origin = dragOrigin else { return }
                var next = style
                next.centerX = origin.x + value.translation.width / filled.width
                next.centerY = origin.y + value.translation.height / filled.height
                next.clampToCanvas(blockSize: blockSize, canvas: filled.size)
                style = next
            }
            .onEnded { _ in
                dragOrigin = nil
                // 松手后让安全区再多停留一会儿，方便看清落点
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    dragging = false
                }
            }
    }

    /// 双指捏合改字号。以手势开始时的字号为基准，避免连续缩放累积误差。
    private func magnifyGesture(filled: CGRect) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                dragging = true
                interacted = true
                if pinchOrigin == nil { pinchOrigin = style.sizeRatio }
                guard let origin = pinchOrigin else { return }
                var next = style
                next.sizeRatio = origin * value
                next.clampToCanvas(blockSize: blockSize, canvas: filled.size)
                style = next
            }
            .onEnded { _ in
                pinchOrigin = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    dragging = false
                }
            }
    }
}

// MARK: - 文字块图像

/// 只负责把文字块画成一张图。
///
/// **`Equatable` 是关键**：拖动只改中心点，不影响文字本身的像素。
/// 若不加这一层，SwiftUI 每一帧都会重建视图、重绘文字（一秒几十次），拖动会明显掉帧。
/// 加了之后 `==` 依然成立，SwiftUI 直接跳过重建 —— 拖起来是跟手的。
struct TextBlockImage: View, Equatable {
    let lines: [String]
    let style: TextStyle
    let canvas: CGSize
    let scale: CGFloat
    let maxWidthRatio: CGFloat

    static func == (lhs: TextBlockImage, rhs: TextBlockImage) -> Bool {
        lhs.lines == rhs.lines
            && lhs.style == rhs.style
            && lhs.canvas == rhs.canvas
            && lhs.scale == rhs.scale
            && lhs.maxWidthRatio == rhs.maxWidthRatio
    }

    /// 中心点固定 0.5/0.5：文字块图像的内容与位置无关，
    /// 实际摆在哪里由外层 `.position` 决定。
    private var localStyle: TextStyle {
        var local = style
        local.centerX = 0.5
        local.centerY = 0.5
        return local
    }

    var body: some View {
        if let block = TextLayer.renderBlock(lines: lines, style: localStyle,
                                             canvas: canvas, scale: scale,
                                             maxWidthRatio: maxWidthRatio) {
            Image(decorative: block.image, scale: scale)
        } else {
            // 没有可排的文字时给个 1pt 的占位，避免外层拿到 nil 布局
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

/// 把「文字可用宽度占比」上报给主界面（出片时要用同一个值）
struct TextWidthRatioKey: PreferenceKey {
    static var defaultValue: CGFloat = 0.92
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 把文字块尺寸从子视图传回父视图（拖动时要按真实尺寸做边界钳制）
private struct TextBlockSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// MARK: - 光标定位请求

/// 插入表情后要把光标挪到表情后面。
/// SwiftUI 的 `TextEditor` 拿不到选区，所以这里用一个小结构体把
/// 「第几次请求 + 目标位置」传给 UITextView：id 变了才执行，不会反复抢光标。
struct CaretRequest: Equatable {
    let id: Int
    let location: Int
}

// MARK: - 带光标跟踪的文本框

/// 替代 `TextEditor` 的文本框。
///
/// 为什么不用 `TextEditor`：它不暴露选区，表情/文字插进去只能追加到末尾 ——
/// 用户把光标点到第二行中间，点个表情却跑到最后一行末尾，这不能算「支持表情」。
/// `UITextView` 有 `selectedRange`，插完还能把光标放到表情后面继续打字。
struct CopyTextView: UIViewRepresentable {
    @Binding var text: String
    var caret: CaretRequest?
    var onSelectionChange: (NSRange) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.textColor = .white
        view.tintColor = .systemYellow
        view.font = .systemFont(ofSize: 13)
        view.textContainerInset = UIEdgeInsets(top: 5, left: 4, bottom: 5, right: 4)
        view.textContainer.lineFragmentPadding = 2
        view.keyboardAppearance = .dark
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // 每次刷新都把最新的 bindings 交回 Coordinator：
        // Coordinator 是引用类型，持有的是旧快照，不更新会写到上一份状态里
        context.coordinator.parent = self
        // 只在内容真不一致时回写，否则每敲一个字光标都会被重置到开头
        if view.text != text {
            let selected = view.selectedRange
            view.text = text
            let limit = (text as NSString).length
            view.selectedRange = NSRange(location: min(selected.location, limit), length: 0)
        }
        if let caret, caret.id != context.coordinator.lastCaretID {
            context.coordinator.lastCaretID = caret.id
            let limit = (view.text as NSString).length
            view.selectedRange = NSRange(location: min(max(0, caret.location), limit), length: 0)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CopyTextView
        var lastCaretID = -1

        init(_ parent: CopyTextView) {
            self.parent = parent
            super.init()
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.onSelectionChange(textView.selectedRange)
        }
    }
}

// MARK: - 编辑面板

/// 文案编辑面板：内容 + 表情 + 字体 + 颜色 + 底色 + 字号，外加「拖动 / 捏合」提示。
///
/// 面板**不做成 sheet**，而是浮在相机上面 —— 只有这样才能边改边看，
/// 真正检验「成片就是现在这样」。sheet 一盖，所见即所得就无从谈起。
struct TextEditorPanel: View {
    @Binding var text: String
    @Binding var style: TextStyle
    /// 换一条（重新生成）
    var onRegenerate: () -> Void
    /// 排版回到默认（字体/字号/位置/颜色）
    var onResetLayout: () -> Void
    /// 收起面板
    var onDone: () -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case font = "字体"
        case color = "颜色"
        case background = "底色"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .font
    @State private var caret = CaretRequest(id: 0, location: 0)
    @State private var selection = NSRange(location: 0, length: 0)

    /// 热门表情：抖音/小红书评论区最常用的那一批。
    /// 都是标准 emoji 字符，会被系统彩色字体渲染，跟着文案一起烧进画面。
    private static let emojis: [String] = [
        "😍", "🥰", "😋", "🤤", "😎", "🤩", "🥳", "😆",
        "😭", "🥹", "🤔", "🫣", "😳", "🙈", "🫶", "👏",
        "👍", "💪", "🔥", "✨", "💯", "❤️", "🧡", "💛",
        "🎉", "🎁", "🛒", "💰", "🍜", "🥘", "🍲", "🦐",
        "🥩", "🍚", "🧋", "☕️", "🍓", "🌸", "🌿", "⭐️"
    ]

    private var fonts: [TextFont] {
        TextFont.pickable(including: style.fontKey)
    }

    var body: some View {
        VStack(spacing: 7) {
            header
            editor
            emojiRow
            tabRow
            tabContent
            sizeRow
            footer
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var header: some View {
        HStack {
            Text("文字")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.68))
            Spacer()
            Button(action: onDone) {
                Text("完成")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 5)
                    .background(Color.yellow, in: Capsule())
            }
        }
    }

    // MARK: 内容

    private var editor: some View {
        CopyTextView(text: $text, caret: caret) { range in
            selection = range
        }
        .frame(height: 54)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
        .overlay(alignment: .topLeading) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("每行一句，最多 5 行；引号内的词会自动高亮")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 11)
                    .allowsHitTesting(false)
            }
        }
    }

    private var emojiRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                // 用下标遍历：Swift 的 KeyPath 不能指向元组元素，
                // `ForEach(Array(x.enumerated()), id: \.offset)` 这种写法编译不过
                ForEach(Self.emojis.indices, id: \.self) { index in
                    Button {
                        insert(Self.emojis[index])
                    } label: {
                        Text(Self.emojis[index])
                            .font(.system(size: 18))
                            .frame(width: 30, height: 26)
                            .background(.white.opacity(0.09),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 26)
    }

    // MARK: 分页

    private var tabRow: some View {
        HStack(spacing: 7) {
            ForEach(Tab.allCases) { item in
                let active = tab == item
                Button {
                    tab = item
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(active ? Color.white.opacity(0.24) : Color.white.opacity(0.07),
                                    in: Capsule())
                        .foregroundStyle(active ? Color.white : Color.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .font:
            fontRow
        case .color:
            colorRow
        case .background:
            backgroundRow
        }
    }

    private var fontRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(fonts) { font in
                    let active = style.fontKey == font.key
                    Button {
                        style.fontKey = font.key
                    } label: {
                        Text(font.title)
                            .font(Font(font.uiFont(size: 13)))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(active ? Color.yellow : Color.white.opacity(0.14),
                                        in: Capsule())
                            .foregroundStyle(active ? Color.black : Color.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 54, alignment: .top)
    }

    private var colorRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(TextPalette.allCases) { palette in
                    let active = style.colorKey == palette.rawValue
                    Button {
                        style.colorKey = palette.rawValue
                    } label: {
                        Circle()
                            .fill(palette.swiftUIColor)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle().strokeBorder(active ? Color.yellow : Color.white.opacity(0.25),
                                                      lineWidth: active ? 2.5 : 1)
                            )
                            .overlay(
                                // 强调色小点：让人知道引号内的字会用哪个颜色
                                Circle()
                                    .fill(Color(palette.accent))
                                    .frame(width: 6, height: 6)
                                    .offset(x: 8, y: 8)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Divider().frame(height: 18).overlay(Color.white.opacity(0.18))

                ForEach(TextOutline.allCases) { outline in
                    let active = style.outlineKey == outline.rawValue
                    Button {
                        style.outlineKey = outline.rawValue
                    } label: {
                        Text(outline.title)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(active ? Color.yellow : Color.white.opacity(0.12),
                                        in: Capsule())
                            .foregroundStyle(active ? Color.black : Color.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 54, alignment: .top)
    }

    private var backgroundRow: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(TextBackground.allCases) { background in
                        let active = style.bgKey == background.rawValue
                        Button {
                            style.bgKey = background.rawValue
                        } label: {
                            HStack(spacing: 4) {
                                if let color = background.color {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Color(color))
                                        .frame(width: 12, height: 12)
                                }
                                Text(background.title)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(active ? Color.yellow : Color.white.opacity(0.12),
                                        in: Capsule())
                            .foregroundStyle(active ? Color.black : Color.white.opacity(0.9))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
            .frame(height: 24)

            HStack(spacing: 8) {
                Text("浓淡")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(style.bgKey == TextBackground.none.rawValue ? 0.3 : 0.72))
                Slider(value: Binding(get: { Double(style.bgOpacity) },
                                      set: { style.bgOpacity = CGFloat($0) }),
                       in: 0.12...0.95)
                    .tint(.yellow)
                    .disabled(style.bgKey == TextBackground.none.rawValue)
                Text(String(format: "%d%%", Int(style.bgOpacity * 100)))
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 32, alignment: .trailing)
            }
        }
        .frame(height: 54, alignment: .top)
    }

    private var sizeRow: some View {
        HStack(spacing: 9) {
            Text("字号")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 30, alignment: .leading)
            Slider(value: Binding(get: { Double(style.sizeRatio) },
                                  set: { style.sizeRatio = CGFloat($0) }),
                   in: Double(TextStyle.minSizeRatio)...Double(TextStyle.maxSizeRatio))
                .tint(.yellow)
            Text(String(format: "%.1f%%", style.sizeRatio * 100))
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 46, alignment: .trailing)
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Text("拖动移动 · 双指缩放 · 红色虚线外会被抖音遮挡")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 4)
            Button(action: onResetLayout) {
                Text("重置")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.16), in: Capsule())
            }
            Button(action: onRegenerate) {
                Text("换一条")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.16), in: Capsule())
            }
        }
    }

    // MARK: 插入表情

    /// 插在光标处（有选中就先替换），插完把光标挪到表情后面。
    private func insert(_ emoji: String) {
        let current = text as NSString
        let location = min(max(0, selection.location), current.length)
        let length = min(selection.length, current.length - location)
        let range = NSRange(location: location, length: max(0, length))
        text = current.replacingCharacters(in: range, with: emoji)
        let next = location + (emoji as NSString).length
        selection = NSRange(location: next, length: 0)
        caret = CaretRequest(id: caret.id + 1, location: next)
    }
}
