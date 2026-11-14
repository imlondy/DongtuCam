import SwiftUI
import AVFoundation
import UIKit

@main
struct DongtuCamApp: App {
    init() {
        Diagnostics.installCrashHandler()
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

    /// 显示在右上角的构建标识：装错包时一眼就能看出来
    private let buildTag = "v18"
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
                statusBar
                shutter
            }
        }
        .onAppear(perform: onAppear)
        .onDisappear(perform: camera.stop)
        .sheet(isPresented: $showSettings) {
            AISettingsView(settings: aiSettings, copyEngine: copyEngine)
        }
    }

    private func onAppear() {
        askPermission()
        // 后台配置：打开就同步一次（失败无所谓，沿用上一次的值）
        Task { @MainActor in await aiSettings.syncRemote() }
        // 上次是崩着退出的：把现场留在界面上，截图就能定位
        if let incident = Diagnostics.takeLastIncident() {
            lastError = "\(buildTag) 上次现场\n" + incident
            // 自愈：连续崩就直接降级到「只出片」，不再碰识别与 AI。
            // 宁可少一个功能，也不能让用户每次拍都闪退。
            let fragile = ["copy.recognize", "process.frame", "process.text",
                           "process.compose", "burn.", "process.save", "camera.record"]
            if fragile.contains(where: { incident.contains($0) }) {
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
        .padding(.bottom, 30)
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
            let renderSize = CGSize(width: frame.width, height: frame.height)
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

            // 5) 视频：相机原片无损重封装 + 配对元数据，不解码、不重编码。
            //    这是全链路里被 v10~v14 真机验证过最稳的一段，也是唯一能出「动图」的路。
            statusText = "封装视频…"
            Diagnostics.mark("process.video")
            var video: VideoOutput?
            do {
                video = try await Self.makeVideo(source: source, identifier: identifier)
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
                    try await Self.saveLivePhoto(still: still.url, video: video.url, report: report)
                    ShotStore.shared.finish(shotID)
                    phase = .done
                    lastError = nil
                    statusText = "已存入相册 · 抖音「+ → 相册 → 动图」直接发"
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
                                  identifier: String) async throws -> StillOutput {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<StillOutput, Error>) in
            BurnEngine.makeStill(frame: frame, overlay: overlay,
                                 identifier: identifier) { result in
                continuation.resume(with: result)
            }
        }
    }

    private static func makeVideo(source: URL,
                                  identifier: String) async throws -> VideoOutput {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<VideoOutput, Error>) in
            BurnEngine.makeVideo(source: source, identifier: identifier) { result in
                continuation.resume(with: result)
            }
        }
    }

    private static func saveLivePhoto(still: URL, video: URL, report: String) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
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
