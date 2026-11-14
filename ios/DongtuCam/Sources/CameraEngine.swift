import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

enum CameraError: LocalizedError {
    case busy
    case notRunning

    var errorDescription: String? {
        switch self {
        case .busy: return "上一段还在录制，稍等一下"
        case .notRunning: return "相机没能启动，请退出重进（或检查相机权限）"
        }
    }
}

/// 打开即相机：固定录 5 秒短视频。
///
/// 历史教训（别再踩）：
/// 1) v11 曾在同一会话再挂一路 `AVCaptureVideoDataOutput` 抓帧，录制输出与数据输出
///    同时挂在 4K 会话上，`startRecording` 易抛 ObjC 异常，且 4K 缓冲 + CGImage
///    让内存成倍上涨被系统直接杀掉。现在只保留一路录制输出。
/// 2) `selectThreeFourFormat` 以前只按「宽高比 3:4」挑格式，会挑到**只支持拍照**的
///    still-image 格式（4032x3024 也是 4:3），这种格式喂给 MovieFileOutput
///    属于无效组合。现在强制要求是**视频编码格式**（420v/420f/x420）。
/// 3) 相机配置不再放在 `init` 里做：init 跑在 SwiftUI 建视图阶段（主线程），
///    一旦 AVFoundation 卡住或抛异常就是「打开即闪退」。现在挪进 `start()`，
///    在专用串行队列上做，并且每一步都留面包屑。
final class CameraEngine: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "dtc.camera.session")
    private var onFinish: ((Result<URL, Error>) -> Void)?
    private var configured = false

    @Published private(set) var isRecording = false

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.configureIfNeeded() else {
                Diagnostics.mark("camera.configure-failed")
                return
            }
            guard !self.session.isRunning else { return }
            Diagnostics.mark("camera.start")
            self.session.startRunning()
            Diagnostics.mark(self.session.isRunning ? "camera.running" : "camera.start-failed")
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: - 配置

    /// 只在第一次真正需要时配置一次；返回是否配置成功
    private func configureIfNeeded() -> Bool {
        if configured { return true }
        Diagnostics.mark("camera.begin-config")
        session.beginConfiguration()
        // 让 activeFormat 决定分辨率，而不是被 sessionPreset 覆盖
        session.sessionPreset = .inputPriority

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video, position: .back) else {
            session.commitConfiguration()
            Diagnostics.mark("camera.no-device")
            return false
        }
        Self.selectThreeFourFormat(on: device)
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            Diagnostics.mark("camera.no-input")
            return false
        }
        session.addInput(input)

        if let mic = AVCaptureDevice.default(for: .audio),
           let audio = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audio) {
            session.addInput(audio)
        }
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        session.commitConfiguration()
        configured = true
        Diagnostics.mark("camera.configured")
        return true
    }

    /// 挑一个 3:4 的**视频**格式，竖屏 3:4 / 横屏 4:3 旋转后都是 3:4，
    /// 成片 100% 来自原片、无需任何裁切。
    ///
    /// 这里踩过一个致命坑（v12 的闪退真凶）：旧代码只按「宽高比 4:3」筛格式，
    /// 而 iPhone 的**静态照片格式**（4032x3024 之类）也是 4:3，结果把它设成了
    /// activeFormat。拍照格式喂给 `AVCaptureMovieFileOutput` 是无效组合，
    /// 一按快门就抛 ObjC 异常 → 闪退。
    /// 现在强制要求媒体子类型是视频编码（420v/420f/x420）。
    private static func selectThreeFourFormat(on device: AVCaptureDevice) {
        let videoSubTypes: Set<FourCharCode> = [0x34323076, 0x34323066, 0x78343230]

        func dimension(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        }
        func isVideo(_ format: AVCaptureDevice.Format) -> Bool {
            videoSubTypes.contains(CMFormatDescriptionGetMediaSubType(format.formatDescription))
        }
        func area(_ format: AVCaptureDevice.Format) -> Int {
            let d = dimension(format)
            return Int(d.width) * Int(d.height)
        }
        func minSide(_ format: AVCaptureDevice.Format) -> Int {
            let d = dimension(format)
            return min(Int(d.width), Int(d.height))
        }

        let videoFormats = device.formats.filter(isVideo)
        guard !videoFormats.isEmpty else { return }

        let portrait: CGFloat = 3.0 / 4.0
        let landscape: CGFloat = 4.0 / 3.0
        let threeFour = videoFormats.filter { format in
            let d = dimension(format)
            guard d.height > 0 else { return false }
            let ratio = CGFloat(d.width) / CGFloat(d.height)
            return abs(ratio - portrait) < 0.02 || abs(ratio - landscape) < 0.02
        }
        // 手机内存有限：优先 1080~1600 级里最大的那个。
        // 抖音动图最终也是这个量级，清楚够用，且不会把内存顶到红线（被系统杀掉＝闪退）。
        func largest(_ formats: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
            let capped = formats.filter { minSide($0) <= 1600 }
            return (capped.isEmpty ? formats : capped).max { area($0) < area($1) }
        }

        let best: AVCaptureDevice.Format?
        if let pick = largest(threeFour) {
            best = pick
        } else {
            // 这台机器没有 3:4 视频格式：退到标准 16:9（1080p 级），
            // 画面依然是原片，只是成片比例变成 9:16，抖音本来也更吃这个比例。
            let wide = videoFormats.filter { format in
                let d = dimension(format)
                guard d.height > 0 else { return false }
                return abs(CGFloat(d.width) / CGFloat(d.height) - 16.0 / 9.0) < 0.03
            }
            best = largest(wide.isEmpty ? videoFormats : wide)
        }
        guard let best else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.unlockForConfiguration()
        } catch {
            // 降级：使用系统默认格式
        }
    }

    // MARK: - 录制

    func capture(seconds: Double, completion: @escaping (Result<URL, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.movieOutput.isRecording else {
                DispatchQueue.main.async { completion(.failure(CameraError.busy)) }
                return
            }
            guard self.configureIfNeeded() else {
                DispatchQueue.main.async { completion(.failure(CameraError.notRunning)) }
                return
            }
            // 会话可能因为来电/切后台被系统停掉，这里先兜底拉起再录
            if !self.session.isRunning { self.session.startRunning() }
            guard self.session.isRunning,
                  self.movieOutput.connection(with: .video) != nil else {
                DispatchQueue.main.async { completion(.failure(CameraError.notRunning)) }
                return
            }
            Diagnostics.mark("camera.record")

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dtc-cam-\(UUID().uuidString).mov")
            self.onFinish = completion
            DispatchQueue.main.async { self.isRecording = true }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)

            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, self.movieOutput.isRecording else { return }
                Diagnostics.mark("camera.stop-request")
                self.movieOutput.stopRecording()
            }
        }
    }

    // MARK: - 录制回调

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        Diagnostics.mark("camera.recorded")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRecording = false
            let result: Result<URL, Error>
            if let error {
                result = .failure(error)
            } else {
                result = .success(outputFileURL)
            }
            self.onFinish?(result)
            self.onFinish = nil
        }
    }
}
