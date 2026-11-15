import SwiftUI
import AVFoundation
import UIKit

/// 构建标识：界面右上角显示，同时写进崩溃日志的启动行。
/// 崩溃现场靠它区分「这次崩的是哪个包」—— 装错包、或看到上一版的旧现场时一眼能认出。
let appBuildTag = "v33"

@main
struct DongtuCamApp: App {
    init() {
        Diagnostics.installCrashHandler(tag: appBuildTag)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - 相机预览

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            return AVCaptureVideoPreviewLayer()
        }
        return layer
    }
}

// MARK: - 主界面：打开就是相机，拍完自动出片

enum Phase {
    case idle
    case recording
    case processing
    case done
    case failed(String)
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraEngine()
    @StateObject private var copyEngine = CopyEngine()
    @StateObject private var aiSettings = AISettings()
    /// 文字样式（字体/字号/位置）：持久化，下次打开直接沿用
    @StateObject private var textStyle = TextStyleStore()

    @State private var phase: Phase = .idle
    @State private var permission = false
    @State private var statusText = "选好商品 → 点快门拍 5 秒 → 自动出片"
    @State private var lastError: String?
    @State private var showSettings = false
    @State private var lastRecognition: Recognition?
    /// 上一次崩在识别/抽帧这一步时，本次先跳过识别，保证能出片
    @State private var recognitionDisabledThisRun = false

    /// 最近一次成功出片：左下角缩略图 + 点开能播的实况预览
    @State private var lastShot: ShotResult?
    @State private var showShotPreview = false
    /// 画面调节面板是否展开
    @State private var showAdjust = false
    /// 文字编辑面板是否展开
    @State private var showTextEditor = false
    /// 文字可用宽度占画面的比例。
    ///
    /// 相机预览按 aspectFill 铺满全屏，3:4 的画面在长屏手机上会被裁掉两边；
    /// 文字若按整个画面宽度排，长句在预览里就会「溢出屏幕」。
    /// 这个值把排版宽度收窄到「屏幕上实际看得见的那一段」，
    /// 预览与成片用同一个数，所以两边都不外溢、换行位置也一致。
    @State private var textMaxWidthRatio: CGFloat = 0.92
    /// 自动识别：正在处理一帧时挡住后续帧（相机 2.5 秒一帧，重叠处理会白耗 CPU）
    @State private var scanning = false
    /// 已经为哪个商品生成过文案，避免同一款反复请求 AI
    @State private var autoDetectedID: String?

    /// 显示在右上角的构建标识：装错包时一眼就能看出来
    private let buildTag = appBuildTag

    /// 单次拍摄时长（秒），设置页可改。
    ///
    /// **3 秒是抖音的红线**：官方口径是「超过 3 秒的动图仅支持发布为静态图片」。
    /// 也就是说超了不会报错，会静默降级 —— v25~v27 录 5 秒，发出去变图文就是这个原因。
    /// 所以录制按 2.5 秒走，合成时再统一裁到 2.9 秒以内，双保险
    /// （录制收尾会多出几十毫秒，不能只靠这边卡）。
    @AppStorage("dtc.captureSeconds") private var captureSeconds: Double = 2.5

