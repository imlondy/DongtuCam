import Foundation

/// 极简「面包屑 + 崩溃现场」记录。
///
/// 侧载 App 拿 .ips 太折腾，这里换个思路：每走一步就把当前步骤写进 UserDefaults，
/// 下次启动时如果发现上一条面包屑没被正常收尾，就说明上次是中途崩了/被系统杀了，
/// 直接把「崩在哪一步」显示在界面上的错误卡片里，截个图就能定位。
///
/// 两类现场都能抓：
/// - ObjC 异常（之前的 AVAssetReader 崩溃就属于这类）→ 记下 name / reason / 栈顶几行；
/// - 信号类崩溃或内存被杀（Swift fatalError、SIGSEGV、前台 jetsam）→ 由面包屑定位。
enum Diagnostics {
    private static let crumbKey = "dtc.diag.crumb"
    private static let crashKey = "dtc.diag.crash"

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 记录「正在做哪一步」
    static func mark(_ step: String) {
        let text = "\(step) @\(formatter.string(from: Date()))"
        UserDefaults.standard.set(text, forKey: crumbKey)
    }

    /// 链路正常收尾（成功或已把错误显示给用户）时清掉面包屑，
    /// 这样「还有面包屑」就等于「上次没跑完」。
    static func clear() {
        UserDefaults.standard.removeObject(forKey: crumbKey)
    }

    static func installCrashHandler() {
        // 必须传「不捕获上下文」的全局函数，闭包里引用类型成员编译器会拒绝
        NSSetUncaughtExceptionHandler(dtcHandleException)
    }

    /// 启动时取上次遗留的现场；取完即清，避免重复提示
    static func takeLastIncident() -> String? {
        var parts: [String] = []
        if let crash = UserDefaults.standard.string(forKey: crashKey), !crash.isEmpty {
            parts.append("上次异常\n" + crash)
            UserDefaults.standard.removeObject(forKey: crashKey)
        }
        if let crumb = UserDefaults.standard.string(forKey: crumbKey), !crumb.isEmpty {
            parts.append("上次中断在 " + crumb)
            UserDefaults.standard.removeObject(forKey: crumbKey)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// 供全局函数写入用
    fileprivate static func record(Exception exception: NSException) {
        let name = exception.name.rawValue
        let reason = exception.reason ?? "(无原因)"
        let stack = exception.callStackSymbols.prefix(6).joined(separator: "\n")
        let text = "\(name)：\(reason)\n\(stack)"
        UserDefaults.standard.set(text, forKey: crashKey)
        UserDefaults.standard.synchronize()
    }
}

/// ObjC 异常处理器：必须是全局函数（C 函数指针），不能是捕获上下文的闭包
private func dtcHandleException(_ exception: NSException) {
    Diagnostics.record(Exception: exception)
}
