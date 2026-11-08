import Foundation
import CoreVideo

/// 把设备真正交付的 btp2 原始字节按行区间落盘，供设备内自校准使用。
///
/// ## 为什么保留这个
///
/// 自研解包与 Apple 官方 ProRes RAW 解码器给出的结果始终对不上：
/// 同一段素材（092529）里，官方解出的偶/奇像素比是 1.106，
/// 自研 mode9 从设备字节算出来是 0.762。lin_curve 是单调曲线，
/// 只会压伸数值、不会把大小关系翻过来，所以这些排法都不是真实那一种。
///
/// 判据本身有原理性缺陷（奖励「人为制造相关性」的排法），继续猜没有出路。
/// 唯一可靠的做法是拿官方解码结果当标准答案，反推位序——
/// 这需要同一帧的 btp2 原始字节。
///
/// ## 为什么只存行区间
///
/// 整帧 4224×3024 是 19 MB，八帧就 150 MB。校准只需要空间上分布的样本，
/// 取 y ∈ [64, 192) 的 128 行（约 811 KB/帧），八帧合计 6.5 MB。
/// 从 64 行开始是为了避开传感器边缘的无效像素（实测首行会出现孤立高值）。
///
/// 落盘位置：App 沙盒 `Documents/btp2dump`。校准成功后立即删除。
enum BayerDump {

    /// 校准至少需要几帧才能容忍开录瞬间的丢帧
    static let frameLimit = 8
    /// 采样行区间
    static let rowStart = 64
    static let rowCount = 128

    private static var count = 0
    private static let lock = NSLock()
    private static var enabled = false

    /// 只有要走自校准的录制才打开，避免无谓写盘
    static func enable() {
        lock.lock()
        enabled = true
        count = 0
        lock.unlock()
    }

    static func disable() {
        lock.lock()
        enabled = false
        lock.unlock()
    }

    static var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    /// 在采集回调里调用。非 Bayer 帧、未开启、或已存够帧数时直接返回。
    static func capture(_ buffer: CVPixelBuffer) {
        lock.lock()
        let index = count
        let allowed = enabled && index < frameLimit
        if allowed { count += 1 }
        lock.unlock()
        guard allowed else { return }

        guard CVPixelBufferGetPixelFormatType(buffer) == BayerConverter.bayerFormat else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }

        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard rowBytes > 0, height > rowStart + 1 else { return }

        let start = min(rowStart, height - 1)
        let rows = min(rowCount, height - start)
        let slice = base.advanced(by: start * rowBytes)
        let data = Data(bytes: slice, count: rowBytes * rows)

        let directory = storageDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = String(format: "f%02d_%dx%d_row%d_y%d-%d_pf%08x.btp2",
                          index, width, height, rowBytes, start, start + rows,
                          CVPixelBufferGetPixelFormatType(buffer))
        try? data.write(to: directory.appendingPathComponent(name))
    }

    /// 供诊断串使用：已经落盘几帧。
    static var capturedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    static func storageDirectory() -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("btp2dump", isDirectory: true)
    }

    /// 删除所有落盘切片。校准用完成即清，不留垃圾。
    static func clear() {
        let directory = storageDirectory()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names where name.hasSuffix(".btp2") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        lock.lock()
        count = 0
        lock.unlock()
    }

    /// 一份切片：帧序号 + 原始字节 + 几何信息
    struct Slice {
        let index: Int
        let width: Int
        let height: Int
        let rowBytes: Int
        let startRow: Int
        let rowCount: Int
        let bytes: [UInt8]
    }

    /// 读出全部切片，按帧序号升序。
    static func loadSlices() -> [Slice] {
        let directory = storageDirectory()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var slices: [Slice] = []
        for name in names where name.hasSuffix(".btp2") {
            // f00_4224x3024_row6336_y64-192_pf62347032.btp2
            let parts = name.split(separator: "_")
            guard parts.count >= 4 else { continue }
            let index = Int(parts[0].dropFirst()) ?? -1
            let dims = parts[1].split(separator: "x")
            let rowBytes = Int(parts[2].dropFirst(3)) ?? 0
            let range = parts[3].dropFirst().split(separator: "-")
            guard index >= 0, dims.count == 2,
                  let width = Int(dims[0]), let height = Int(dims[1]),
                  rowBytes > 0, range.count == 2,
                  let start = Int(range[0]), let end = Int(range[1]), end > start,
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name))
            else { continue }
            slices.append(Slice(index: index, width: width, height: height,
                                rowBytes: rowBytes, startRow: start,
                                rowCount: end - start, bytes: [UInt8](data)))
        }
        return slices.sorted { $0.index < $1.index }
    }
}
