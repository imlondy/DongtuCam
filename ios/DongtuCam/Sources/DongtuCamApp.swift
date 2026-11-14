import SwiftUI
import AVFoundation
import UIKit

/// 构建标识：界面右上角显示，同时写进崩溃日志的启动行。
/// 崩溃现场靠它区分「这次崩的是哪个包」—— 装错包、或看到上一版的旧现场时一眼能认出。
let appBuildTag = "v24"

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
    /// 自动识别：正在处理一帧时挡住后续帧（相机 2.5 秒一帧，重叠处理会白耗 CPU）
    @State private var scanning = false
    /// 已经为哪个商品生成过文案，避免同一款反复请求 AI
    @State private var autoDetectedID: String?

    /// 显示在右上角的构建标识：装错包时一眼就能看出来
    private let buildTag = appBuildTag
    /// 预览文字的磅值（和下面 copyPreview 里的 13 保持一致）
    private let previewFontPt: CGFloat = 13

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if permission {
                CameraPreview(session: camera.session).ignoresSafeArea()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "camera.fill").font(.largeTitle)
                    Text("需要相机权限才能拍摄").font(.subheadline)
                }
                .foregroundStyle(.white)
            }

            VStack(spacing: 0) {
                topBar
                copyPreview
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
        .sheet(isPresented: $showShotPreview) {
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

            Button {
                Task { await copyEngine.refresh(config: aiSettings.config,
                                                recognition: lastRecognition) }
            } label: {
                icon("arrow.triangle.2.circlepath")
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

    /// 固定 3 个位置、用「新建的数组」渲染。
    /// 不能用 ForEach(lines.indices, id: \.self)：AI 返回行数变化时
    /// SwiftUI 会拿旧索引去取新数组，是典型的越界闪退来源。
    private var previewLines: [String] {
        let source = copyEngine.lines
        return (0..<3).map { index in index < source.count ? source[index] : "" }
    }

    /// 只是拍前预览，不会进画面；真正烧录由 TextLayer 完成
    private var copyPreview: some View {
        VStack(spacing: 3) {
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
            }

            ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                if !line.isEmpty {
                    Text(line)
                        .font(.system(size: previewFontPt, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.85), radius: 2.5)
                }
            }

            if let note = copyEngine.note {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
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
                withAnimation(.easeOut(duration: 0.24)) { showAdjust.toggle() }
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
        statusText = "录制 5 秒…"
        Diagnostics.mark("shutter")

        camera.capture(seconds: 5.0) { result in
            switch result {
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
                self.lastError = "\(buildTag) 录制失败\n" + error.localizedDescription
                self.statusText = "录制失败（详情见下方）"
                Diagnostics.clear()
            case .success(let url):
                self.process(url)
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
    private func publishShot(still: URL, identifier: String?, isLive: Bool?) {
        let thumb = ShotThumbnailMaker.image(from: still)
        Diagnostics.mark(thumb == nil ? "shot.thumb-nil" : "shot.thumb-ok")
        withAnimation(.easeOut(duration: 0.26)) {
            lastShot = ShotResult(thumbnail: thumb, localIdentifier: identifier, isLive: isLive)
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
                                            previewFontPt: CGFloat,
                                            screenWidth: CGFloat) async -> CGImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let image = autoreleasepool {
                    TextLayer.make(lines: lines, size: size,
                                   previewFontPt: previewFontPt,
                                   screenWidthPt: screenWidth)
                }
                continuation.resume(returning: image)
            }
        }
    }

    /// 屏幕宽度（pt）。不用已废弃的 UIScreen.main。
    @MainActor
    private static var screenWidthPt: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let width = scenes.first?.screen.bounds.width, width > 0 { return width }
        return 393
    }

    // MARK: - 一次快门 = 完整链路（每一级都能失败，失败就降级，绝不白拍）

    private func process(_ source: URL) {
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

            // 2) 文案：识别失败/网络失败都不影响出片，本地模板兜底
            await prepareCopy(frame: recognitionNeeded ? frame : nil)
            if copyEngine.lines.isEmpty { copyEngine.regenerate() }
            Diagnostics.mark("process.copy")

            // 3) 文字层。失败不致命：出无字静帧，仍然能配成实况。
            //    画布用 stillCanvasSize（显示尺寸的 1.5 倍）：
            //    文字按更高像素渲染，缩到屏幕上看才锐利。
            let renderSize = BurnEngine.stillCanvasSize(for: frame)
            statusText = "排版文字…"
            Diagnostics.mark("process.text")
            var overlay: CGImage? = await Self.overlayInBackground(lines: copyEngine.lines,
                                                                   size: renderSize,
                                                                   previewFontPt: previewFontPt,
                                                                   screenWidth: Self.screenWidthPt)
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
                                                 lines: copyEngine.lines,
                                                 screenWidth: Self.screenWidthPt,
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
                    // 左下角挂上这一拍的缩略图（点开能播实况 + 跳相册）
                    publishShot(still: still.url,
                                identifier: outcome.localIdentifier,
                                isLive: outcome.verifiedLive)
                    // 拿到完整相册权限时会回读确认；确认不了就不把话说满
                    statusText = outcome.verifiedLive == true
                        ? "已存入相册 · 系统已确认是实况 · 抖音「+ → 相册 → 动图」直接发"
                        : "已存入相册 · 抖音「+ → 相册 → 动图」直接发"
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
            // 实况没配上也算出片：缩略图照样挂上，只是没有相册标识
            publishShot(still: still, identifier: nil, isLive: false)
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

    private static func makeVideo(source: URL, lines: [String], screenWidth: CGFloat,
                                  identifier: String) async throws -> VideoOutput {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<VideoOutput, Error>) in
            BurnEngine.makeVideo(source: source,
                                 lines: lines,
                                 previewFontPt: 13,
                                 screenWidthPt: screenWidth,
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
