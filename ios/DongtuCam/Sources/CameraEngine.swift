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
    private var configured = false

    /// 跨线程共享的标记位与回调统一用一把锁保护。
    ///
    /// Swift 的闭包是「函数指针 + 上下文指针」两个字宽，主线程写、相机队列读
    /// 如果不加锁，有概率读到撕裂的值。这类崩溃位置随机、极难复现，
    /// 必须在写的时候就堵住，而不是等它出现在现场日志里。
    private let stateLock = NSLock()
    private var finishHandler: ((Result<URL, Error>) -> Void)?
    private var onFinish: ((Result<URL, Error>) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return finishHandler
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            finishHandler = newValue
        }
    }
    /// 录制中不送帧：识别没必要时时跑，也别和录制抢 CPU
    private var samplingFlag = true
    private var samplingEnabled: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return samplingFlag
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            samplingFlag = newValue
        }
    }

    /// 保留设备引用，美化调节与变焦都要用它
    private var videoDevice: AVCaptureDevice?
    /// 供「自动识别商品」用的低开销取帧通道
    private let frameOutput = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "dtc.camera.frames")
    private var lastSampleAt: CFTimeInterval = 0

    /// 送帧回调（主线程调用）。
    ///
    /// **必须加锁**：Swift 的闭包是「函数指针 + 上下文指针」两个字，
    /// 主线程赋值、取帧队列读取如果不加锁，就有概率读到撕裂的值 ——
    /// 崩起来是「偶发、位置随机」，正是本项目最难查的那类崩溃。
    private let frameLock = NSLock()
    private var frameHandler: ((CGImage) -> Void)?

    var onFrame: ((CGImage) -> Void)? {
        get {
            frameLock.lock()
            defer { frameLock.unlock() }
            return frameHandler
        }
        set {
            frameLock.lock()
            defer { frameLock.unlock() }
            frameHandler = newValue
        }
    }
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

    /// 滑杆拖动每秒会产生上百次回调。如果每次都直接排队下发，
    /// 就是上百次 `lockForConfiguration` —— 又慢又容易和录制/切换格式撞车。
    /// 这三个「只保留最新值」的槽位把一次拖动压缩成几次实际应用，手感也更顺。
    private let exposureQueue = LatestValue<Float>()
    private let zoomQueue = LatestValue<CGFloat>()
    private let kelvinQueue = LatestValue<CGFloat>()

    /// 三项调节的唯一出口。
    ///
    /// v23 的崩溃就出在这里：亮度直接调了 `setExposureTargetBias` 而没先锁定设备，
    /// AVFoundation 抛出 ObjC 异常 ——
    /// `May not be called without first successfully gaining exclusive ownership
    /// of the device using -lockForConfiguration:` —— 这种异常 Swift 的 `try` 抓不到，
    /// 进程当场被信号带走。现在所有设备参数修改都必须经过这里。
    ///
    /// 另外，`unlockForConfiguration` 放在 `defer` 里：一旦漏了解锁，
    /// 设备会被永久占住，之后所有调节都静默失败 —— 比崩溃更难查。
    @discardableResult
    private func withDeviceConfig(_ tag: String, _ body: (AVCaptureDevice) throws -> Void) -> Bool {
        guard let device = videoDevice else {
            Diagnostics.mark("camera.\(tag)-nodevice")
            return false
        }
        do {
            try device.lockForConfiguration()
        } catch {
            // 正常不会走到：sessionQueue 是串行的，且所有写入都经由它。
            Diagnostics.mark("camera.\(tag)-lockfail")
            return false
        }
        defer { device.unlockForConfiguration() }
        do {
            try body(device)
            return true
        } catch {
            Diagnostics.mark("camera.\(tag)-failed")
            return false
        }
    }

    /// 亮度 = 曝光补偿（EV）。范围跟设备走，一般是 ±2。
    func setExposureBias(_ value: Float) {
        let clamped = max(exposureRange.lowerBound, min(exposureRange.upperBound, value))
        // 先乐观更新，滑杆才跟手；真正是否生效由相机队列确认
        publish { self.exposureBias = clamped }
        if exposureQueue.push(clamped) {
            drainExposure()
        }
    }

    private func drainExposure() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let next = self.exposureQueue.drain()
            if let value = next { self.applyExposure(value) }
            // 应用期间可能又来了新值，继续下一轮；没新值就自然收尾
            if !self.exposureQueue.isIdle { self.drainExposure() }
        }
    }

    private func applyExposure(_ value: Float) {
        guard let device = videoDevice else { return }
        let clamped = max(device.minExposureTargetBias,
                          min(device.maxExposureTargetBias, value))
        let applied = withDeviceConfig("exposure") { dev in
            dev.setExposureTargetBias(clamped)
        }
        guard applied else { return }
        publish { if self.exposureBias != clamped { self.exposureBias = clamped } }
    }

    /// 变焦。上限取设备能力与 6 倍的较小值（再高就只是糊的数码放大）。
    func setZoom(_ value: CGFloat) {
        publish { self.zoomFactor = value }
        if zoomQueue.push(value) {
            drainZoom()
        }
    }

    private func drainZoom() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let next = self.zoomQueue.drain()
            if let value = next { self.applyZoom(value) }
            if !self.zoomQueue.isIdle { self.drainZoom() }
        }
    }

    private func applyZoom(_ value: CGFloat) {
        guard let device = videoDevice else { return }
        let ceiling = max(1, min(device.maxAvailableVideoZoomFactor, 6))
        let clamped = max(1, min(ceiling, value))
        let applied = withDeviceConfig("zoom") { dev in
            dev.videoZoomFactor = clamped
        }
        guard applied else { return }
        publish { if self.zoomFactor != clamped { self.zoomFactor = clamped } }
    }

    /// 色温 = 锁定白平衡。数值越小越冷（偏蓝），越大越暖（偏黄）。
    func setKelvin(_ value: CGFloat) {
        let clamped = max(3000, min(8000, value))
        publish {
            self.kelvin = clamped
            self.autoWhiteBalance = false
        }
        if kelvinQueue.push(clamped) {
            drainKelvin()
        }
    }

    private func drainKelvin() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let next = self.kelvinQueue.drain()
            if let value = next { self.applyKelvin(value) }
            if !self.kelvinQueue.isIdle { self.drainKelvin() }
        }
    }

    private func applyKelvin(_ value: CGFloat) {
        guard let device = videoDevice else { return }
        guard device.isWhiteBalanceModeSupported(.locked) else {
            Diagnostics.mark("camera.wb-unsupported")
            return
        }
        let applied = withDeviceConfig("wb") { dev in
            let target = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: Float(value), tint: 0)
            let gains = dev.deviceWhiteBalanceGains(for: target)
            let ceiling = dev.maxWhiteBalanceGain
            func safe(_ v: Float) -> Float { max(1, min(ceiling, v)) }
            dev.setWhiteBalanceModeLocked(
                with: AVCaptureDevice.WhiteBalanceGains(redGain: safe(gains.redGain),
                                                        greenGain: safe(gains.greenGain),
                                                        blueGain: safe(gains.blueGain)))
        }
        guard applied else { return }
        publish {
            if self.kelvin != value { self.kelvin = value }
            self.autoWhiteBalance = false
        }
    }

    /// 交还给系统的自动白平衡（换了光线环境后一键找回正常色彩）
    func resetWhiteBalance() {
        // 丢掉还在排队的色温目标，否则它会在这次重置之后又锁回去
        kelvinQueue.clear()
        publish {
            self.autoWhiteBalance = true
            self.kelvin = 5000
        }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            guard device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else { return }
            let applied = self.withDeviceConfig("wb-reset") { dev in
                dev.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            guard applied else { return }
            Diagnostics.mark("camera.wb-reset-ok")
        }
    }

    /// 一键还原（亮度 0 / 变焦 1x / 自动白平衡）
    func resetAdjustments() {
        setExposureBias(0)
        setZoom(1)
        resetWhiteBalance()
    }

    /// `@Published` 只在主线程写。调节入口都在主线程，但这里再兜一层，
    /// 以后误从后台线程调用也不会触发「Publishing changes from background threads」。
    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
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
            // 先取一次副本再清空：直接 `onFinish?(x)` 后紧接着置 nil，
            // 中间若被别的线程写入，那次写入会被这里清掉
            let handler = self.onFinish
            self.onFinish = nil
            handler?(result)
        }
    }
}

