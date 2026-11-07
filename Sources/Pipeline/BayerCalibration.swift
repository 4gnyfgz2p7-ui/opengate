import Foundation
import CoreVideo

/// Bayer 解包方式的自动标定。
///
/// 12-bit 打包有两种常见排法，外观完全一样（都是两像素三字节），
/// 只有把样本取出来才看得出区别：
///
///   A（MIPI 常见）：p0 = (b0 << 4) | (b1 >> 4)   p1 = ((b1 & 0x0F) << 8) | b2
///   B（低位在前）  ：p0 = b0 | ((b1 & 0x0F) << 8)   p1 = (b1 >> 4) | (b2 << 4)
///
/// 取错了不会报错，只会得到一张"浮雕"般的图：每个像素都变成相邻像素之差。
/// 这里不靠猜，直接按画面本身的统计特性挑：正确排法下色度在相邻块之间是连续的，
/// 错误排法下色度逐块跳变。
final class BayerCalibration {

    struct Outcome {
        /// 0 = A，1 = B
        var unpackMode: Int32 = 0
        /// 0=RGGB 1=BGGR 2=GRBG 3=GBRG
        var pattern: Int32 = 0
        var score: Float = .greatestFiniteMagnitude
        /// 相邻块色度跳变的平均幅度（越小越像正常图像）
        var chromaEnergy: Float = 0
        /// 白平衡后 R 与 B 的失衡程度
        var neutrality: Float = 0

        var summary: String {
            let modeName = unpackMode == 0 ? "A" : "B"
            let patternName = ["RGGB", "BGGR", "GRBG", "GBRG"][Int(pattern)]
            return "\(modeName) · \(patternName) · \(String(format: "%.1f", chromaEnergy))"
        }
    }

    /// 每个相位是什么颜色：0=R 1=G 2=B
    private static let colors: [[Int]] = [
        [0, 1, 1, 2],   // RGGB
        [2, 1, 1, 0],   // BGGR
        [1, 0, 2, 1],   // GRBG
        [1, 2, 0, 1],   // GBRG
    ]

    /// 稀疏采样标定。只读几十万个样本，几毫秒完成，第一帧跑一次即可。
    static func run(
        base: UnsafeMutableRawPointer,
        rowBytes: Int,
        width: Int,
        height: Int,
        black: Float,
        white: Float,
        redGain: Float,
        blueGain: Float,
        preferredPattern: Int32
    ) -> Outcome {

        let step = 24
        let invRange = 1.0 / Double(max(white - black, 1))

        func sample(_ mode: Int, _ x: Int, _ y: Int) -> Double {
            let row = base.advanced(by: y * rowBytes)
                .assumingMemoryBound(to: UInt8.self)
            let index = (x >> 1) * 3
            let b0 = Double(row[index])
            let b1 = Double(row[index + 1])
            let b2 = Double(row[index + 2])
            if mode == 0 {
                if (x & 1) == 0 {
                    return (b0 * 16 + floor(b1 / 16))
                }
                return ((b1 - floor(b1 / 16) * 16) * 256 + b2)
            } else {
                if (x & 1) == 0 {
                    return b0 + (b1 - floor(b1 / 16) * 16) * 256
                }
                return (floor(b1 / 16) + b2 * 16)
            }
        }

        var best = Outcome()
        best.pattern = preferredPattern

        for mode in 0...1 {
            // 先算每个候选的色度能量和灰world 平衡
            var perPattern = [(energy: Double, sumR: Double, sumB: Double, sumG: Double)]()

            for pattern in 0..<4 {
                let table = colors[pattern]
                var energy = 0.0
                var previousChroma: Double?
                var sumR = 0.0
                var sumG = 0.0
                var sumB = 0.0
                var count = 0.0

                var y = 0
                while y + 1 < height {
                    previousChroma = nil
                    var x = 0
                    while x + 1 < width {
                        // 一个 2×2 块
                        var quad = [Double](repeating: 0, count: 4)
                        quad[0] = sample(mode, x, y)
                        quad[1] = sample(mode, x + 1, y)
                        quad[2] = sample(mode, x, y + 1)
                        quad[3] = sample(mode, x + 1, y + 1)

                        var red = 0.0
                        var blue = 0.0
                        var green = 0.0
                        for index in 0..<4 {
                            let value = max(0.0, (quad[index] - Double(black)) * invRange)
                            switch table[index] {
                            case 0: red = value
                            case 2: blue = value
                            default: green = (green + value) * 0.5
                            }
                        }

                        let chroma = (red - blue)
                        if let previous = previousChroma {
                            energy += abs(chroma - previous)
                        }
                        previousChroma = chroma

                        sumR += red * Double(redGain)
                        sumB += blue * Double(blueGain)
                        sumG += green
                        count += 1

                        x += step
                    }
                    y += step
                }

                let normalized = count > 0 ? energy / count : .greatestFiniteMagnitude
                perPattern.append((normalized, sumR, sumB, sumG))
            }

            // 色度能量最小的那个排法才可能是对的；
            // R/B 对调不会改变色度能量的量级，用白平衡后的中立性来区分。
            guard let minEnergy = perPattern.map({ $0.energy }).min() else { continue }
            for pattern in 0..<4 {
                let entry = perPattern[pattern]
                // 只接受接近最优的候选（避免把噪声当信号）
                guard entry.energy <= minEnergy * 1.35 + 1e-6 else { continue }
                let red = max(entry.sumR, 1e-6)
                let blue = max(entry.sumB, 1e-6)
                let neutrality = abs(log(red / blue))
                let score = entry.energy + neutrality * 4.0

                if score < best.score {
                    best.score = Float(score)
                    best.chromaEnergy = Float(entry.energy)
                    best.neutrality = Float(neutrality)
                    best.unpackMode = Int32(mode)
                    best.pattern = Int32(pattern)
                }
            }
        }

        return best
    }
}
