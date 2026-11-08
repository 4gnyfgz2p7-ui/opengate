import Foundation
import SwiftUI

/// 离线处理一个本地文件：选 ProRes RAW → 官方解码 → 已验证色彩管线 → HEVC。
///
/// ## 为什么需要它
///
/// 录制链路每调一次参数就要重录一次，同一场景无法反复比对，收敛极慢，
/// 而且每次都要重新对一次构图和光线。这里把输入固定成一个文件：
/// 改一版、处理一版，差异才可比。
///
/// 走的是和录制后中转完全相同的代码路径（`RawTranscoder`），所以这里
/// 能出什么结果，录制链路就能出什么结果，不存在两套行为。
@MainActor
final class FileProcessor: ObservableObject {

    @Published private(set) var busy = false
    @Published private(set) var status = "尚未选择文件"
    @Published private(set) var output: URL?
    /// 转码日志（最近若干行）。转码每一步都写进 transcode.log，
    /// 这里直接读出来显示，不必再去「文件」App 里拷。
    @Published private(set) var logLines: [String] = []
    /// 上次异常终止的现场。选完文件就闪退时，重开 App 进设置直接能看到
    /// 异常名与原因，不必去翻「设置 → 隐私与安全性 → 分析数据」。
    @Published private(set) var lastCrash: String?

    init() {
        lastCrash = Self.shortCrash()
    }

    private static func shortCrash() -> String? {
        guard let raw = Diagnostics.readCrash() else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        // 名称、原因两行足够定位；完整调用栈留在 last-crash.txt 里
        let head = lines.prefix(4).joined(separator: "\n")
        return head.count > 400 ? String(head.prefix(400)) + "…" : head
    }

    func dismissCrash() {
        lastCrash = nil
        try? FileManager.default.removeItem(at: Diagnostics.crashURL)
    }

    /// 输出固定用 HEVC 长 GOP：文件小、编码快，便于快速比对。
    private let tier: QualityTier = .hevcLongGOP

    /// 处理期间轮询日志文件。转码是同步阻塞的一段流程，回调只报进度，
    /// 真正的失败原因写在日志里，所以按固定间隔读。
    /// `nonisolated(unsafe)` 只为能在 deinit 里 invalidate：
    /// Timer 只在主线程被创建和失效，不存在并发写。
    nonisolated(unsafe) private var logTimer: Timer?

    deinit {
        logTimer?.invalidate()
    }

    private func startLogPolling() {
        logTimer?.invalidate()
        refreshLog()
        logTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLog() }
        }
    }

    private func stopLogPolling() {
        logTimer?.invalidate()
        logTimer = nil
        refreshLog()
    }

    func refreshLog() {
        let lines = TranscodeLog.recentLines(18)
        if lines != logLines { logLines = lines }
    }

    /// 选择器本身失败（权限、文件被移除等），不进入处理流程
    func reportPickerFailure(_ error: Error) {
        busy = false
        status = "选择文件失败：\(error.localizedDescription)"
    }

    func process(_ url: URL) {
        guard !busy else { return }
        busy = true
        output = nil
        status = "正在处理 \(url.lastPathComponent)…"
        TranscodeLog.reset()
        TranscodeLog.write("=== 开始处理 \(url.lastPathComponent) ===")
        Diagnostics.beginProgress("离线转码 \(url.lastPathComponent)")
        startLogPolling()

        let tier = self.tier

        Task.detached(priority: .userInitiated) { [weak self] in
            // 「文件」App 给出的 URL 是安全作用域资源，必须显式开合。
            // 不开启的话 AVURLAsset 打开会失败，报「文件里没有视频轨」。
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            // 输出放到录制目录，名字沿用源命名规则并加 _Log2 后缀，
            // 与 PC 端工具的产物命名保持一致，一眼能对上。
            let base = MovieRecorder.makeOutputURL(tier: tier)
            let target = base.deletingPathExtension()
                .deletingLastPathComponent()
                .appendingPathComponent(base.deletingPathExtension().lastPathComponent + "_Log2")
                .appendingPathExtension("mov")

            do {
                // 同步阻塞：解码、套曲线、编码、写标记全在这一个线程里完成。
                // 早先用回调并行驱动，音视频两个队列抢同一个计数器，
                // 会踩 Swift 独占访问检查而闪退。
                let result = try Log2Transcoder.run(
                    rawURL: url,
                    outputURL: target,
                    applyCurve: true,
                    bitRate: 45_000_000
                ) { line in
                    TranscodeLog.write(line)
                    // 崩溃时日志文件不一定来得及落盘，这里同步 fsync 一份
                    Diagnostics.mark(line)
                }
                let size = MovieRecorder.fileSize(at: target)
                await MainActor.run {
                    guard let self else { return }
                    self.busy = false
                    self.output = target
                    self.status = String(
                        format: "完成：%d 帧 · %.1f 秒 · %.1f MB\n%@",
                        result.frames, result.elapsed,
                        Double(size) / 1_000_000, result.summary
                    )
                    self.stopLogPolling()
                    self.lastCrash = nil
                    try? FileManager.default.removeItem(at: Diagnostics.crashURL)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.busy = false
                    self.status = "失败：\(error.localizedDescription)"
                    TranscodeLog.write("失败：\(error.localizedDescription)")
                    self.stopLogPolling()
                }
            }
        }
    }
}
