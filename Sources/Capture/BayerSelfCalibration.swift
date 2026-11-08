import Foundation
import CoreVideo
import AVFoundation

/// 在设备上反推 btp2 的真实解包位序。
///
/// ## 思路
///
/// 判据本身有原理性缺陷——「相邻像素差最小」会奖励 mode9/10 那种
/// 让相邻像素共享低位字节的排法，所以永远选错。换成任何同层统计量都没用。
///
/// 唯一可靠的锚点是**官方解码器的输出**：同一段 ProRes RAW，Apple 解出来的
/// bp16 是标准答案。只要拿到同一帧的 btp2 原始字节，位序就是可计算的：
/// 对每种候选排法算与标准答案的秩相关，最高的那个就是真实排法。
///
/// 用秩相关而不是线性相关，是因为官方输出可能经过 lin_curve；
/// 单调曲线不改变排序，秩相关对它免疫。
///
/// 校准一旦成功就写进 UserDefaults，之后 HEVC 录制直接用这个位序，
/// **不再需要中转，恢复实时**。
enum BayerSelfCalibration {

    struct Solution {
        var mode: Int32
        var pattern: Int32
        var score: Double
        var frames: Int
        var date: Date

        var summary: String {
            String(format: "mode=%d pat=%d ρ=%.4f n=%d", mode, pattern, score, frames)
        }
    }

    private static let key = "bayer.selfcalibration.v1"

    // MARK: - 持久化

