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

    /// 显示在右上角的构建标识：装错包时一眼就能看出来
    private let buildTag = "v12"

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
        // 上次是崩着退出的：把现场留在界面上，截图就能定位
        if let incident = Diagnostics.takeLastIncident() {
            lastError = "\(buildTag) 上次现场\n" + incident
        }
        Diagnostics.mark("app.ready")
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
                        .font(.system(size: 13, weight: .bold))
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

    /// frame 为 nil 表示没取到画面，此时只走 AI（无图）/ 本地模板
    @MainActor
    private func prepareCopy(frame: CGImage?) async {
        var recognition: Recognition?

        if let frame, aiSettings.config.autoRecognize {
            statusText = "识别商品…"
            recognition = await ProductRecognizer.analyze(frame: frame,
                                                          products: copyEngine.products)
            lastRecognition = recognition
            if let hit = recognition?.localHit {
                copyEngine.select(hit)
            }
            if let recognition { statusText = recognition.summary }
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
        var jpeg: Data?
        if aiSettings.config.useVision, let frame {
            jpeg = ProductRecognizer.jpegPreview(frame)
        }
        _ = await copyEngine.generateWithAI(config: aiSettings.config,
                                            recognition: recognition,
                                            imageJPEG: jpeg)
        if let note = copyEngine.note { statusText = note }
    }

    // MARK: 烧字 + 写相册

    private func process(_ source: URL) {
        Task { @MainActor in
            phase = .processing
            statusText = "整理文案…"
            Diagnostics.mark("process.begin")

            var frame: CGImage?
            if aiSettings.config.autoRecognize {
                Diagnostics.mark("process.frame")
                frame = BurnEngine.previewFrame(from: source)
            }
            await prepareCopy(frame: frame)

            if copyEngine.lines.isEmpty { copyEngine.regenerate() }
            Diagnostics.mark("process.copy")

            guard let track = AVAsset(url: source).tracks(withMediaType: .video).first else {
                phase = .failed("没有视频轨")
                statusText = "素材里没有视频轨"
                lastError = "\(buildTag) 素材里没有视频轨"
                Diagnostics.clear()
                return
            }
            let natural = track.naturalSize.applying(track.preferredTransform)
            let renderSize = CGSize(width: abs(natural.width), height: abs(natural.height))
            guard let overlay = TextLayer.make(lines: copyEngine.lines, size: renderSize) else {
                phase = .failed("文案渲染失败")
                statusText = "文案渲染失败，请先选商品"
                lastError = "\(buildTag) 文案渲染失败 · size=\(Int(renderSize.width))x\(Int(renderSize.height))"
                Diagnostics.clear()
                return
            }

            statusText = "烧录字幕 → 写入相册…"
            Diagnostics.mark("process.burn")
            do {
                let output = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<BurnOutput, Error>) in
                    BurnEngine.render(source: source, overlay: overlay) { result in
                        continuation.resume(with: result)
                    }
                }
                Diagnostics.mark("process.save")
                statusText = "写入相册…"
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    LivePhotoWriter.save(still: output.stillURL,
                                         video: output.videoURL,
                                         report: output.report) { result in
                        continuation.resume(with: result)
                    }
                }
                phase = .done
                lastError = nil
                statusText = "已存入相册 · 抖音「+ → 相册 → 动图」直接发"
                Diagnostics.clear()
            } catch {
                phase = .failed(error.localizedDescription)
                lastError = "\(buildTag) 失败\n" + error.localizedDescription
                statusText = "处理失败（详情见下方）"
                Diagnostics.clear()
            }
        }
    }
}
