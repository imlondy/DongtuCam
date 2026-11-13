import AVFoundation
import Foundation

/// 打开即相机：固定录 5 秒短视频。
/// 用「录视频」而不是系统 Live Photo 拍摄，是因为原生实况只有约 3 秒且不可控；
/// 5 秒视频 + 抽帧 still 再交给 PhotoKit 写回，时长、文案、版式全部可控。
final class CameraEngine: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "dtc.camera.session")
    private var onFinish: ((Result<URL, Error>) -> Void)?

    @Published private(set) var isRecording = false

    override init() {
        super.init()
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
        guard let best = candidates.max(by: { a, b in
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
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func capture(seconds: Double, completion: @escaping (Result<URL, Error>) -> Void) {
        guard !movieOutput.isRecording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dtc-cam-\(UUID().uuidString).mov")
        onFinish = completion
        DispatchQueue.main.async { self.isRecording = true }
        movieOutput.startRecording(to: url, recordingDelegate: self)

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
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