    static var saved: Solution? {
        get {
            guard let raw = UserDefaults.standard.dictionary(forKey: key),
                  let mode = raw["mode"] as? Int,
                  let pattern = raw["pattern"] as? Int,
                  let score = raw["score"] as? Double,
                  let frames = raw["frames"] as? Int,
                  let stamp = raw["date"] as? Double
            else { return nil }
            return Solution(mode: Int32(mode), pattern: Int32(pattern),
                            score: score, frames: frames,
                            date: Date(timeIntervalSince1970: stamp))
        }
        set {
            if let newValue {
                UserDefaults.standard.set([
                    "mode": Int(newValue.mode),
                    "pattern": Int(newValue.pattern),
                    "score": newValue.score,
                    "frames": newValue.frames,
                    "date": newValue.date.timeIntervalSince1970,
                ], forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    static var hasSolution: Bool {
        (saved?.score ?? 0) > 0.90
    }

    // MARK: - 主流程

    /// 读 dump 切片 + 官方解码结果，算出真实位序。
    /// 失败返回 nil，调用方保留原路径即可。
    static func calibrate(rawURL: URL) -> Solution? {
        let slices = BayerDump.loadSlices()
        guard let first = slices.first, !first.bytes.isEmpty else { return nil }

        let width = first.width
        let height = first.height
        let rowBytes = first.rowBytes
        let startRow = first.startRow
        let rows = first.rowCount
        guard width > 512, rowBytes > 0 else { return nil }

        // 官方帧：解足够多帧以容忍开录丢帧
        let wanted = min(24, slices.count + 8)
        var official: [[Double]] = []
        do {
            _ = try ProResRAWReader.decode(url: rawURL, limit: wanted) { buffer, _, _ in
                official.append(sampleOfficial(buffer, width: width,
                                               startRow: startRow, rows: rows))
                return true
            }
        } catch {
            return nil
        }
        guard official.count >= 2 else { return nil }

        // 采样点：x 取 16 的倍数，保证 8px/12B 与 2px/3B 的块边界同时对齐
        let stepX = 16
        let columns = stride(from: 0, to: width - 8, by: stepX).map { $0 }
        guard columns.count > 64 else { return nil }

        // 每隔 4 行取一行
        let rowIndexes = stride(from: 0, to: rows, by: 4).map { $0 }

        // 标准答案的秩先算一次：offset 循环里反复用，避免重复排序。
        // 8416 个点排一次约 1 ms，若放进 11×8 的双层循环就是 700 多次排序。
        let officialRanks = official.map { ranks($0) }

        var best: (mode: Int32, offset: Int, score: Double)?

        for mode in Int32(0)...10 {
            // 该 mode 下每个 dump 切片的秩也只算一次
            let decodedRanks = slices.map { slice in
                ranks(decode(slice: slice, mode: mode,
                             columns: columns, rowIndexes: rowIndexes))
            }
            for offset in 0..<min(8, official.count) {
                var total = 0.0
                var pairs = 0
                for (slot, values) in decodedRanks.enumerated() {
                    let target = slot + offset
                    guard target < officialRanks.count else { break }
                    let reference = officialRanks[target]
                    guard reference.count == values.count, !values.isEmpty else { continue }
                    total += pearson(values, reference)
                    pairs += 1
                }
                guard pairs > 0 else { continue }
                let score = total / Double(pairs)
                if best == nil || score > best!.score {
                    best = (mode, offset, score)
                }
            }
        }

        guard let best, best.score > 0.90 else { return nil }

        // 相位：官方如果声明了就用它，否则沿用 RGGB
        let pattern = Int32(BayerSelfCalibration.detectPattern(
            slice: first, mode: best.mode, columns: columns
        ))

        return Solution(mode: best.mode, pattern: pattern, score: best.score,
                        frames: slices.count, date: Date())
    }

    // MARK: - 采样

    /// 官方 bp16 帧 → 按相同列/行采样的值
    private static func sampleOfficial(
        _ buffer: CVPixelBuffer,
        width: Int, startRow: Int, rows: Int
    ) -> [Double] {
        guard CVPixelBufferGetPixelFormatType(buffer) == BayerConverter.planar16Format else {
            return []
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }

        let bufferWidth = CVPixelBufferGetWidth(buffer)
        let bufferHeight = CVPixelBufferGetHeight(buffer)
        let rowStride = CVPixelBufferGetBytesPerRow(buffer) / 2
        let line = base.assumingMemoryBound(to: UInt16.self)

        var values: [Double] = []
        values.reserveCapacity(rows * 128)
        for offset in stride(from: 0, to: rows, by: 4) {
            let y = startRow + offset
            guard y < bufferHeight else { break }
            let row = line.advanced(by: y * rowStride)
            for x in stride(from: 0, to: min(width, bufferWidth) - 8, by: 16) {
                values.append(Double(row[x] >> 4))
            }
        }
        return values
    }

    /// 一份 btp2 切片 → 按给定排法解出的值
    private static func decode(
        slice: BayerDump.Slice,
        mode: Int32,
        columns: [Int],
        rowIndexes: [Int]
    ) -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(columns.count * rowIndexes.count)
        slice.bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for rowIndex in rowIndexes {
                guard rowIndex < slice.rowCount else { break }
                let row = base.advanced(by: rowIndex * slice.rowBytes)
                for x in columns {
                    values.append(BayerCalibration.unpack(row, x, mode: Int(mode)))
                }
            }
        }
        return values
    }

    /// 从四个相位组里找两个绿点：绿点在物理上成对出现且电平接近。
    private static func detectPattern(
        slice: BayerDump.Slice, mode: Int32, columns: [Int]
    ) -> Int {
        var levels = [Double](repeating: 0, count: 4)
        var counts = [Int](repeating: 0, count: 4)
        slice.bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for rowIndex in stride(from: 0, to: slice.rowCount, by: 2) {
                let row = base.advanced(by: rowIndex * slice.rowBytes)
                for x in columns where x + 1 < slice.width {
                    let phase = ((rowIndex & 1) << 1) | (x & 1)
                    levels[phase] += BayerCalibration.unpack(row, x, mode: Int(mode))
                    counts[phase] += 1
                }
            }
        }
        for index in 0..<4 where counts[index] > 0 {
            levels[index] /= Double(counts[index])
        }
        // 对角两两成对：green 在 (0,1)/(1,0) 即 phase1/phase2（RGGB/GBRG 族）
        // 或 (0,0)/(1,1) 即 phase0/phase3（BGGR/GRBG 族）。
        // 绿点在 Bayer 结构里总是反对角，所以比较这两对的接近程度。
        let diag = abs(levels[1] - levels[2]) / max(levels[1] + levels[2], 1)
        let main = abs(levels[0] - levels[3]) / max(levels[0] + levels[3], 1)
        // 更接近的一对是绿点。等值场景无法判断时默认 RGGB。
        return diag <= main ? 0 : 3
    }

    // MARK: - 统计

    /// 两条秩序列的相关系数。
    /// 输入已经是秩，所以这里就是普通 Pearson——秩变换本身已经消掉了
    /// lin_curve 这类单调曲线的影响。
    private static func pearson(_ ra: [Double], _ rb: [Double]) -> Double {
        guard ra.count == rb.count, ra.count > 8 else { return 0 }
        let n = Double(ra.count)
        var meanA = 0.0, meanB = 0.0
        for index in 0..<ra.count {
            meanA += ra[index]
            meanB += rb[index]
        }
        meanA /= n
        meanB /= n
        var cov = 0.0, varA = 0.0, varB = 0.0
        for index in 0..<ra.count {
            let da = ra[index] - meanA
            let db = rb[index] - meanB
            cov += da * db
            varA += da * da
            varB += db * db
        }
        guard varA > 1e-12, varB > 1e-12 else { return 0 }
        return cov / (varA.squareRoot() * varB.squareRoot())
    }

    private static func ranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var result = [Double](repeating: 0, count: values.count)
        var position = 0
        while position < order.count {
            var end = position
            while end + 1 < order.count,
                  values[order[end + 1]] == values[order[position]] {
                end += 1
            }
            let average = Double(position + end) / 2.0 + 1.0
            for slot in position...end {
                result[order[slot]] = average
            }
            position = end + 1
        }
        return result
    }
}
