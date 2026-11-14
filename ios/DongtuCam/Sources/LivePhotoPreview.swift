import SwiftUI
import Photos
import PhotosUI
import UIKit

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
    let createdAt = Date()
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
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let livePhoto {
                LivePhotoPlayer(livePhoto: livePhoto)
                    .ignoresSafeArea()
            } else if let image = shot.thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
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
                    Button(action: openAlbum) {
                        Label("在相册中打开", systemImage: "photo.on.rectangle.angled")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
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
        _ = PHLivePhoto.request(for: asset,
                                targetSize: CGSize(width: 900, height: 1200),
                                contentMode: .aspectFit) { photo, _ in
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
}

/// 包一层 PHLivePhotoView：拿到实况就自动播一遍，让用户立刻看到"动"的效果
private struct LivePhotoPlayer: UIViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
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
