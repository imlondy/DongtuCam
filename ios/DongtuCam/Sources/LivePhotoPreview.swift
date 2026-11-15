import SwiftUI
import Photos
import PhotosUI
import UIKit
import AVFoundation

/// 一拍的结果。
///
/// `thumbnail` 取自本地的 still.heic（不依赖相册权限、也不需要等 PhotoKit），
/// `localIdentifier` 是刚写进相册那张的 PHAsset 标识 —— 点缩略图就用它回读实况。
struct ShotResult: Identifiable {
    let id = UUID()
    let thumbnail: UIImage?
    let localIdentifier: String?
    /// true = 系统已确认是实况；false = 只存成普通照片；nil = 没权限回读
    let isLive: Bool?
    /// 这一拍的静音动图（已压字、已转正）。缓存区里的副本。
    /// **这是带实况标记的原片**：文件级 `com.apple.quicktime.content.identifier`
    /// + 轨级 `still-image-time` 都在里面，和相册里那张 HEIC 是配对的。
    let videoURL: URL?
    /// 这一拍的封面 HEIC（缓存区副本）。和 `videoURL` 用同一个配对标识，
    /// 两个文件一起交给抖音，才构成完整的「实况」。
    let stillURL: URL?
    let createdAt = Date()

    /// 成片画幅（宽/高）。缩略图是带方向变换解码出来的，尺寸就是显示尺寸，
    /// 所以直接拿它的比例；真拿不到时退回 3:4（本 App 唯一的拍摄画幅）。
    static func previewAspect(_ image: UIImage?) -> CGFloat {
        guard let size = image?.size, size.width > 1, size.height > 1 else { return 3.0 / 4.0 }
        let ratio = size.width / size.height
        // 畸形值（0、NaN、极端长条）一律不采用，避免布局算出 0 高度
        guard ratio.isFinite, ratio > 0.2, ratio < 5 else { return 3.0 / 4.0 }
        return ratio
    }

    /// 把 aspect 的画面等比塞进 size：只留黑边，绝不拉伸。
    static func fittedRect(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0.01, size.width > 1, size.height > 1 else {
            return CGRect(origin: .zero, size: size)
        }
        let containerAspect = size.width / size.height
        if aspect > containerAspect {
            // 画面更宽 → 贴左右，上下留边
            let h = size.width / aspect
            return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
        } else {
            // 画面更高（3:4 属这一档）→ 贴上下，左右留边
            let w = size.height * aspect
            return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
        }
    }
}

/// 从本地文件生成缩略图。用 ImageIO 的 thumbnail 接口，
/// 只解码需要的那一档（几十 KB），不会把 2160x2880 的原图整张读进内存。
enum ShotThumbnailMaker {
    static func image(from url: URL, maxSide: CGFloat = 420) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                           options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - 左下角缩略图

struct ShotThumbnail: View {
    let shot: ShotResult
    let action: () -> Void

    /// 缩略图本身也是 3:4 —— 之前塞进正方形里，等于把画面裁掉一截，
    /// 一眼看不出成片画幅（用户会以为拍出来是方的）。
    private var aspect: CGFloat { ShotResult.previewAspect(shot.thumbnail) }

    /// 在底部控件的高度（62）内按比例适配，画面比例不被改动，也不会溢出到快门那一行
    private var thumbSize: CGSize {
        let maxW: CGFloat = 74
        let maxH: CGFloat = 60
        let w = min(maxW, maxH * aspect)
        return CGSize(width: w, height: w / max(aspect, 0.01))
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image = shot.thumbnail {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Rectangle().fill(.white.opacity(0.16))
                            Image(systemName: "photo")
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .frame(width: thumbSize.width, height: thumbSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(.white.opacity(0.9), lineWidth: 1.8)
                )

                // 实况角标：一眼看出这张是不是"能动的"
                if shot.isLive != false {
                    Image(systemName: "livephoto")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.yellow)
                        .padding(4)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("最近一张动图，点击查看")
    }
}

// MARK: - 全屏预览（能播的实况 + 一键去相册）

struct LivePhotoPreviewSheet: View {
    let shot: ShotResult
    @Environment(\.dismiss) private var dismiss

