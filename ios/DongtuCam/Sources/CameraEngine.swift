import AVFoundation
import CoreGraphics
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
/// 历史教训（别再踩）：v11 曾在同一会话上再挂一路 `AVCaptureVideoDataOutput` 抓帧，
/// 用于「按下快门立刻识别商品」。结果是：
/// 1) 录制输出 + 数据输出同时挂在 2880x3840 的会话上，`startRecording` 容易抛 ObjC 异常；
/// 2) 4K 缓冲池 + 每帧转 CGImage 让内存成倍上升，在手机上很容易被系统直接杀掉（表现为闪退）。
/// 所以现在**只保留一路录制输出**，识别改为从成片首帧做（见 BurnEngine.previewFrame），
/// 画面内容完全一样，只是晚 5 秒，换取稳定。
final class CameraEngine: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "dtc.camera.session")
    private var onFinish: ((Result<URL, Error>) -> Void)?

    @Published private(set) var isRecording = false

    override init() {
        super.init()
        Diagnostics.mark("camera.init")
        configure()
    }

    private func configure() {
        session.beginConfiguration()
        // 让 activeFormat 决定分辨率，而不是被 sessionPreset 覆盖
        session.sessionPreset = .inputPriority

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                for: .video, position: .back) {
            Self.selectThreeFourFormat(on: device)
            if let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        // 不强制设置 videoOrientation：由 AVAsset 的 preferredTransform
        // 在导出阶段自动转正，避免 deprecated API 与横竖屏错乱。
        session.commitConfiguration()
        Diagnostics.mark("camera.configured")
    }

    /// 直接在相机层选 3:4 的视频格式（竖屏 3:4 / 横屏 4:3 旋转后也是 3:4），
    /// 这样成片 100% 来自原片、无需任何裁切或人工延伸区。
    /// 机型不支持时自动退回系统默认格式，仍可正常出片。
    private static func selectThreeFourFormat(on device: AVCaptureDevice) {
        let portrait: CGFloat = 3.0 / 4.0
        let landscape: CGFloat = 4.0 / 3.0
        let candidates = device.formats.filter { format in
            let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimension.height > 0 else { return false }
            let ratio = CGFloat(dimension.width) / CGFloat(dimension.height)
            return abs(ratio - portrait) < 0.02 || abs(ratio - landscape) < 0.02
        }
        // 4K 级画面对手机内存压力大，优先挑 1080~1600 级里最大的那个：
        // 抖音动图最终也是这个量级，清楚够用，且不会把内存顶到红线。
        let preferred = candidates.filter { format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return min(Int(d.width), Int(d.height)) <= 1600
        }
        let pool = preferred.isEmpty ? candidates : preferred
        guard let best = pool.max(by: { a, b in
            let lhs = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let rhs = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(lhs.width) * Int(lhs.height) < Int(rhs.width) * Int(rhs.height)
        }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.unlockForConfiguration()
        } catch {
            // 降级：使用系统默认格式
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
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

    func capture(seconds: Double, completion: @escaping (Result<URL, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.movieOutput.isRecording else {
                DispatchQueue.main.async { completion(.failure(CameraError.busy)) }
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
                self.movieOutput.stopRecording()
            }
        }
    }

    // MARK: - 录制回调

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRecording = false
            Diagnostics.mark("camera.recorded")
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
