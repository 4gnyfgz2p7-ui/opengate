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

    /// 输出固定用 HEVC 长 GOP：文件小、编码快，便于快速比对。
    private let tier: QualityTier = .hevcLongGOP

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

        let tier = self.tier

        Task.detached(priority: .userInitiated) { [weak self] in
            // 「文件」App 给出的 URL 是安全作用域资源，必须显式开合。
            // 不开启的话 AVURLAsset 打开会失败，报「文件里没有视频轨」。
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let target = MovieRecorder.makeOutputURL(tier: tier)
            do {
                let result = try RawTranscoder.run(
                    rawURL: url,
                    outputURL: target,
                    tier: tier,
                    metadata: [],
                    selfCalibrate: false
                )
                let size = MovieRecorder.fileSize(at: target)
                await MainActor.run {
                    guard let self else { return }
                    self.busy = false
                    self.output = target
                    self.status = String(
                        format: "完成：%d 帧 · %.1f 秒 · %.1f MB\n%@",
                        result.frames, result.elapsed,
                        Double(size) / 1_000_000, result.probe
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.busy = false
                    self.status = "失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
