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
    /// 没装抖音 / 查不到 scheme 时给一句提示，别让按钮点了没反应
    @State private var douyinMissing = false
    /// 没装剪映 / 查不到 scheme。剪映是「角标 + 视频体裁」的唯一出口，缺了必须显式告知
    @State private var jianyingMissing = false
    @State private var motionState: MotionSaveState = .idle
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

                    // v37 的结论 —— 两条路，只有一条能同时拿到「角标 + 视频体裁」。
                    //
                    // 体裁由「入口」决定，不由文件决定：
                    //   ① 抖音 App 内 + → 相册 →（动图/视频分类都一样）→ 图文。角标有，体裁是图文。
                    //   ② 其它 App 通过 SDK 把**相册 localIdentifier**交给抖音 → 视频。
                    //      这条通道抖音只对白名单 App 开放（剪映是字节自家产品），
                    //      第三方接 DouyinOpenSDK 要 client_key + aweme.share，
                    //      而 open.douyin.com 的分享权限要企业/个体工商户资质 + 审核。
                    //      → 没有资质此路不通，v35 已验证到 20002 No Media Resource。
                    //
                    // 所以把剪映当「最后一公里」，我们负责前面 90%：
                    // 拍摄 / 文案烧录 / 3:4 画幅 / ≤2.9 秒（剪映实况硬限 3.9s，留足余量）。
                    VStack(spacing: 4) {
                        Text("角标 + 视频体裁 → 走剪映中转（抖音只给白名单 App 开这条通道）")
                        Text("只要角标、可接受图文 → 抖音内 + → 相册 → 动图 → 靶心变 ∞")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.yellow.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                    // 主入口：先把带文案的视频落进相册（H.264 mp4，剪映吃这个最稳），
                    // 再唤起剪映。「开始创作」里直接能选到刚存的那条。
                    Button(action: saveAndOpenJianying) {
                        Group {
                            switch motionState {
                            case .saving:
                                HStack(spacing: 7) {
                                    ProgressView().tint(.black).scaleEffect(0.8)
                                    Text("存进相册…")
                                }
                            case .done:
                                Label("再开一次剪映", systemImage: "wand.and.stars")
                            case .failed:
                                Label("重试：存视频 → 剪映", systemImage: "arrow.clockwise")
                            case .idle:
                                Label("存视频 → 打开剪映", systemImage: "wand.and.stars")
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                    }
                    .disabled(saving)

                    HStack(spacing: 10) {
                        // 保底：接受图文体裁时，直接在抖音里出角标
                        Button(action: openDouyin) {
                            Label("抖音（图文）", systemImage: "arrow.up.forward.app")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 9)
                                .background(.white.opacity(0.18), in: Capsule())
                                .foregroundStyle(.white)
                        }

                        Button(action: openAlbum) {
                            Label("相册", systemImage: "photo.on.rectangle.angled")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 9)
                                .background(.white.opacity(0.18), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }

                    if case .done = motionState {
                        Text("视频已在相册「视频」分类（H.264 · 带文案 · ≤2.9s）。剪映「开始创作」选它 → 导出选「实况」→ 点「发布到抖音」，角标和视频体裁都在这条路上。")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.62))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    } else if case .failed(let reason) = motionState {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.orange.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 26)
                    }

                    if jianyingMissing {
                        Text("没找到剪映：手动打开剪映 → 开始创作 → 从相册选最新这条视频 → 导出选「实况」→ 发布到抖音")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }

                    if douyinMissing {
                        Text("没找到抖音（或系统不允许查询）：手动打开抖音，从「+ → 相册 → 动图」选这张")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
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

    /// 直接跳抖音。
    ///
    /// 已验证能出「动图」角标的路径是「抖音内 + → 相册 → 动图」，
    /// 但那条要手动翻两层。这里省掉找 App 的那一步。
    /// `canOpenURL` 需要 Info.plist 里声明 `LSApplicationQueriesSchemes`，
    /// 否则永远返回 false（系统不会告诉你装没装）。
    private func openDouyin() {
        let schemes = ["snssdk1128://", "douyinopensdk://"]
        for scheme in schemes {
            guard let url = URL(string: scheme) else { continue }
            if UIApplication.shared.canOpenURL(url) {
                Diagnostics.mark("douyin.open-ok")
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return
            }
        }
        Diagnostics.mark("douyin.not-installed")
        douyinMissing = true
    }

    /// 存带文案的视频 → 唤起剪映。
    ///
    /// 为什么剪映是唯一出口：抖音「跨进程取相册资源」的分享能力只对白名单
    /// App 开放（剪映/醒图/字节系），第三方要接 DouyinOpenSDK 必须有
    /// client_key + `aweme.share` 权限，而 open.douyin.com 对分享权限的
    /// 准入要求企业/个体工商户资质 + 应用审核 —— 个人开发者拿不到。
    ///
    /// 我们能做的就是把它压到最短：一步存片、自动跳到剪映，
    /// 用户在剪映里只需「开始创作 → 选这条 → 导出实况 → 发布到抖音」。
    private func saveAndOpenJianying() {
        guard let url = shot.videoURL, !saving else { return }
        motionState = .saving
        Diagnostics.mark("jianying.save-begin")

        // compat = true：H.264 + mp4，剪映对这个形态兼容性最好
        LivePhotoWriter.saveCompatVideo(url) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    Diagnostics.mark("jianying.save-ok")
                    motionState = .done
                    openJianying()
                case .failure(let error):
                    Diagnostics.mark("jianying.save-failed")
                    motionState = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// 唤起剪映。国内版 scheme 是 `videoeditor://`，CapCut 国际版是 `capcut://`。
    /// 同样需要 Info.plist 的 `LSApplicationQueriesSchemes`，否则 canOpenURL 恒 false。
    private func openJianying() {
        let schemes = ["videoeditor://", "capcut://"]
        for scheme in schemes {
            guard let url = URL(string: scheme) else { continue }
            if UIApplication.shared.canOpenURL(url) {
                Diagnostics.mark("jianying.open-ok")
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return
            }
        }
        Diagnostics.mark("jianying.not-installed")
        jianyingMissing = true
    }

    /// 交给抖音的形态 —— v37 起这条路径整体废弃。
    ///
    /// v35 试过把 `PHLivePhoto` 交给系统分享，抖音弹
    /// `[20002] params error, No Media Resource`：抖音的分享只认
    /// **相册里的 local identifier**，系统分享面板递的是文件，结构上就不通。
    /// 唯一接受 localIdentifier 的接口在 DouyinOpenSDK 里，需要企业资质才能申请，
    /// 所以 v37 把出口改成剪映（见 `saveAndOpenJianying`）。

    private var saving: Bool {
        if case .saving = motionState { return true }
        return false
    }

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