    @State private var livePhoto: PHLivePhoto?
    @State private var status = "载入动图…"
    @State private var albumUnavailable = false
    @State private var motionState: MotionSaveState = .idle
    @State private var showShare = false
    @State private var preparing = false
    /// 交给系统分享面板的东西。可能是单个 .mov，也可能是 HEIC + MOV 两项
    @State private var shareItems: [Any] = []
    /// 这段视频的真实形态（时长 / 有无音轨 / 分辨率 / 编码 / 实况标记）。
    /// 抖音判体裁的依据就在这几个数里，发之前先看见，省得发完再猜。
    @State private var videoInfo: String?
    /// 原片里到底有没有实况标记。没有的话，抖音只会当成普通视频。
    @State private var liveMarked = false

    private enum MotionSaveState: Equatable {
        case idle
        case saving
        case done
        case failed(String)
    }

    /// 成片比例，预览、缩略图、播放器三处共用同一个值
    private var aspect: CGFloat { ShotResult.previewAspect(shot.thumbnail) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 关键：画面锁定成片比例再摆放。
            // 之前 PHLivePhotoView / Image 直接 .ignoresSafeArea() 铺满整屏，
            // 屏幕约 0.46、成片 0.75，于是被横向压扁 —— 这就是"变形"的来源。
            GeometryReader { geo in
                let box = ShotResult.fittedRect(aspect: aspect, in: geo.size)

                Group {
                    if let livePhoto {
                        LivePhotoPlayer(livePhoto: livePhoto)
                    } else if let image = shot.thumbnail {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ZStack {
                            Rectangle().fill(.white.opacity(0.08))
                            ProgressView().tint(.white)
                        }
                    }
                }
                .frame(width: box.width, height: box.height)
                .clipped()
                .position(x: box.midX, y: box.midY)
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(11)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                VStack(spacing: 12) {
                    if livePhoto == nil {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }

                    if let videoInfo {
                        VStack(spacing: 2) {
                            Text(videoInfo)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.5))
                            Text(liveMarked
                                 ? "✓ 带实况标记（content.identifier + still-image-time）"
                                 : "✗ 无实况标记 —— 抖音只会当成普通视频")
                                .font(.caption2)
                                .foregroundStyle(liveMarked ? .green.opacity(0.85) : .orange.opacity(0.9))
                        }
                    }

                    // 验收标准只有一条：抖音**发布页左上角**有没有「动图」标。
                    // 那是抖音收到素材时的即时判定，比发布后的作品页更早、更准。
                    VStack(spacing: 3) {
                        Text("验收标准：抖音发布页左上角出现「动图」标")
                        Text("出现了就成了；没有就换下面的「实况包」再试一次")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.yellow.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                    HStack(spacing: 10) {
                        // 主路径：把**带实况标记的原片**交给抖音。
                        // 之前几版都先转码成 mp4 —— AVAssetExportSession 会把
                        // content.identifier 和 still-image-time 一起丢掉，
                        // 抖音收到的是个干净视频，发布页自然没有「动图」标。
                        if shot.videoURL != nil {
                            Button { share(.liveMovie) } label: {
                                Group {
                                    if preparing {
                                        HStack(spacing: 7) {
                                            ProgressView().tint(.black).scaleEffect(0.8)
                                            Text("准备…")
                                        }
                                    } else {
                                        Label("发布到抖音", systemImage: "square.and.arrow.up")
                                    }
                                }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(.white, in: Capsule())
                                .foregroundStyle(.black)
                            }
                            .disabled(preparing)
                        }

                        Button(action: openAlbum) {
                            Label("相册", systemImage: "photo.on.rectangle.angled")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(.white.opacity(0.18), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }

                    // 对照实验：同一条成片，三种交付形态各发一次。
                    // 抖音的判定条件不公开，与其继续猜，不如让它自己给出答案。
                    if shot.videoURL != nil {
                        HStack(spacing: 8) {
                            Button { share(.liveBundle) } label: {
                                Label("实况包 HEIC+MOV", systemImage: "rectangle.stack")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.white.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            .disabled(preparing || shot.stillURL == nil)

                            Button { share(.compatMP4) } label: {
                                Label("纯视频 mp4", systemImage: "film")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.white.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            .disabled(preparing)
                        }
                    }

                    // 备用：只想把视频落进相册时用（从相册上传会是图文，别指望角标）
                    if shot.videoURL != nil {
                        Button { saveMotionVideo(compat: true) } label: {
                            Group {
                                switch motionState {
                                case .saving:
                                    HStack(spacing: 7) {
                                        ProgressView().tint(.white).scaleEffect(0.8)
                                        Text("存相册…")
                                    }
                                case .done:
                                    Label("视频已存相册", systemImage: "checkmark.circle.fill")
                                case .failed:
                                    Label("重试存视频", systemImage: "arrow.clockwise")
                                case .idle:
                                    Label("只存进相册（视频分类）", systemImage: "film")
                                }
                            }
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.12), in: Capsule())
                            .foregroundStyle(.white.opacity(0.9))
                        }
                        .disabled(saving)
                    }

                    if case .done = motionState {
                        Text("已存进相册「视频」分类。注意：从相册上传会被抖音判成图文，要视频体裁仍然得走「发布到抖音」。")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 26)
                    } else if case .failed(let reason) = motionState {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.orange.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 26)
                    }

                    if albumUnavailable {
                        Text("系统没有开放跳转相册的入口，请手动打开「照片」App")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .onAppear(perform: load)
        .task(id: shot.id) { loadVideoInfo() }
        .sheet(isPresented: $showShare) {
            ActivitySheet(items: shareItems)
        }
    }

    /// 读这段动图的真实参数。只读元数据，不解码画面。
    /// 编码格式和码率也要看 —— 抖音判体裁的依据很可能就在这几个数里。
    private func loadVideoInfo() {
        guard let url = shot.videoURL else { return }
        DispatchQueue.global(qos: .utility).async {
            let asset = AVAsset(url: url)
            let seconds = asset.duration.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            let track = asset.tracks(withMediaType: .video).first
            let size = track?.naturalSize ?? .zero
            let fps = track.map { Int(($0.nominalFrameRate).rounded()) } ?? 0
            let hasAudio = !asset.tracks(withMediaType: .audio).isEmpty
            let codec = track.map { Self.codecName($0) } ?? "?"
            let mbps = (track?.estimatedDataRate ?? 0) / 1_000_000

            // 实况的两块物证：文件级配对标识 + 轨级 still-image-time。
            // 抖音若按实况解析，读的就是这两个；少一个它只会当普通视频。
            let identifier = asset.metadata.first {
                ($0.key as? String) == "com.apple.quicktime.content.identifier"
            }?.stringValue
            let timedTracks = asset.tracks.filter { $0.mediaType == .metadata }.count
            let marked = (identifier?.isEmpty == false) || timedTracks > 0

            var text = String(format: "%.1f 秒 · %.0f×%.0f · %d fps", seconds, size.width, size.height, fps)
            text += " · " + codec
            text += hasAudio ? " · 带音轨" : " · 无音轨"
            if mbps > 0.05 { text += String(format: " · %.1f Mbps", mbps) }
            DispatchQueue.main.async {
                videoInfo = text
                liveMarked = marked
            }
        }
    }

    private static func codecName(_ track: AVAssetTrack) -> String {
        guard let desc = track.formatDescriptions.first else { return "?" }
        let sub = CMFormatDescriptionGetMediaSubType(desc as! CMFormatDescription)
        switch sub {
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_H264: return "H.264"
        default:
            let bytes: [UInt8] = [UInt8((sub >> 24) & 0xFF), UInt8((sub >> 16) & 0xFF),
                                  UInt8((sub >> 8) & 0xFF), UInt8(sub & 0xFF)]
            return String(bytes: bytes, encoding: .ascii) ?? "未知编码"
        }
    }

    /// 从相册回读刚存的那张实况。
    /// 只有拿到「完整相册权限」才读得到；只有「添加照片」权限时会落到本地缩略图。
    private func load() {
        guard let identifier = shot.localIdentifier else {
            status = "已保存，但没有拿到相册标识（只授了「添加照片」权限）"
            return
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else {
            status = "相册里没找到这一张，请在「照片」里确认"
            return
        }
        // 从相册回读实况要用 PHImageManager（PHLivePhoto 自己的 request 只接受文件 URL）
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false

        _ = PHImageManager.default().requestLivePhoto(for: asset,
                                                     targetSize: CGSize(width: 900, height: 1200),
                                                     contentMode: .aspectFit,
                                                     options: options) { photo, _ in
            DispatchQueue.main.async {
                if let photo {
                    livePhoto = photo
                } else {
                    status = "这张没有动图部分（实况没配上），封面仍可正常查看"
                }
            }
        }
    }

    private func openAlbum() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            DispatchQueue.main.async {
                if !ok { albumUnavailable = true }
            }
        }
    }

    /// 交给抖音的三种形态。抖音的判定条件没公开，只能让它自己挑。
    private enum ShareMode {
        /// 带实况标记的原片 .mov（首选）：H.264 + content.identifier + still-image-time
        case liveMovie
        /// HEIC + MOV 两项一起给：构成完整的实况，抖音若按配对解析就会认出「动图」
        case liveBundle
        /// 转码成 mp4 的纯视频（对照用，历史上就是这条没有「动图」标）
        case compatMP4
    }

    /// 打开系统分享面板，把这一拍的素材交给抖音。
    ///
    /// **绝对不能再无条件转码**：`AVAssetExportSession` 只搬音视频轨，
    /// 文件级的 `com.apple.quicktime.content.identifier` 和轨级的
    /// `still-image-time` 都会被丢掉。抖音收到一个干净 mp4，发布页左上角
    /// 就不会出现「动图」标 —— 这正是 v32/v33 的症状。
    private func share(_ mode: ShareMode) {
        guard !preparing else { return }
        switch mode {
        case .liveMovie:
            guard let url = shot.videoURL else { return }
            Diagnostics.mark("share.live-movie")
            shareItems = [url]
            showShare = true

        case .liveBundle:
            var items: [Any] = []
            if let still = shot.stillURL { items.append(still) }
            if let mov = shot.videoURL { items.append(mov) }
            guard !items.isEmpty else { return }
            Diagnostics.mark("share.live-bundle")
            shareItems = items
            showShare = true

        case .compatMP4:
            guard let url = shot.videoURL else { return }
            preparing = true
            Diagnostics.mark("share.compat-begin")
            LivePhotoWriter.transcodeCompat(url) { result in
                DispatchQueue.main.async {
                    preparing = false
                    switch result {
                    case .success(let out):
                        shareItems = [out]
                    case .failure:
                        // 转码失败不能拦住用户：原片照样能发
                        Diagnostics.mark("share.compat-failed")
                        shareItems = [url]
                    }
                    showShare = !shareItems.isEmpty
                }
            }
        }
    }

    private var saving: Bool {
        if case .saving = motionState { return true }
        return false
    }

    /// 把这一拍落进相册的「视频」分类。
    ///
    /// `compat = true` 会多走一遍转码：H.264 + 静音音轨 + mp4 容器，
    /// 对齐剪映导出物的形态。两条都发一次，就能看出抖音到底按什么判体裁。
    private func saveMotionVideo(compat: Bool) {
        guard let url = shot.videoURL, !saving else { return }
        motionState = .saving
        Diagnostics.mark(compat ? "motion.save-compat" : "motion.save-begin")

        let handler: (Result<Void, Error>) -> Void = { result in
            switch result {
            case .success:
                Diagnostics.mark("motion.save-ok")
                motionState = .done
            case .failure(let error):
                Diagnostics.mark("motion.save-failed")
                motionState = .failed(error.localizedDescription)
            }
        }

        if compat {
            LivePhotoWriter.saveCompatVideo(url, completion: handler)
        } else {
            LivePhotoWriter.saveVideo(url, completion: handler)
        }
    }
}

/// 系统分享面板。items 传 `.mov` 的 fileURL，抖音的 Share Extension 会接收它。
///
/// 这是「相册入口」之外唯一一条能把成片交给抖音的公开通道，
/// 也是剪映「分享到抖音」在系统层面的等价物：抖音拿到的是文件，不是相册资源。
private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items,
                                                  applicationActivities: nil)
        // iOS 不允许指定分享目标，也不允许给第三方 App 排序（排序取决于用户使用频次），
        // 唯一能做的就是把这个列表瘦下来：系统自带的邮件/信息/打印/拷贝/存相册全部排除，
        // 剩下的基本就是抖音、微信、隔空投送，抖音更容易在首屏出现。
        controller.excludedActivityTypes = [
            .addToReadingList, .assignToContact, .copyToPasteboard, .mail,
            .markupAsPDF, .message, .postToFacebook,
            .postToFlickr, .postToTencentWeibo, .postToTwitter, .postToVimeo,
            .postToWeibo, .print, .saveToCameraRoll, .sharePlay
        ]
        // iPad / 分屏下必须给 popover 一个锚点，否则弹出即崩
        if let popover = controller.popoverPresentationController {
            popover.permittedArrowDirections = []
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX,
                                        y: controller.view.bounds.midY,
                                        width: 1, height: 1)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// 包一层 PHLivePhotoView：拿到实况就自动播一遍，让用户立刻看到"动"的效果
private struct LivePhotoPlayer: UIViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        // 容器已经是成片比例的框，这里再兜一层：万一系统按自己的尺寸铺，
        // aspectFit + clipsToBounds 也只会留黑边，不会拉伸
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.backgroundColor = .clear
        view.livePhoto = livePhoto
        view.startPlayback(with: .full)
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto {
            view.livePhoto = livePhoto
            view.startPlayback(with: .full)
        }
    }
}