    /// 取景框矩形：**成片画幅**，垂直居中在「顶栏与快门之间」的那段空间里。
    ///
    /// - Parameters:
    ///   - size: 安全区内的可用尺寸
    ///   - aspect: 成片宽高比（3:4 = 0.75）；相机格式异常时回落 0.75
    private static func viewfinderRect(in size: CGSize, aspect rawAspect: CGFloat) -> CGRect {
        let aspect = (rawAspect.isFinite && rawAspect > 0.2 && rawAspect < 1.6) ? rawAspect : 0.75
        // 顶栏 + 文案角标 ≈ 78；状态条 + 快门区 ≈ 186
        let topReserve: CGFloat = 78
        let bottomReserve: CGFloat = 186
        let maxHeight = max(160, size.height - topReserve - bottomReserve)
        var height = maxHeight
        var width = height * aspect
        if width > size.width {
            width = size.width
            height = width / aspect
        }
        let x = (size.width - width) / 2
        let y = topReserve + (maxHeight - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 取景框：**成片是什么画幅，预览就是什么画幅**。
            //
            // v25 之前预览是全屏 aspectFill，3:4 的画面在长屏手机上两边被裁掉，
            // 屏幕上只看得见中间 61% —— 同一个字号在预览里显得大、在成片里显得小，
            // 「所见即所得」在这一步就断了。现在把画面框成 3:4，
            // 框外就是会被裁掉的区域（纯黑），字号与位置在两边完全等价。
            GeometryReader { geo in
                let frame = Self.viewfinderRect(in: geo.size, aspect: camera.displayAspect)

                ZStack {
                    if permission {
                        CameraPreview(session: camera.session)
                            .frame(width: frame.width, height: frame.height)
                            .clipped()
                            .position(x: frame.midX, y: frame.midY)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "camera.fill").font(.largeTitle)
                            Text("需要相机权限才能拍摄").font(.subheadline)
                        }
                        .foregroundStyle(.white)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                    }

                    // 取景框边线：框外不会出现在成片里
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)

                    // 文字层：和成片走同一套排版（TextLayer），
                    // 所以屏幕上的字体、字号、颜色、位置、描边就是最终要烧进画面的样子
                    TextOverlay(lines: copyEngine.lines,
                                style: $textStyle.style,
                                aspect: camera.displayAspect,
                                showGuides: showTextEditor,
                                onTap: toggleTextEditor)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .onPreferenceChange(TextWidthRatioKey.self) { ratio in
                            textMaxWidthRatio = ratio
                        }
                }
            }
            // 键盘弹起时**不要**把取景框挤小：
            // 画面一缩，同一份 sizeRatio 画出来的字在屏幕上就变小了，
            // 边打字边看的时候会以为「字变小了」。取景框钉死，键盘只影响下方控件。
            .ignoresSafeArea(.keyboard, edges: .bottom)

            VStack(spacing: 0) {
                topBar
                copyBadge
                Spacer()
                if let lastError {
                    Text(lastError)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                }
                if showTextEditor {
                    TextEditorPanel(text: copyText,
                                    style: $textStyle.style,
                                    onRegenerate: regenerateCopy,
                                    onResetLayout: { textStyle.reset() },
                                    onDone: { withAnimation(.easeOut(duration: 0.24)) { showTextEditor = false } })
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if showAdjust {
                    adjustPanel
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                statusBar
                controls
            }
        }
        .onAppear(perform: onAppear)
        .onDisappear {
            // 摘掉取帧回调：App 退到后台时相机那边就彻底不转图了
            camera.onFrame = nil
            camera.stop()
        }
        // 正常切后台/退出留个记号：下次冷启动就不会把「用户自己关掉」
        // 误判成「闪退」（v19 现场面板就是这么误报的）
        .onChange(of: scenePhase) { phase in
            if phase != .active { Diagnostics.mark("app.background") }
        }
        .sheet(isPresented: $showSettings) {
            AISettingsView(settings: aiSettings, copyEngine: copyEngine)
        }
        // 用全屏而不是 sheet：sheet 顶部是圆角卡片，会裁掉画面四角，
        // 也没法让黑底真正铺满，看图时会误以为是画幅不对
        .fullScreenCover(isPresented: $showShotPreview) {
            if let lastShot {
                LivePhotoPreviewSheet(shot: lastShot)
            }
        }
        .onChange(of: aiSettings.autoDetectOnCamera) { _ in wireAutoDetect() }
    }

    private func onAppear() {
        askPermission()
        // 后台配置：打开就同步一次（失败无所谓，沿用上一次的值）
        Task { @MainActor in
            await aiSettings.syncRemote()
            // 等配置到位再开自动识别：否则会拿着旧 Key 白跑一轮
            wireAutoDetect()
        }
        // 上次是崩着退出的：把现场留在界面上，截图就能定位
        if let incident = Diagnostics.takeLastIncident() {
            // 用「崩的那个包」的版本号标注，而不是当前版本 ——
            // 否则刚装新版就会显示成「v24 上次现场」，把上一版的旧账算到新版头上
            let crashTag = incident.tag ?? buildTag
            lastError = "\(crashTag) 上次现场\n" + incident.text
            // 自愈：连续崩就直接降级到「只出片」，不再碰识别与 AI。
            // 宁可少一个功能，也不能让用户每次拍都闪退。
            let fragile = ["copy.recognize", "process.frame", "process.text",
                           "process.compose", "burn.", "burnV.", "process.save", "camera.record"]
            if fragile.contains(where: { incident.text.contains($0) }) {
                let strikes = UserDefaults.standard.integer(forKey: "dtc.crash.strikes") + 1
                UserDefaults.standard.set(strikes, forKey: "dtc.crash.strikes")
                if strikes >= 2 {
                    recognitionDisabledThisRun = true
                    aiSettings.config.autoRecognize = false
                    aiSettings.config.enabled = false
                    statusText = "安全模式：已关闭识别与 AI，只用本地文案出片"
                } else {
                    recognitionDisabledThisRun = true
                    statusText = "本次已跳过商品识别（上次崩在这一步）"
                }
            }
        } else {
            UserDefaults.standard.set(0, forKey: "dtc.crash.strikes")
        }
        Diagnostics.mark("app.ready")

        // 上次没走完（含闪退）的素材：自动补存进相册。
        // 这是「一次性解决白拍」的最后一道保险——不依赖崩溃处理，
        // 只依赖「录制后就落盘」这一个近乎不会失败的动作。
        ShotStore.shared.recover { message in
            if let message {
                statusText = message
                // 补存成功后不要再显示「上次现场」，避免用户以为又崩了
                if lastError?.contains("上次现场") == true { lastError = nil }
            }
            // 恢复走完就把面包屑清空：这一轮起点已知，文件里不会再残留
            // 「启动+恢复」的十几行把真正的现场顶出窗口
            Diagnostics.clear()
        }
    }

    // MARK: 顶部：商品 + 文案操作 + 设置

    private var topBar: some View {
        HStack(spacing: 7) {
            Menu {
                ForEach(copyEngine.products) { product in
                    Button(product.name) { copyEngine.select(product) }
                }
            } label: {
                Label(copyEngine.selected?.name ?? "选商品", systemImage: "shippingbox")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Button {
                if let text = UIPasteboard.general.string {
                    _ = copyEngine.match(text)
                }
            } label: {
                icon("doc.on.clipboard")
            }

            Button(action: regenerateCopy) {
                icon("arrow.triangle.2.circlepath")
            }

            // 文字：改内容 / 字体 / 字号（点画面上的文字同效）
            Button(action: toggleTextEditor) {
                Image(systemName: "textformat")
                    .font(.subheadline.weight(.semibold))
                    .padding(9)
                    .background(showTextEditor ? Color.yellow : Color.white.opacity(0.18),
                                in: Circle())
                    .foregroundStyle(showTextEditor ? Color.black : Color.white)
            }

            Button { showSettings = true } label: {
                icon("gearshape")
            }

            Spacer(minLength: 4)

            Text(buildTag)
                .font(.caption2.weight(.black))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.yellow, in: Capsule())
                .foregroundStyle(.black)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.subheadline.weight(.semibold))
            .padding(9)
            .background(.ultraThinMaterial, in: Circle())
    }

    /// 文字面板开合。和画面调节互斥，否则两块面板叠起来会把画面挤没。
    private func toggleTextEditor() {
        withAnimation(.easeOut(duration: 0.24)) {
            showTextEditor.toggle()
            if showTextEditor { showAdjust = false }
        }
    }

    /// 文案编辑的双向绑定。
    ///
    /// 直接读写 `copyEngine.lines`，不另存一份草稿 —— 面板上敲的每个字都立刻
    /// 反映到画面上的文字层，这才叫边改边看。
    private var copyText: Binding<String> {
        Binding(get: { copyEngine.lines.joined(separator: "\n") },
                set: { copyEngine.edit($0) })
    }

    private func regenerateCopy() {
        Task { await copyEngine.refresh(config: aiSettings.config,
                                        recognition: lastRecognition) }
    }

    /// 文案来源角标。文字本身已经画在画面上了，这里只留极简的状态提示。
    private var copyBadge: some View {
        HStack(spacing: 6) {
            Text(copyEngine.badge)
                .font(.system(size: 9, weight: .black))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(copyEngine.badge == "AI" ? Color.orange : Color.white.opacity(0.28),
                            in: Capsule())
                .foregroundStyle(.white)
            if aiSettings.config.enabled == false {
                Text("未启用 AI")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            if copyEngine.isManual {
                Text("已手动编辑")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.yellow.opacity(0.92))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 7)
    }

    private var statusBar: some View {
        Text(statusText)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.black.opacity(0.42), in: Capsule())
            .padding(.bottom, 14)
    }

    private var shutter: some View {
        Button(action: shoot) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 3).frame(width: 76, height: 76)
                Circle()
                    .fill(working ? Color.orange : Color.red)
                    .frame(width: 60, height: 60)
            }
        }
        .disabled(working || !permission)
    }

    // MARK: 底部控件：缩略图 / 快门 / 调节

    private var controls: some View {
        HStack(spacing: 0) {
            // 左：刚拍的那张。没有就先留白，保证快门永远在正中间
            Group {
                if let shot = lastShot {
                    ShotThumbnail(shot: shot) { showShotPreview = true }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    Color.clear
                }
            }
            .frame(width: 78, height: 62, alignment: .leading)

            Spacer(minLength: 0)
            shutter
            Spacer(minLength: 0)

            // 右：画面调节
            Button {
                withAnimation(.easeOut(duration: 0.24)) {
                    showAdjust.toggle()
                    // 两个面板互斥：同时展开会把画面挤没
                    if showAdjust { showTextEditor = false }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(showAdjust ? Color.black : Color.white)
                    .frame(width: 44, height: 44)
                    .background(showAdjust ? Color.yellow : Color.white.opacity(0.18), in: Circle())
            }
            .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 26)
    }

    // MARK: 画面调节面板

    private var adjustPanel: some View {
        VStack(spacing: 11) {
            HStack {
                Text("画面调节")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Button {
                    camera.resetAdjustments()
                } label: {
                    Text("重置")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.18), in: Capsule())
                }
            }

            adjustRow("亮度",
                      value: Binding(get: { Double(camera.exposureBias) },
                                     set: { camera.setExposureBias(Float($0)) }),
                      range: Double(camera.exposureRange.lowerBound)...Double(camera.exposureRange.upperBound),
                      readout: String(format: "%+.1f", camera.exposureBias))

            adjustRow("变焦",
                      value: Binding(get: { Double(camera.zoomFactor) },
                                     set: { camera.setZoom(CGFloat($0)) }),
                      range: 1...Double(max(2, camera.maxZoom)),
                      readout: String(format: "%.1f×", camera.zoomFactor))

            adjustRow("色温",
                      value: Binding(get: { Double(camera.kelvin) },
                                     set: { camera.setKelvin(CGFloat($0)) }),
                      range: 3000...8000,
                      readout: camera.autoWhiteBalance ? "自动" : "\(Int(camera.kelvin))K")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func adjustRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, readout: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 30, alignment: .leading)
            Slider(value: value, in: range)
                .tint(.yellow)
            Text(readout)
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 50, alignment: .trailing)
        }
    }

    private var working: Bool {
        switch phase {
        case .recording, .processing: return true
        case .idle, .done, .failed: return false
        }
    }

    // MARK: 权限

    private func askPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permission = true
            camera.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.permission = granted
                    if granted { self.camera.start() }
                }
            }
        default:
            permission = false
            statusText = "请到 设置 → 隐私与安全性 → 相机 开启权限"
        }
    }

    // MARK: 一次快门 = 完整链路

    private func shoot() {
        guard !working else { return }
        phase = .recording
        lastError = nil
        lastRecognition = nil
        statusText = "录制 \(Int(captureSeconds.rounded())) 秒…"
        Diagnostics.mark("shutter")

        // 快门按下的这一刻，屏幕上是什么字，成片就是什么字。
        // 处理期间 AI 可能又换了一条文案，那是给下一拍用的。
        let shotLines = copyEngine.lines

        camera.capture(seconds: captureSeconds) { result in
            switch result {
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
                self.lastError = "\(buildTag) 录制失败\n" + error.localizedDescription
                self.statusText = "录制失败（详情见下方）"
                Diagnostics.clear()
            case .success(let url):
                self.process(url, shotLines: shotLines)
            }
        }
    }

    // MARK: 识别 + 写文案（从成片首帧取画面，避免多挂一路相机输出）

    /// 是否真的需要识别。
    ///
    /// 这一条是**闪退的关键修复**：识别结果唯一的用途是「给 AI 提供输入 + 自动切商品」，
    /// 而 AI 没配 Key 时文案本来就来自本地模板，识别纯属白跑——却要额外付出
    /// Vision 模型装载（上百 MB）+ 一次全帧解码的代价。
    /// v11/v12 就是在这条白跑的路径上被系统干掉的（内存顶峰 / Vision 异常）。
    /// 所以现在只有 AI 真的可用、且用户没手动关掉时才识别。
    private var recognitionNeeded: Bool {
        guard !recognitionDisabledThisRun else { return false }
        guard aiSettings.config.autoRecognize else { return false }
        return aiSettings.isReady
    }

    /// frame 为 nil 表示没取到画面，此时只走 AI（无图）/ 本地模板
    @MainActor
    private func prepareCopy(frame: CGImage?) async {
        // 用户手动改过文案：这一拍就按他改的出，不识别、也不调 AI。
        // 人家明明调过措辞，拍一次又被换掉，那「编辑」就形同虚设 —— 想换请点「换一条」。
        if copyEngine.isManual, !copyEngine.lines.isEmpty {
            Diagnostics.mark("copy.manual-skip")
            return
        }

        var recognition: Recognition?

        if let frame, recognitionNeeded {
            statusText = "识别商品…"
            Diagnostics.mark("copy.recognize")
            recognition = await ProductRecognizer.analyze(frame: frame,
                                                          products: copyEngine.products)
            lastRecognition = recognition
            if let hit = recognition?.localHit {
                copyEngine.select(hit)
            }
            if let recognition { statusText = recognition.summary }
            Diagnostics.mark("copy.recognized")
        }

        guard aiSettings.config.enabled,
              !aiSettings.config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }

        // 关掉「每次拍摄重新生成」时，沿用上一条 AI 文案
        if !aiSettings.config.autoGenerateOnShoot,
           copyEngine.badge == "AI",
           !copyEngine.lines.isEmpty {
            return
        }

        statusText = "AI 写文案…"
        Diagnostics.mark("copy.ai")
        var jpeg: Data?
        if aiSettings.config.useVision, let frame {
            jpeg = ProductRecognizer.jpegPreview(frame)
        }
        _ = await copyEngine.generateWithAI(config: aiSettings.config,
                                            recognition: recognition,
                                            imageJPEG: jpeg)
        if let note = copyEngine.note { statusText = note }
        Diagnostics.mark("copy.ai-done")
    }

    // MARK: 举着商品就认（自动识别 → 自动切商品 → 自动出文案）

    /// 把相机的取帧回调接上识别流程。
    /// 关掉开关、或本次处于「跳过识别」的自愈模式时直接把回调摘掉 ——
    /// 相机那边就彻底不再转图，等于零开销。
    @MainActor
    private func wireAutoDetect() {
        guard aiSettings.autoDetectOnCamera, !recognitionDisabledThisRun, permission else {
            camera.onFrame = nil
            Diagnostics.mark("auto.off")
            return
        }
        Diagnostics.mark("auto.on")
        camera.onFrame = { image in
            Task { @MainActor in await self.scan(image) }
        }
    }

    /// 收到一帧（相机每 2.5 秒送一次）：本地识别 → 命中就切商品 → 有 AI 就写文案。
    ///
    /// 三道闸：正在出片、正在录、上一帧还没处理完 —— 任一成立就直接丢弃这一帧。
    /// 识别本身是纯本机 Vision，不花钱；**AI 只在商品真的换了才调一次**。
    @MainActor
    private func scan(_ image: CGImage) async {
        guard !scanning, !working, permission else { return }
        guard aiSettings.autoDetectOnCamera, !recognitionDisabledThisRun else { return }
        scanning = true
        defer { scanning = false }

        Diagnostics.mark("auto.scan")
        let recognition = await ProductRecognizer.analyze(frame: image,
                                                          products: copyEngine.products)
        guard let hit = recognition.localHit else {
            Diagnostics.mark("auto.miss")
            return
        }
        // 同一款不重复处理：省 AI 额度，也避免预览文字一直跳
        guard hit.id != autoDetectedID else { return }
        autoDetectedID = hit.id
        Diagnostics.mark("auto.hit")

        // 先切商品：select 会立刻换成本地模板文案，保证任何时候都有字可看
        copyEngine.select(hit)
        lastRecognition = recognition

        guard aiSettings.isReady else {
            statusText = "识别到「\(hit.name)」· 已用本地文案"
            return
        }
        statusText = "识别到「\(hit.name)」· AI 写文案…"
        _ = await copyEngine.generateWithAI(config: aiSettings.config,
                                            recognition: recognition,
                                            imageJPEG: nil)
        if let note = copyEngine.note { statusText = note }
    }

    /// 出片成功：把封面挂到左下角。
    /// 缩略图取自本地 still.heic，不依赖相册权限；`identifier` 用来点开时回读实况。
    @MainActor
    private func publishShot(still: URL, identifier: String?, isLive: Bool?, video: URL? = nil) {
        let thumb = ShotThumbnailMaker.image(from: still)
        Diagnostics.mark(thumb == nil ? "shot.thumb-nil" : "shot.thumb-ok")
        withAnimation(.easeOut(duration: 0.26)) {
            lastShot = ShotResult(thumbnail: thumb,
                                  localIdentifier: identifier,
                                  isLive: isLive,
                                  videoURL: Self.cacheMotionVideo(video))
        }
    }

    /// 把这一拍的静音动图复制到缓存区。
    ///
    /// 暂存目录在 `ShotStore.finish` 时会被整个删掉，而「存成动图视频」是用户
    /// 几秒之后才点的 —— 不提前复制一份，那个按钮就是个摆设。
    /// 只留最新一条（覆盖写），占几 MB，不会滚成雪球。
    private static func cacheMotionVideo(_ source: URL?) -> URL? {
        guard let source, FileManager.default.fileExists(atPath: source.path) else {
            Diagnostics.mark("motion.cache-skip")
            return nil
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dtc-motion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("latest.mov")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            Diagnostics.mark("motion.cache-ok")
            return dest
        } catch {
            Diagnostics.mark("motion.cache-failed")
            return nil
        }
    }

    // MARK: 烧字 + 写相册

    /// 后台抽帧。AVAssetImageGenerator 是同步解码，放主线程会卡住 UI。
    private static func frameInBackground(_ source: URL) async -> CGImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let image = autoreleasepool { BurnEngine.previewFrame(from: source) }
                continuation.resume(returning: image)
            }
        }
    }

    /// 后台渲染文字层。UIGraphicsImageRenderer 支持在非主线程跑，
    /// 大画布（上千万像素）放主线程会让界面卡住几百毫秒。
    private static func overlayInBackground(lines: [String], size: CGSize,
                                            style: TextStyle,
                                            maxWidthRatio: CGFloat) async -> CGImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let image = autoreleasepool {
                    TextLayer.make(lines: lines, style: style, canvas: size,
                                   maxWidthRatio: maxWidthRatio)
                }
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - 一次快门 = 完整链路（每一级都能失败，失败就降级，绝不白拍）

    /// - Parameter shotLines: **按下快门那一刻屏幕上显示的文案**。
    ///   出片用它，而不是处理完再看 `copyEngine.lines` —— 后者可能已经被
    ///   AI 重新生成过，那样烧进画面的字就和用户按快门时看到的不一样了。
    private func process(_ source: URL, shotLines: [String]) {
        Task { @MainActor in
            phase = .processing
            Diagnostics.mark("process.begin")

            // 0) 先落盘。从这一刻起这一拍就丢不了了：
            //    后面任何一步把进程带走，下次冷启动 ShotStore.recover 会自动补存。
            let shotID = ShotStore.shared.begin(video: source)
            Diagnostics.mark(shotID == nil ? "process.stage-failed" : "process.staged")

            // 1) 抽帧：既是静帧底图，也是识别输入
            statusText = "取画面…"
            Diagnostics.mark("process.frame")
            guard let frame = await Self.frameInBackground(source) else {
                Diagnostics.mark("process.frame-nil")
                await decline(toVideo: source, shotID: shotID,
                              reason: "取不到画面，已把原片存进相册")
                return
            }
            Diagnostics.mark("process.frame-ok")

            // 2) 文案：识别失败/网络失败都不影响出片，本地模板兜底。
            //    用户手动改过时不再让 AI 覆盖（prepareCopy 内部判断）。
            await prepareCopy(frame: recognitionNeeded ? frame : nil)
            if copyEngine.lines.isEmpty { copyEngine.regenerate() }
            Diagnostics.mark("process.copy")

            // 这一拍到底用哪几句：快门那一刻的屏幕内容优先
            let burnLines = shotLines.isEmpty ? copyEngine.lines : shotLines
            let style = textStyle.style
            let maxWidthRatio = textMaxWidthRatio

            // 3) 文字层。失败不致命：出无字静帧，仍然能配成实况。
            //    画布用 stillCanvasSize（显示尺寸的 2 倍）：文字按更高像素渲染，
            //    缩到屏幕上看才锐利。排版参数与预览完全同一份，只是画布更大。
            let renderSize = BurnEngine.stillCanvasSize(for: frame)
            statusText = "排版文字…"
            Diagnostics.mark("process.text")
            var overlay: CGImage? = await Self.overlayInBackground(lines: burnLines,
                                                                   size: renderSize,
                                                                   style: style,
                                                                   maxWidthRatio: maxWidthRatio)
            Diagnostics.mark(overlay == nil ? "process.text-nil" : "process.text-ok")

            // 4) 静帧：做完立刻进暂存区，崩溃也有东西可恢复
            statusText = "生成封面…"
            Diagnostics.mark("process.still")
            let identifier = UUID().uuidString
            let still: StillOutput
            do {
                still = try await Self.makeStill(frame: frame, overlay: overlay,
                                                 source: source,
                                                 identifier: identifier)
            } catch {
                Diagnostics.mark("process.still-failed")
                await decline(toVideo: source, shotID: shotID,
                              reason: "封面生成失败，已存原片")
                return
            }
            Self.persist(still.url, as: "still.heic", id: shotID)
            ShotStore.shared.mark(shotID, stage: "still")

            // 文字层此刻已无用，立刻放掉，给后面的视频段腾内存
            overlay = nil

            // 5) 视频：逐帧压字 + 转正（动图播放时也能看到文案），
            //    压字失败自动降级为无损封装（只是画面里没字）。
            statusText = "压制动图…"
            Diagnostics.mark("process.video")
            var video: VideoOutput?
            do {
                video = try await Self.makeVideo(source: source,
                                                 lines: burnLines,
                                                 style: style,
                                                 maxWidthRatio: maxWidthRatio,
                                                 identifier: identifier)
            } catch {
                Diagnostics.mark("process.video-failed")
                video = nil
            }
            if let video {
                Self.persist(video.url, as: "video.mov", id: shotID)
                ShotStore.shared.mark(shotID, stage: "video")
            }

            // 6) 写相册：实况 → 照片 + 视频，逐级降级
            statusText = "写入相册…"
            Diagnostics.mark("process.save")
            let report = BurnEngine.selfCheck(stillURL: still.url,
                                              videoURL: video?.url ?? source,
                                              identifier: identifier)
                + " vid=" + (video?.mode ?? "none")

            if let video {
                do {
                    let outcome = try await Self.saveLivePhoto(still: still.url,
                                                               video: video.url,
                                                               report: report)
                    ShotStore.shared.finish(shotID)
                    phase = .done
                    lastError = nil
                    // 左下角挂上这一拍的缩略图（点开能播实况 + 跳相册 + 另存动图视频）
                    publishShot(still: still.url,
                                identifier: outcome.localIdentifier,
                                isLive: outcome.verifiedLive,
                                video: video.url)
                    // 拿到完整相册权限时会回读确认；确认不了就不把话说满
                    // 两条通道产出的体裁不同：相册「动图」= 动图体裁（分享出去标「动图」），
                    // App 间分享视频文件 = 视频体裁（剪映那条，分享出去标「视频」）
                    statusText = outcome.verifiedLive == true
                        ? "已存入相册 · 点左下角缩略图 →「发布到抖音」才是视频体裁"
                        : "已写入相册（未回读确认）· 点左下角缩略图 →「发布到抖音」"
                    Diagnostics.clear()
                    return
                } catch {
                    Diagnostics.mark("process.live-failed")
                    await degrade(still: still.url, video: video.url, shotID: shotID,
                                  reason: error.localizedDescription, report: report)
                    return
                }
            }
            // 视频段完全失败：至少把带字照片 + 原片分别存下来
            await degrade(still: still.url, video: source, shotID: shotID,
                          reason: "视频封装失败", report: report)
        }
    }

    /// 连封面都做不出来时的兜底：把原片存成普通视频
    @MainActor
    private func decline(toVideo source: URL, shotID: String?, reason: String) async {
        var saved = false
        var failure: String?
        do {
            try await Self.saveVideoOnly(source)
            saved = true
        } catch {
            failure = error.localizedDescription
        }
        if saved {
            ShotStore.shared.finish(shotID)
            phase = .done
            statusText = "已把原片存进相册 · \(reason)"
            lastError = "\(buildTag) \(reason)"
        } else {
            phase = .failed(reason)
            statusText = "写相册失败（详情见下方）"
            lastError = "\(buildTag) \(reason)\n\(failure ?? "")"
        }
        Diagnostics.clear()
    }

    /// 实况配对失败的降级：照片 + 视频分别存，两个都失败才算失败
    @MainActor
    private func degrade(still: URL, video: URL?, shotID: String?,
                         reason: String, report: String) async {
        var saved: [String] = []
        do {
            try await Self.saveStillOnly(still)
            saved.append("带字照片")
        } catch {
            Diagnostics.mark("process.still-save-failed")
        }
        if let video {
            do {
                try await Self.saveVideoOnly(video)
                saved.append("视频")
            } catch {
                Diagnostics.mark("process.video-save-failed")
            }
        }
        if saved.isEmpty {
            phase = .failed(reason)
            statusText = "写相册失败（详情见下方）"
            lastError = "\(buildTag) 写相册失败\n\(reason)\n\(report)"
        } else {
            phase = .done
            ShotStore.shared.finish(shotID)
            // 实况没配上也算出片：缩略图照样挂上，只是没有相册标识。
            // 视频已经单独存进相册了，这里只把缓存副本留一份，别让「存成动图视频」变灰。
            publishShot(still: still, identifier: nil, isLive: false, video: video)
            statusText = "已存\(saved.joined(separator: " + "))（实况没配上）"
            lastError = "\(buildTag) 实况配对未成功，已分存\n\(reason)\n\(report)"
        }
        Diagnostics.clear()
    }

    private static func persist(_ url: URL, as name: String, id: String?) {
        guard let id else { return }
        _ = ShotStore.shared.keep(url, as: name, id: id)
    }

    // MARK: - 回调转 async

    private static func makeStill(frame: CGImage, overlay: CGImage?,
                                  source: URL,
                                  identifier: String) async throws -> StillOutput {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<StillOutput, Error>) in
            BurnEngine.makeStill(frame: frame, overlay: overlay, source: source,
                                 identifier: identifier) { result in
                continuation.resume(with: result)
            }
        }
    }

    private static func makeVideo(source: URL, lines: [String], style: TextStyle,
                                  maxWidthRatio: CGFloat,
                                  identifier: String) async throws -> VideoOutput {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<VideoOutput, Error>) in
            BurnEngine.makeVideo(source: source,
                                 lines: lines,
                                 style: style,
                                 maxWidthRatio: maxWidthRatio,
                                 identifier: identifier) { result in
                continuation.resume(with: result)
            }
        }
    }

    private static func saveLivePhoto(still: URL, video: URL,
                                      report: String) async throws -> LivePhotoOutcome {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<LivePhotoOutcome, Error>) in
            LivePhotoWriter.save(still: still, video: video, report: report) { result in
                continuation.resume(with: result)
            }
        }
    }

    private static func saveStillOnly(_ still: URL) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            LivePhotoWriter.saveStill(still) { result in
                continuation.resume(with: result)
            }
        }
    }

    private static func saveVideoOnly(_ video: URL) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            LivePhotoWriter.saveVideo(video) { result in
                continuation.resume(with: result)
            }
        }
    }
}
