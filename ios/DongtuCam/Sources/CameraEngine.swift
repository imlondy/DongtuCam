import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox
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

    /// 保留设备引用，美化调节与变焦都要用它
    private var videoDevice: AVCaptureDevice?
    /// 供「自动识别商品」用的低开销取帧通道
    private let frameOutput = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "dtc.camera.frames")
    private var lastSampleAt: CFTimeInterval = 0
    /// 录制中不送帧：识别没必要时时跑，也别和录制抢 CPU
    private var samplingEnabled = true

    /// 送帧回调（主线程）
    var onFrame: ((CGImage) -> Void)?
    /// 采样间隔：2.5 秒一帧足够"举起商品就认出来"，又不会把 CPU 和 AI 额度烧穿
    var sampleInterval: CFTimeInterval = 2.5

    @Published private(set) var isRecording = false

    // MARK: 美化参数（全部是相机原生能力，预览实时可见、录制时直接固化进成片）

    /// 曝光补偿，单位 EV
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var exposureRange: ClosedRange<Float> = -2...2
    /// 变焦倍数
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var maxZoom: CGFloat = 4
    /// 色温（K），3500 冷 ← 5000 标准 → 7500 暖
    @Published private(set) var kelvin: CGFloat = 5000
    /// 是否还在自动白平衡
    @Published private(set) var autoWhiteBalance = true

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
        videoDevice = device
        // 曝光补偿的可调范围跟着设备走（iPhone 一般 ±2 EV，个别格式 ±8）
        let low = max(-2, device.minExposureTargetBias)
        let high = min(2, device.maxExposureTargetBias)
        if low < high {
            DispatchQueue.main.async { self.exposureRange = low...high }
        }
        DispatchQueue.main.async { self.maxZoom = min(device.maxAvailableVideoZoomFactor, 6) }
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

        // 取帧通道：给「举起商品 → 自动识别 → 自动匹配文案」用。
        //
        // v11 曾因为「4K 会话上再挂一路 data output + 每帧转 CGImage」把内存顶穿而闪退。
        // 这一版的区别：格式已限制在 1600 以下、**节流到 2.5 秒一帧**、
        // 只在需要识别时才把帧送出去（onFrame 为 nil 时立刻 return），
        // 所以它每秒的实际工作量约等于一次缩略图解码。
        frameOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        frameOutput.alwaysDiscardsLateVideoFrames = true
        frameOutput.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(frameOutput) {
            session.addOutput(frameOutput)
            // 竖的正立帧：Vision 的文字识别对旋转 90° 的画面基本失效
            if let connection = frameOutput.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    connection.videoRotationAngle = 90
                } else if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }
            Diagnostics.mark("camera.frame-output-ok")
        } else {
            Diagnostics.mark("camera.frame-output-skip")
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
        /// 8bit 的两种（420v / 420f）；`x420` 是 10bit HDR，静帧是 SDR，
        /// 混着来容易出现「视频 HDR、照片 SDR」的色偏，所以优先 8bit。
        let eightBitSubTypes: Set<FourCharCode> = [0x34323076, 0x34323066]

        func dimension(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        }
        func subType(_ format: AVCaptureDevice.Format) -> FourCharCode {
            CMFormatDescriptionGetMediaSubType(format.formatDescription)
        }
        func isVideo(_ format: AVCaptureDevice.Format) -> Bool {
            videoSubTypes.contains(subType(format))
        }
        func area(_ format: AVCaptureDevice.Format) -> Int {
            let d = dimension(format)
            return Int(d.width) * Int(d.height)
        }
        func minSide(_ format: AVCaptureDevice.Format) -> Int {
            let d = dimension(format)
            return min(Int(d.width), Int(d.height))
        }

        let allVideoFormats = device.formats.filter(isVideo)
        guard !allVideoFormats.isEmpty else { return }
        let eightBitFormats = allVideoFormats.filter { eightBitSubTypes.contains(subType($0)) }
        let videoFormats = eightBitFormats.isEmpty ? allVideoFormats : eightBitFormats

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

    // MARK: - 美化调节
    //
    // 三项都走相机原生能力，而不是拍完再后期修图。好处是：
    //   1. 预览里**实时**能看到效果，所见即所得；
    //   2. 照片（静帧）和视频（动图）拿到的是同一份已经调好的画面，
    //      不会出现「封面和动图颜色不一致」这种穿帮；
    //   3. 零额外内存、零额外编码，不给已经很脆的保存链路添风险。

    /// 亮度 = 曝光补偿（EV）。范围跟设备走，一般是 ±2。
    func setExposureBias(_ value: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            let clamped = max(device.minExposureTargetBias,
                              min(device.maxExposureTargetBias, value))
            device.setExposureTargetBias(clamped)
            DispatchQueue.main.async { self.exposureBias = clamped }
        }
    }

    /// 变焦。上限取设备能力与 6 倍的较小值（再高就只是糊的数码放大）。
    func setZoom(_ value: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            let ceiling = min(device.maxAvailableVideoZoomFactor, 6)
            let clamped = max(1, min(ceiling, value))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = clamped }
            } catch {
                Diagnostics.mark("camera.zoom-failed")
            }
        }
    }

    /// 色温 = 锁定白平衡。数值越小越冷（偏蓝），越大越暖（偏黄）。
    func setKelvin(_ value: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            guard device.isWhiteBalanceModeSupported(.locked) else { return }
            let clamped = max(3000, min(8000, value))
            do {
                try device.lockForConfiguration()
                let target = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: Float(clamped), tint: 0)
                let gains = device.deviceWhiteBalanceGains(for: target)
                let ceiling = device.maxWhiteBalanceGain
                func safe(_ v: Float) -> Float { max(1, min(ceiling, v)) }
                device.setWhiteBalanceModeLocked(
                    with: AVCaptureDevice.WhiteBalanceGains(redGain: safe(gains.redGain),
                                                            greenGain: safe(gains.greenGain),
                                                            blueGain: safe(gains.blueGain)))
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.kelvin = clamped
                    self.autoWhiteBalance = false
                }
            } catch {
                Diagnostics.mark("camera.wb-failed")
            }
        }
    }

    /// 交还给系统的自动白平衡（换了光线环境后一键找回正常色彩）
    func resetWhiteBalance() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            guard device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else { return }
            do {
                try device.lockForConfiguration()
                device.whiteBalanceMode = .continuousAutoWhiteBalance
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.autoWhiteBalance = true
                    self.kelvin = 5000
                }
            } catch {
                Diagnostics.mark("camera.wb-reset-failed")
            }
        }
    }

    /// 一键还原（亮度 0 / 变焦 1x / 自动白平衡）
    func resetAdjustments() {
        setExposureBias(0)
        setZoom(1)
        resetWhiteBalance()
    }

    // MARK: - 取帧（自动识别商品）

    /// 打开/关闭送帧。录制期间关掉，避免和录制抢 CPU。
    func setSamplingEnabled(_ enabled: Bool) {
        samplingEnabled = enabled
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
            // 录制期间停掉识别取帧：两边同时吃 CPU 只会让录制更容易掉帧
            self.samplingEnabled = false
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
        samplingEnabled = true
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

// MARK: - 实时取帧（自动识别商品）

/// 单独一个 extension：取帧和录制是两套互不相干的委托，
/// 混在一个类型里最容易在后续改动中互相误伤。
extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // 三重闸门，全在送帧之前挡掉，保证这个回调平时几乎不花时间：
        //  1. 没人在等帧（没开自动识别）→ 立刻返回
        //  2. 正在录制 → 返回
        //  3. 距上一帧不到 sampleInterval → 返回
        guard output === frameOutput,
              samplingEnabled,
              onFrame != nil else { return }
        let now = CACurrentMediaTime()
        guard now - lastSampleAt >= sampleInterval else { return }
        lastSampleAt = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // VideoToolbox 的零拷贝取图：直接拿到 CGImage，不建 CIImage、不进 GPU
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard let image else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(image)
        }
    }
}
