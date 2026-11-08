import Foundation
import CoreVideo

/// 把设备真正交付的 btp2 原始字节原样落盘，只存最前面两帧。
///
/// 起因：本机自研的 btp2 解包与 Apple 官方 ProRes RAW 解码器给出的结果对不上。
/// 同一段素材（092529）里：
///   - 官方解码器解出的偶/奇像素比 = 1.106
///   - 本机 mode9 从设备字节算出来 = 0.762
///   - mode10 = 0.758，mode0（8px/12B）= 0.968
/// lin_curve 是一条单调曲线，只会压伸数值、不会把大小关系翻过来，所以这三种
/// 排法都不是设备实际用的那一种。
///
/// 这件事没法再靠统计判据猜——判据本身就在奖励「人为制造相关性」的排法
/// （mode9/10 让相邻像素共享低位字节，相邻差天然变小，于是被判据选中）。
/// 唯一的出路是把真字节存下来，在 PC 上把每种排法都跑一遍，看哪一种能还原
/// 出官方解码器的数字。
///
/// 落盘位置：App 沙盒 Documents/btp2dump，用「文件」App 或 Finder 直接取。
/// 文件名带尺寸和行字节数，方便核对 strides。
enum BayerDump {

    /// 两帧足够比对，又不会让开录瞬间卡太久（单帧 rowBytes×height ≈ 19 MB）。
    private static let limit = 2
    private static var count = 0
    private static let lock = NSLock()

    /// 在采集回调里调用。非 Bayer 帧、或已经存够帧数时直接返回。
    static func capture(_ buffer: CVPixelBuffer) {
        lock.lock()
        let index = count
        guard index < limit else {
            lock.unlock()
            return
        }
        count += 1
        lock.unlock()

        guard CVPixelBufferGetPixelFormatType(buffer) == BayerConverter.bayerFormat else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }

        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard rowBytes > 0, height > 0 else { return }
        let data = Data(bytes: base, count: rowBytes * height)

        let directory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("btp2dump", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = String(format: "f%02d_%dx%d_row%d_pf%08x.btp2",
                          index, width, height, rowBytes,
                          CVPixelBufferGetPixelFormatType(buffer))
        try? data.write(to: directory.appendingPathComponent(name))
    }

    /// 供诊断串使用：已经落盘几帧。
    static var capturedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
