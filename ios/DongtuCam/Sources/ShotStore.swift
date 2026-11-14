import Foundation
import UIKit

/// 拍摄素材的本地暂存区：**先落盘，再处理，写库成功才删**。
///
/// ## 为什么必须有这一层
///
/// iOS 上的闪退是进程级死亡：`do/catch`、`defer`、`DispatchGroup.notify`
/// 统统不会执行。只要处理链路里任何一步把进程带走，用户这一拍就凭空消失
/// ——v15 的体验就是这样（相册里什么都没有）。
///
/// 所以把顺序倒过来：
///   录制结束 → 原片立刻复制进 Documents/PendingShots/&lt;id&gt;/
///   之后每一步产物（带字静帧、配好元数据的视频）也写进同一个目录
///   写相册成功 → 删目录
///   进程中途死掉 → 目录留着 → 下次冷启动扫描出来，自动补存进相册
///
/// 这一步不依赖任何解码/编码，只是文件复制（几 MB），1 秒内完成，
/// 是整条链路里唯一「几乎不可能失败」的操作。
///
/// ## 恢复策略（宁可降级，不可丢弃）
///   1. 有 still.heic + video.mov → 先试实况配对（用户最想要的结果）
///   2. 配对失败 / 只有 still → 存一张带文字的照片
///   3. 连静帧都没有 → 把原片存成普通视频（就是 v13 那种「闪退也留了视频」）
///   每条最多尝试 2 次，避免某段素材把 App 拖进「启动即崩、崩完再试」的死循环。
final class ShotStore {
    static let shared = ShotStore()

