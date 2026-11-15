import SwiftUI

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
struct TextOverlay: View {
    let lines: [String]
    @Binding var style: TextStyle
    /// 成片画面的宽高比（显示方向：3:4 = 0.75）
    let aspect: CGFloat
    /// 点文字触发（打开编辑面板）
    var onTap: () -> Void = {}

    @Environment(\.displayScale) private var displayScale

    /// 文字块在屏幕上的实际尺寸，拖动时用来防止把字拖出画面
    @State private var blockSize: CGSize = .zero
    @State private var dragOrigin: CGPoint?
    @State private var pinchOrigin: CGFloat?

    var body: some View {
        GeometryReader { geo in
            // 成片画面按 aspectFill 铺在屏幕上，文字用同一个矩形定位
            let filled = TextStyle.filledRect(aspect: aspect, in: geo.size)
            let scale = min(max(displayScale, 1), 3)
            // 屏幕实际看得见的画面宽度占比：预览按 aspectFill 铺满，
            // 3:4 的画面在长屏手机上两边会被裁掉
            let ratio = Self.widthRatio(visible: geo.size.width, canvas: filled.width)

            TextBlockImage(lines: lines,
                           fontKey: style.fontKey,
                           sizeRatio: style.sizeRatio,
                           lineSpacing: style.lineSpacing,
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
            // 把「看得见的宽度占比」上报给主界面：出片时要用同一个数，
            // 否则预览里不溢出的句子，成片里可能被挤小或溢出
            .preference(key: TextWidthRatioKey.self, value: ratio)
        }
        .allowsHitTesting(!lines.isEmpty)
    }

    /// 文字块可用宽度占画面的比例。
    ///
    /// 竖拍 3:4 的画面在 9:19.5 的手机屏上按 aspectFill 铺满后，
    /// 屏幕上只看得见中间 61% 的宽度。排版宽度就收窄到这个范围，
    /// 长句在预览里不会被切掉，成片里同样不会溢出。
    static func widthRatio(visible: CGFloat, canvas: CGFloat) -> CGFloat {
        guard canvas > 1, visible > 1 else { return 0.92 }
        return min(0.92, max(0.42, (visible / canvas) * 0.96))
    }

    // MARK: 手势

    /// 拖动改位置。归一化增量按**画面矩形**算，不是按屏幕 ——
    /// 屏幕比画面宽（aspectFill 裁掉两边），按屏幕算会「拖一点跑很远」。
    private func dragGesture(filled: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard filled.width > 1, filled.height > 1 else { return }
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
            .onEnded { _ in dragOrigin = nil }
    }

    /// 双指捏合改字号。以手势开始时的字号为基准，避免连续缩放累积误差。
    private func magnifyGesture(filled: CGRect) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchOrigin == nil { pinchOrigin = style.sizeRatio }
                guard let origin = pinchOrigin else { return }
                var next = style
                next.sizeRatio = origin * value
                next.clampToCanvas(blockSize: blockSize, canvas: filled.size)
                style = next
            }
            .onEnded { _ in pinchOrigin = nil }
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
    let fontKey: String
    let sizeRatio: CGFloat
    let lineSpacing: CGFloat
    let canvas: CGSize
    let scale: CGFloat
    let maxWidthRatio: CGFloat

    static func == (lhs: TextBlockImage, rhs: TextBlockImage) -> Bool {
        lhs.lines == rhs.lines
            && lhs.fontKey == rhs.fontKey
            && lhs.sizeRatio == rhs.sizeRatio
            && lhs.lineSpacing == rhs.lineSpacing
            && lhs.canvas == rhs.canvas
            && lhs.scale == rhs.scale
            && lhs.maxWidthRatio == rhs.maxWidthRatio
    }

    var body: some View {
        // 中心点固定 0.5/0.5：文字块图像的内容与位置无关，
        // 实际摆在哪里由外层 `.position` 决定。
        let style = TextStyle(fontKey: fontKey,
                              sizeRatio: sizeRatio,
                              centerX: 0.5,
                              centerY: 0.5,
                              lineSpacing: lineSpacing)
        if let block = TextLayer.renderBlock(lines: lines, style: style,
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

// MARK: - 编辑面板

/// 文案编辑面板：文字内容、字体、字号，外加「拖动 / 捏合」的提示。
///
/// 面板**不做成 sheet**，而是浮在相机上面 —— 只有这样才能边改边看，
/// 真正检验「成片就是现在这样」。sheet 一盖，所见即所得就无从谈起。
struct TextEditorPanel: View {
    @Binding var text: String
    @Binding var style: TextStyle
    /// 换一条（重新生成）
    var onRegenerate: () -> Void
    /// 排版回到默认（字体/字号/位置）
    var onResetLayout: () -> Void
    /// 收起面板
    var onDone: () -> Void

    private var fonts: [TextFont] {
        TextFont.pickable(including: style.fontKey)
    }

    var body: some View {
        VStack(spacing: 9) {
            header
            editor
            fontRow
            sizeRow
            footer
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
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

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .tint(.yellow)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(height: 74)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
            .overlay(alignment: .topLeading) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("每行一句，最多 5 行")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.38))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
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
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 30)
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
        HStack(spacing: 8) {
            Text("画面上可直接拖动文字，双指捏合改大小")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Button(action: onResetLayout) {
                Text("重置排版")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.16), in: Capsule())
            }
            Button(action: onRegenerate) {
                Text("换一条")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.16), in: Capsule())
            }
        }
    }
}