/// 「只保留最新值」的单槽位。
///
/// 给滑杆这类高频输入用：拖动时每秒上百个值，真正需要落到设备上的只有最后一个。
/// - `push`：存入最新值；返回 true 表示此刻没人在处理，调用方需要启动一次 drain。
/// - `drain`：取走当前值（空则返回 nil）。取过之后 `isIdle` 仍为 false，
///   直到确认真的没有新值 —— 这样「应用期间新来的值」不会被悄悄丢掉。
/// - `isIdle`：true 表示既没有待处理值，也没有正在进行的一轮，可以收尾。
/// - `clear`：丢弃待处理值（重置白平衡时防止旧目标又锁回去）。
private final class LatestValue<T> {
    private let lock = NSLock()
    private var pending: T?
    private var hasPending = false
    private var busy = false

    func push(_ value: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending = value
        hasPending = true
        guard !busy else { return false }
        busy = true
        return true
    }

    func drain() -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard hasPending else { return nil }
        let value = pending
        pending = nil
        hasPending = false
        return value
    }

    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        if !hasPending { busy = false }
        return !busy
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        pending = nil
        hasPending = false
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
              samplingEnabled else { return }
        // 闭包只读一次（锁内），后面用这个局部变量，避免读到撕裂值
        guard let handler = onFrame else { return }
        let now = CACurrentMediaTime()
        guard now - lastSampleAt >= sampleInterval else { return }
        lastSampleAt = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // VideoToolbox 的零拷贝取图：直接拿到 CGImage，不建 CIImage、不进 GPU
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard let image else { return }
        DispatchQueue.main.async {
            handler(image)
        }
    }
}
