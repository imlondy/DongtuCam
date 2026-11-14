import Foundation
import Darwin

/// 崩溃现场记录：**直接写文件、立即落盘**，不依赖 UserDefaults。
///
/// 为什么推翻上一版：`UserDefaults.set` 只写内存，落盘是异步的。
/// 进程被信号打死、或被系统因内存杀掉时，最近几步全部丢失，
/// 界面上就会显示一个早已过期的步骤（实际踩到过：崩在烧字，
/// 却显示「上次中断在 camera.configured」，据此连改两轮都没改对）。
///
/// 现在改成 open + write：write 直接进内核页缓存，进程一死也能读到。
/// 同时装了信号处理器，SIGSEGV / SIGABRT 这类崩溃也会把栈写进同一个文件。
enum Diagnostics {
    private static let stepPath: String = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("dtc-steps.log").path
    }()

    private static var fd: Int32 = -1
    private static let lock = NSLock()
    /// 上一次运行留下的现场，启动时取走并清空
    private static var pendingIncident: String?

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - 启动

    static func installCrashHandler() {
        ensureOpen()
        // 先把上一轮的历史读出来，再清空，避免本轮的步骤混进「上次现场」
        pendingIncident = readTail()
        if fd >= 0 { _ = ftruncate(fd, 0) }

        NSSetUncaughtExceptionHandler(dtcHandleException)
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, dtcSignalHandler)
        }
        mark("app.launch")
    }

    /// 启动时取上次遗留的现场；取完即清，避免重复提示
    static func takeLastIncident() -> String? {
        defer { pendingIncident = nil }
        guard let text = pendingIncident, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - 面包屑

    /// 记录「正在做哪一步」，立即落盘。
    /// 格式化也放在锁内：mark 会被相机回调线程和主线程同时调用。
    static func mark(_ step: String) {
        lock.lock()
        defer { lock.unlock() }
        if fd < 0 { fd = open(stepPath, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        guard fd >= 0 else { return }
        let text = "\(formatter.string(from: Date()))  \(step)\n"
        guard let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.write(fd, base, buffer.count)
        }
    }

    /// 面包屑顺带记一笔内存占用（MB）。
    ///
    /// iOS 对前台 App 的内存有硬上限，超了就是 SIGKILL —— 装不上任何处理器，
    /// 现场只会「突然停在某一行」。v19 那次日志尾部没有 "!!" 就是这种情况，
    /// 但光看行号分不清是「内存被杀」还是「用户自己退出」。
    /// 带上内存曲线之后，一眼就能看出是不是在峰值被带走的。
    static func markMem(_ step: String) {
        mark("\(step) mem=\(Int(footprintMB))")
    }

    /// 当前进程实际占用（phys_footprint），取不到返回 0
    static var footprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024.0 / 1024.0
    }

    /// 链路正常收尾（成功或已把错误显示给用户）时清空，
    /// 这样「文件里还有内容」就等于「上次没跑完」。
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        if fd < 0 { fd = open(stepPath, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        if fd >= 0 { _ = ftruncate(fd, 0) }
    }

    // MARK: - 内部

    private static func ensureOpen() {
        lock.lock()
        defer { lock.unlock() }
        if fd < 0 { fd = open(stepPath, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
    }

    /// 读最后 60 行。
    ///
    /// 曾经只读 14 行，结果关键一轮的现场被「启动+恢复」的 9 条面包屑顶出了窗口，
    /// 崩溃点两侧全空白，白白多排查一轮。改 40 行后能覆盖一次完整的
    /// 「启动 → 恢复 → 拍摄 → 处理」，v20 起每步带了内存读数，再放宽到 60。
    private static func readTail() -> String? {
        guard let text = try? String(contentsOfFile: stepPath, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        var tail = Array(lines.suffix(60))
        // 有 "!!" 才是真崩（信号 / ObjC 异常）。
        if tail.contains(where: { $0.contains("!!") }) {
            return tail.joined(separator: "\n")
        }
        // 尾部是「切后台/退出」标记：说明上次是正常结束，不是闪退。
        // 以前这种情况也会弹「上次现场」，反而盖住了真正的崩溃 —— 直接忽略。
        if tail.contains(where: { $0.contains("app.background") }) { return nil }
        // 没有异常、也没正常退出：进程是被系统直接杀掉的（jetsam 内存 / 看门狗）。
        tail.append("（无异常记录：进程被系统结束，多为内存不足 —— 看 mem= 是否很高）")
        return tail.joined(separator: "\n")
    }

    /// 供崩溃处理器写入（不取锁：崩溃时可能正持有锁）
    fileprivate static func writeFatal(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if fd < 0 { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.write(fd, base, buffer.count)
        }
    }

    fileprivate static func record(Exception exception: NSException) {
        let name = exception.name.rawValue
        let reason = exception.reason ?? "(无原因)"
        let stack = exception.callStackSymbols.prefix(8).joined(separator: "\n")
        writeFatal("\n!! ObjC 异常 \(name)\n   \(reason)\n\(stack)\n")
    }

    fileprivate static func record(signal sig: Int32) {
        // 信号处理里只写「哪个信号」：面包屑已经在文件里逐条落盘了，
        // 靠它就能定位到崩在哪一步。这里刻意不调 Swift/ObjC 运行时
        // （Thread.callStackSymbols 会分配内存，持锁时可能死锁）。
        writeFatal("\n!! 信号崩溃 signal=\(sig)\n")
    }
}

// MARK: - C 函数指针（不能捕获上下文，所以必须是全局函数）

private func dtcHandleException(_ exception: NSException) {
    Diagnostics.record(Exception: exception)
}

private func dtcSignalHandler(_ sig: Int32) {
    Diagnostics.record(signal: sig)
    // 恢复默认处理并重新抛出，保持系统原本的崩溃行为（.ips 仍会生成）
    signal(sig, SIG_DFL)
    raise(sig)
}
