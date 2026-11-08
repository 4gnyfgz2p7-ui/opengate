import Foundation

/// 转码过程的落盘日志。
///
/// 转码失败时，界面上只会看到一个 0 字节文件和一句简短提示。具体原因
/// ——解码器不认 bp16、reader 拒收轨道、编码器拒帧、尺寸不匹配——
/// 拿不到，等于靠猜。这里把每一步都写进 `Documents/Recordings/transcode.log`，
/// 用「文件」App 直接取出来就能定位。
enum TranscodeLog {

    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static var fileURL: URL {
        MovieRecorder.recordingDirectory().appendingPathComponent("transcode.log")
    }

    /// 追加一行。失败时不抛错——日志本身不该拖垮转码。
    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// 每次转码开始清空，避免日志无限增长。
    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
