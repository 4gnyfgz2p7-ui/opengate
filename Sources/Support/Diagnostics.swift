import Foundation

/// 现场诊断：崩溃原因 + 最后进度落盘。
///
/// 存在的理由很具体——探针闪退时，不要在手机上翻「设置 → 分析数据」找 .ips，
/// 也不用连电脑。App 自己在崩溃前把异常原因和最后一步写进 Documents，
/// 重新打开就能在探针页看到，直接分享出来即可定位。
///
/// 覆盖面：只能抓 Objective-C 异常（AVFoundation 抛的正是这类）。
/// Swift 的 fatalError / 系统 watchdog 不走这里，但那些会在系统里留 .ips。
enum Diagnostics {

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var progressURL: URL { documents.appendingPathComponent("probe-progress.txt") }
    static var crashURL: URL { documents.appendingPathComponent("last-crash.txt") }

    /// 在 App 启动最早期安装。闭包是 C 函数指针，不能捕获上下文，
    /// 因此内部只引用静态属性。
    static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let body = """
            时间: \(ISO8601DateFormatter().string(from: Date()))
            名称: \(exception.name.rawValue)
            原因: \(exception.reason ?? "无")
            --- 调用栈 ---
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            // 必须同步写完，紧接着进程就会终止
            if let data = body.data(using: .utf8) {
                try? data.write(to: Diagnostics.crashURL, options: .atomic)
            }
        }
    }

    /// 每次探测开始时重置进度文件
    static func beginProgress(_ title: String) {
        let line = "=== \(title) · \(stamp()) ===\n"
        try? line.write(to: progressURL, atomically: true, encoding: .utf8)
    }

    /// 追加一行并立即下发到内核。刻意不开缓冲：
    /// 崩溃时进程不会再有机会 flush，写晚一步就什么都没了。
    static func mark(_ message: String) {
        let line = "[\(stamp())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: progressURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            fsync(handle.fileDescriptor)
            try? handle.close()
        } else {
            try? data.write(to: progressURL, options: .atomic)
        }
    }

    static func readProgress() -> String? {
        guard let text = try? String(contentsOf: progressURL, encoding: .utf8) else { return nil }
        return text.isEmpty ? nil : text
    }

    static func readCrash() -> String? {
        guard let text = try? String(contentsOf: crashURL, encoding: .utf8) else { return nil }
        return text.isEmpty ? nil : text
    }

    static func clear() {
        try? FileManager.default.removeItem(at: progressURL)
        try? FileManager.default.removeItem(at: crashURL)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
