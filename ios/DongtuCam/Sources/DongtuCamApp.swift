import SwiftUI
import AVFoundation
import UIKit

@main
struct DongtuCamApp: App {
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
            fatalError("PreviewUIView 的 layer 必须是 AVCaptureVideoPreviewLayer")
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

    @State private var phase: Phase = .idle
    @State private var permission = false
    @State private var statusText = "选好商品 → 点快门拍 5 秒 → 自动出片"
    @State private var lastError: String?
    /// 显示在右上角的构建标识：装错包时一眼就能看出来
    private let buildTag = "v9"

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
        .onAppear(perform: askPermission)
        .onDisappear(perform: camera.stop)
    }

    // MARK: 顶部：自动匹配商品 + 文案控制

    private var topBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(copyEngine.products) { product in
                    Button(product.name) { copyEngine.select(product) }
                }
            } label: {
                Label(copyEngine.selected?.name ?? "选商品", systemImage: "shippingbox")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Button {
                if let text = UIPasteboard.general.string {
                    _ = copyEngine.match(text)
                }
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.subheadline.weight(.semibold))
                    .padding(9)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Button(action: copyEngine.regenerate) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .padding(9)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Button {
                Task { await copyEngine.regenerateFromServer() }
            } label: {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .padding(9)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            Text(buildTag)
                .font(.caption2.weight(.black))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.yellow, in: Capsule())
                .foregroundStyle(.black)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    /// 只是拍前预览，不会进画面；真正烧录由 TextLayer 完成
    private var copyPreview: some View {
        VStack(spacing: 2) {
            ForEach(copyEngine.lines.indices, id: \.self) { index in
                Text(copyEngine.lines[index])
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
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

    // MARK: 一次快门 = 完整链路，全程不需要第二个人工步骤

    private func shoot() {
        guard !working else { return }
        phase = .recording
        statusText = "录制 5 秒…"

        camera.capture(seconds: 5.0) { result in
            switch result {
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
                self.lastError = "录制失败\n" + error.localizedDescription
                self.statusText = "录制失败：\(error.localizedDescription)"
            case .success(let url):
                self.process(url)
            }
        }
    }

    private func process(_ source: URL) {
        phase = .processing
        statusText = "匹配文案 → 逐帧烧录 → 写入相册…"

        let asset = AVAsset(url: source)
        guard let track = asset.tracks(withMediaType: .video).first else {
            phase = .failed("没有视频轨")
            statusText = "素材里没有视频轨"
            return
        }
        let natural = track.naturalSize.applying(track.preferredTransform)
        let size = CGSize(width: abs(natural.width), height: abs(natural.height))
        guard let overlay = TextLayer.make(lines: copyEngine.lines, size: size) else {
            phase = .failed("文案渲染失败")
            statusText = "文案渲染失败，请先选商品"
            return
        }

        BurnEngine.render(source: source, overlay: overlay) { burned in
            switch burned {
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
                self.lastError = "处理失败\n" + error.localizedDescription
                self.statusText = "处理失败：\(error.localizedDescription)"
            case .success(let output):
                LivePhotoWriter.save(still: output.stillURL, video: output.videoURL,
                                     report: output.report) { saved in
                    switch saved {
                    case .success:
                        self.phase = .done
                        self.lastError = nil
                        self.statusText = "已存入相册 · 抖音「+ → 相册 → 动图」直接发"
                    case .failure(let error):
                        self.phase = .failed(error.localizedDescription)
                        self.lastError = "\(self.buildTag) 写入相册失败\n" + error.localizedDescription
                        self.statusText = "写入相册失败（详情见下方）"
                    }
                }
            }
        }
    }
}
