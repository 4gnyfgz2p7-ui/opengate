import Foundation
import CoreVideo
import CoreGraphics
import CoreMedia

/// 波形示波器采样。
///
/// 性能约束：4224×3024 的 Y 平面有 1277 万像素，逐像素统计会吃掉大量内存带宽。
/// 这里的做法是**固定列数 + 垂直稀疏采样**：
/// - 48 列 → 每列代表画面 1/48 宽度
/// - 每列沿垂直方向等距取 96 个点
/// 单帧约 4 600 次读取，24 fps 下约 11 万次/秒，可忽略。
///
/// 只读 Y 平面，不碰色度——波形看的是亮度分布，色度无意义且要多读一倍数据。
///
/// 分辨率刻意低于显示尺寸：波形本身是统计图，48×96 放大到 150 pt 宽仍有足够信息量，
/// 再往上加列数只增加读取成本，看不出差别。
final class WaveformSampler {

    static let columns = 48
    static let levels = 96

    /// 一次波形读数。
    ///
    /// 判定口径刻意取"是否真的登顶/触底"，而不是 90%、95% 这类经验阈值：
    /// 波形的顶就是编码范围的上限，信号一旦落在这里就已经被削平，
    /// 后期没有任何余量可拉回；没登顶就说明高光还在范围内，可以救。
    /// 这个口径换成 Apple Log 2 后依然成立——log 只是把更多高光压进范围内，
    /// 顶依然是"已经撞到天花板"的那一格。
    struct Reading: Equatable {
        var columns: Int = WaveformSampler.columns
        /// 有像素登顶的列数（高光被削平）
        var highlightColumns: Int = 0
        /// 有像素触底的列数（暗部被压死）
        var shadowColumns: Int = 0

        static let empty = Reading()

        var isHighlightClipped: Bool { highlightColumns > 0 }
        var isShadowClipped: Bool { shadowColumns > 0 }
        var isClean: Bool { !isHighlightClipped && !isShadowClipped }
    }

    private(set) var reading = Reading()

    /// 每多少帧产出一张新图。24 fps / 6 = 4 Hz，肉眼仍算连续。
    var decimation = 6

    private var bins = [UInt32](repeating: 0, count: columns * levels)
    private let lock = NSLock()
    private var frameCounter = 0
    private var isEnabled = true

    func setEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        isEnabled = enabled
        if !enabled {
            // 逐元素清零，不依赖 UnsafeMutableBufferPointer 的较新 API
            for index in bins.indices { bins[index] = 0 }
            reading = .empty
        }
    }

    /// 线程安全的读数快照
    func currentReading() -> Reading {
        lock.lock(); defer { lock.unlock() }
        return reading
    }

    /// 采样一帧。返回 nil 表示这一帧不产出（未到抽帧间隔、波形关闭、或格式不支持）。
    func process(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        lock.lock()
        guard isEnabled else { lock.unlock(); return nil }
        frameCounter += 1
        let shouldEmit = frameCounter % decimation == 0
        lock.unlock()

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard let layout = YPlaneLayout(format: format) else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0 else { return nil }

        var local = [UInt32](repeating: 0, count: Self.columns * Self.levels)

        // 垂直方向按高度均分，采样点数与亮度级数一致（96），
        // 保证每个亮度级都能落到，又不做无谓的重复读取
        let rowsPerColumn = min(Self.levels, height)
        let rowStep = max(1, height / rowsPerColumn)
        let colStep = max(1, width / Self.columns)

        for col in 0..<Self.columns {
            let x = min(width - 1, col * colStep)
            var y = 0
            while y < height {
                let luma = layout.readLuma(base, bytesPerRow, x, y)
                let normalized = layout.normalize(luma)
                let level = min(Self.levels - 1, max(0, Int(normalized * Float(Self.levels - 1) / 255)))
                local[col * Self.levels + level] += 1
                y += rowStep
            }
        }

        lock.lock()
        bins = local
        let emit = shouldEmit
        if emit {
            reading = Self.analyze(local)
        }
        lock.unlock()

        guard emit else { return nil }
        return makeImage()
    }

    /// 逐列检查是否登顶 / 触底。48 列 × 96 级 = 4608 次比较，代价可忽略。
    private static func analyze(_ local: [UInt32]) -> Reading {
        var result = Reading()
        let top = levels - 1
        let bottom = 0

        for col in 0..<columns {
            let base = col * levels
            var clippedTop = false
            var clippedBottom = false

            for level in 0..<levels where local[base + level] > 0 {
                if level == top { clippedTop = true }
                if level == bottom { clippedBottom = true }
            }

            if clippedTop { result.highlightColumns += 1 }
            if clippedBottom { result.shadowColumns += 1 }
        }
        return result
    }

    /// 生成灰度位图。用 CGImage 而不是 SwiftUI Canvas：
    /// Canvas 要逐格 fill 上万个矩形，CGImage 只做一次 8 KB 内存拷贝。
    private func makeImage() -> CGImage? {
        lock.lock()
        let snapshot = bins
        lock.unlock()

        var maxCount: UInt32 = 1
        for value in snapshot where value > maxCount {
            maxCount = value
        }

        let count = Self.columns * Self.levels
        var pixels = [UInt8](repeating: 0, count: count)

        // 对数映射：弱信号也看得见，强信号不糊成一片白
        let denominator = log(1.0 + Double(maxCount))
        for index in 0..<count {
            let value = snapshot[index]
            guard value > 0 else { continue }
            let normalized = log(1.0 + Double(value)) / denominator
            pixels[index] = UInt8(min(255, max(8, normalized * 255)))
        }

        // CGImage 第 0 行在顶部，而亮度 0 应在底部，需要翻转行序
        var flipped = [UInt8](repeating: 0, count: count)
        for row in 0..<Self.levels {
            let source = row * Self.columns
            let target = (Self.levels - 1 - row) * Self.columns
            for i in 0..<Self.columns {
                flipped[target + i] = pixels[source + i]
            }
        }

        return flipped.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: Self.columns,
                height: Self.levels,
                bitsPerComponent: 8,
                bytesPerRow: Self.columns,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }
}

// MARK: - Y 平面布局

/// 不同像素格式的 Y 平面读取方式与归一化规则。
private enum YPlaneLayout {
    case u8VideoRange      // 16–235
    case u8FullRange       // 0–255
    case u16VideoRange     // 64–940（10-bit）
    case u16FullRange      // 0–1023（10-bit）

    init?(format: OSType) {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            self = .u8VideoRange
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            self = .u8FullRange
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            self = .u16VideoRange
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            self = .u16FullRange
        default:
            return nil
        }
    }

    func readLuma(_ base: UnsafeMutableRawPointer, _ bytesPerRow: Int, _ x: Int, _ y: Int) -> Float {
        switch self {
        case .u8VideoRange, .u8FullRange:
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            return Float(pointer[y * bytesPerRow + x])
        case .u16VideoRange, .u16FullRange:
            // 10-bit 存在 16-bit 容器里，小端
            let pointer = base.assumingMemoryBound(to: UInt16.self)
            let index = y * (bytesPerRow / 2) + x
            return Float(UInt16(littleEndian: pointer[index]))
        }
    }

    /// 归一化到 0–255，便于统一映射到 128 个亮度级
    func normalize(_ value: Float) -> Float {
        let result: Float
        switch self {
        case .u8VideoRange:
            result = (value - 16) / 219 * 255
        case .u8FullRange:
            result = value
        case .u16VideoRange:
            result = (value - 64) / 876 * 255
        case .u16FullRange:
            result = value / 1023 * 255
        }
        return min(255, max(0, result))
    }
}