    private let root: URL
    private let queue = DispatchQueue(label: "dtc.shotstore")

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = docs.appendingPathComponent("PendingShots", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    struct Shot {
        let id: String
        let dir: URL
        /// 相机原始录制文件
        var source: URL? { existing(dir.appendingPathComponent("source.mov")) }
        /// 带文字的 HEIC 静帧
        var still: URL? { existing(dir.appendingPathComponent("still.heic")) }
        /// 已注入配对元数据（必要时也压好字）的视频
        var video: URL? { existing(dir.appendingPathComponent("video.mov")) }
        var attempts: Int { Int(meta["attempts"] ?? "0") ?? 0 }
        var meta: [String: String] { ShotStore.readMeta(dir) }

        private func existing(_ url: URL) -> URL? {
            FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    // MARK: - 录制后立刻调用

    /// 把原片复制进暂存区。返回 id；失败返回 nil（此时调用方应直接走「存视频」兜底）。
    func begin(video: URL) -> String? {
        let id = String(UUID().uuidString.prefix(8))
        let dir = root.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: video, to: dir.appendingPathComponent("source.mov"))
        } catch {
            Diagnostics.mark("store.begin-failed")
            return nil
        }
        writeMeta(["createdAt": "\(Date().timeIntervalSince1970)", "stage": "staged"], to: dir)
        Diagnostics.mark("store.begin-\(id)")
        return id
    }

    /// 把某个中间产物收进暂存目录（复制，不动原文件）。
    /// - Parameter name: `still.heic` / `video.mov`
    @discardableResult
    func keep(_ temp: URL, as name: String, id: String) -> URL? {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: temp, to: dest)
            return dest
        } catch {
            Diagnostics.mark("store.keep-failed-\(name)")
            return nil
        }
    }

    func mark(_ id: String?, stage: String) {
        guard let id else { return }
        let dir = root.appendingPathComponent(id, isDirectory: true)
        var meta = Self.readMeta(dir)
        meta["stage"] = stage
        writeMeta(meta, to: dir)
    }

    func finish(_ id: String?) {
        guard let id else { return }
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        Diagnostics.mark("store.finish-\(id)")
    }

    // MARK: - 扫描

    func pending() -> [Shot] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .compactMap { name -> Shot? in
                let dir = root.appendingPathComponent(name, isDirectory: true)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                      isDir.boolValue else { return nil }
                return Shot(id: name, dir: dir)
            }
            .sorted { ($0.meta["createdAt"] ?? "") < ($1.meta["createdAt"] ?? "") }
            .filter { $0.source != nil || $0.still != nil || $0.video != nil }
    }

    /// 冷启动 / 回到前台时调用。把没走完的素材补存进相册。
    /// - Parameter completion: 主线程回调；nil 表示没有待处理素材，否则是一句给用户看的结果
    func recover(completion: @escaping (String?) -> Void) {
        let shots = pending()
        guard !shots.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        Diagnostics.mark("store.recover-\(shots.count)")
        recoverNext(Array(shots.prefix(3)), saved: 0, failed: 0, completion: completion)
    }

    private func recoverNext(_ shots: [Shot], saved: Int, failed: Int,
                             completion: @escaping (String?) -> Void) {
        guard let shot = shots.first else {
            let message: String?
            if saved > 0 {
                message = "上次中断的素材已补存进相册（\(saved) 条）"
            } else if failed > 0 {
                message = "上次中断的素材还在本地，进相册失败（\(failed) 条）"
            } else {
                message = nil
            }
            DispatchQueue.main.async { completion(message) }
            return
        }
        var rest = shots
        rest.removeFirst()

        // 同一段素材连续失败两次就不再自动重试，避免陷入「启动即崩」的循环
        guard shot.attempts < 2 else {
            finish(shot.id)
            recoverNext(rest, saved: saved, failed: failed, completion: completion)
            return
        }
        bumpAttempts(shot)

        // 1) 最好的结果：配对成实况
        if let still = shot.still, let video = shot.video {
            Diagnostics.mark("store.recover-live")
            LivePhotoWriter.save(still: still, video: video, report: "recover") { result in
                if case .success = result {
                    self.finish(shot.id)
                    self.recoverNext(rest, saved: saved + 1, failed: failed, completion: completion)
                    return
                }
                // 2) 配对失败：至少把带字照片 + 视频分别存下来
                self.savePhotoThenVideo(shot, rest: rest, saved: saved, failed: failed,
                                        completion: completion)
            }
            return
        }
        // 只有静帧
        if let still = shot.still {
            Diagnostics.mark("store.recover-still")
            LivePhotoWriter.saveStill(still) { result in
                let ok = result.isSuccess
                if ok { self.finish(shot.id) }
                self.recoverNext(rest, saved: saved + (ok ? 1 : 0),
                                 failed: failed + (ok ? 0 : 1), completion: completion)
            }
            return
        }
        // 只有原片：存普通视频（这条保证「闪退也不白拍」）
        if let source = shot.source {
            Diagnostics.mark("store.recover-video")
            LivePhotoWriter.saveVideo(source) { result in
                let ok = result.isSuccess
                if ok { self.finish(shot.id) }
                self.recoverNext(rest, saved: saved + (ok ? 1 : 0),
                                 failed: failed + (ok ? 0 : 1), completion: completion)
            }
            return
        }
        finish(shot.id)
        recoverNext(rest, saved: saved, failed: failed, completion: completion)
    }

    private func savePhotoThenVideo(_ shot: Shot, rest: [Shot], saved: Int, failed: Int,
                                    completion: @escaping (String?) -> Void) {
        guard let still = shot.still else {
            recoverNext(rest, saved: saved, failed: failed, completion: completion)
            return
        }
        LivePhotoWriter.saveStill(still) { photoResult in
            guard let video = shot.video ?? shot.source else {
                let ok = photoResult.isSuccess
                if ok { self.finish(shot.id) }
                self.recoverNext(rest, saved: saved + (ok ? 1 : 0),
                                 failed: failed + (ok ? 0 : 1), completion: completion)
                return
            }
            LivePhotoWriter.saveVideo(video) { videoResult in
                let ok = photoResult.isSuccess || videoResult.isSuccess
                if ok { self.finish(shot.id) }
                self.recoverNext(rest, saved: saved + (ok ? 1 : 0),
                                 failed: failed + (ok ? 0 : 1), completion: completion)
            }
        }
    }

    private func bumpAttempts(_ shot: Shot) {
        var meta = shot.meta
        meta["attempts"] = "\(shot.attempts + 1)"
        writeMeta(meta, to: shot.dir)
    }

    // MARK: - meta

    private func writeMeta(_ dict: [String: String], to dir: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: dir.appendingPathComponent("meta.json"))
    }

    static func readMeta(_ dir: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return dict
    }
}

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
