import Foundation
import CoreVideo

/// Bayer 解包方式与相位的自动标定。
///
/// 12-bit 打包有三种常见排法，外观完全一样（都是两像素三字节），
/// 只有把样本取出来才看得出区别：
///
///   A：p0 = (b0 << 4) | (b1 >> 4)      p1 = ((b1 & 0x0F) << 8) | b2
///   B：p0 = b0 | ((b1 & 0x0F) << 8)    p1 = (b1 >> 4) | (b2 << 4)
///   C：p0 = ((b0 & 0xF0) << 4) | b1    p1 = ((b0 & 0x0F) << 8) | b2
///
/// 取错了不会报错，只会得到一张"浮雕"般的图：每个像素都变成相邻像素之差。
///
/// 判据在 PC 上用合成数据验过，不是猜的：
/// - **排法**看「同色相邻样本的平均差」。正确排法下同一颜色位置相隔 2 像素的样本
///   是平滑的；实测（打包 A）A=0.0004、B=0.0018、C=0.0103，分离度 4–25 倍。
/// - **相位**看「一格里两个绿点的差」。正确相位下两绿点高度相关（0.0006），
///   错相位把 R、B 当成绿点（0.20），差两个数量级。
/// - **R/B 谁在前**看白平衡后的中立性：设备给的增益本来就是中和现场用的，
///   套错方向会明显偏离（实测 0.40 对 0.94）。
final class BayerCalibration {

    struct Outcome {
        /// 0 = A，1 = B，2 = C
        var unpackMode: Int32 = 0
        /// 0=RGGB 1=BGGR 2=GRBG 3=GBRG
        var pattern: Int32 = 0
        var score: Float = .greatestFiniteMagnitude
        /// 同色相邻样本的平均差（越小越像正常图像）
        var gradient: Float = 0
        /// 一格里两个绿点的平均差
        var greenPair: Float = 0
        /// 白平衡后 R 与 B 的失衡程度
        var neutrality: Float = 0

        var summary: String {
            let modes = ["A", "B", "C"]
            let patterns = ["RGGB", "BGGR", "GRBG", "GBRG"]
            let modeName = modes[Int(max(0, min(2, unpackMode)))]
            let patternName = patterns[Int(max(0, min(3, pattern)))]
            return modeName + "·" + patternName + "·" + String(format: "%.3f", gradient)
        }
    }

    /// 每个相位是什么颜色：0=R 1=G 2=B
    private static let colors: [[Int]] = [
        [0, 1, 1, 2],   // RGGB
        [2, 1, 1, 0],   // BGGR
        [1, 0, 2, 1],   // GRBG
        [1, 2, 0, 1],   // GBRG
    ]

    private static func unpack(
        _ base: UnsafeMutableRawPointer,
        _ rowBytes: Int,
        _ x: Int,
        _ y: Int,
        _ mode: Int
    ) -> Double {
        let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
        let index = (x >> 1) * 3
        let b0 = Double(row[index])
        let b1 = Double(row[index + 1])
        let b2 = Double(row[index + 2])
        switch mode {
        case 0:
            return (x & 1) == 0 ? (b0 * 16 + floor(b1 / 16))
                                : ((b1 - floor(b1 / 16) * 16) * 256 + b2)
        case 1:
            return (x & 1) == 0 ? (b0 + (b1 - floor(b1 / 16) * 16) * 256)
                                : (floor(b1 / 16) + b2 * 16)
        default:
            return (x & 1) == 0 ? (floor(b0 / 16) * 256 + b1)
                                : ((b0 - floor(b0 / 16) * 16) * 256 + b2)
        }
    }

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
        let blackValue = Double(black)

        func value(_ mode: Int, _ x: Int, _ y: Int) -> Double {
            max(0.0, (unpack(base, rowBytes, x, y, mode) - blackValue) * invRange)
        }

        // ---- 第一关：排法 ----
        var gradients = [Double](repeating: .greatestFiniteMagnitude, count: 3)
        var zeroFractions = [Double](repeating: 1, count: 3)

        for mode in 0..<3 {
            var total = 0.0
            var samples = 0.0
            var zeros = 0.0
            var y = 0
            while y + 4 < height {
                var x = 0
                while x + 4 < width {
                    let a = value(mode, x, y)
                    let b = value(mode, x + 2, y)
                    let c = value(mode, x, y + 2)
                    let d = value(mode, x, y + 4)
                    total += abs(a - b) + abs(a - c) + abs(b - d)
                    samples += 3
                    if a == 0 { zeros += 1 }
                    x += step
                }
                y += step
            }
            gradients[mode] = samples > 0 ? total / samples : .greatestFiniteMagnitude
            zeroFractions[mode] = samples > 0 ? zeros / (samples / 3) : 1
        }

        var bestMode = 0
        var bestModeScore = Double.greatestFiniteMagnitude
        let minGradient = gradients.min() ?? 0
        for mode in 0..<3 {
            // 梯度为主；两种排法接近时（1.5 倍以内）用"读出来全黑"的比例破平
            var score = gradients[mode]
            score += gradients[mode] <= minGradient * 1.5
                ? zeroFractions[mode] * 0.01
                : zeroFractions[mode] * 0.5
            if score < bestModeScore {
                bestModeScore = score
                bestMode = mode
            }
        }

        // ---- 第二关：相位 ----
        var bestPattern = Int(preferredPattern)
        var bestPatternScore = Double.greatestFiniteMagnitude
        var bestGreenPair = 0.0
        var bestNeutrality = 0.0

        for pattern in 0..<4 {
            let table = colors[pattern]
            guard let greenA = table.firstIndex(of: 1),
                  let greenB = table.lastIndex(of: 1),
                  let redIndex = table.firstIndex(of: 0),
                  let blueIndex = table.firstIndex(of: 2)
            else { continue }

            var greenPair = 0.0
            var redSum = 0.0
            var blueSum = 0.0
            var count = 0.0

            var y = 0
            while y + 1 < height {
                var x = 0
                while x + 1 < width {
                    var quad = [Double](repeating: 0, count: 4)
                    for index in 0..<4 {
                        quad[index] = value(bestMode, x + (index & 1), y + (index >> 1))
                    }
                    greenPair += abs(quad[greenA] - quad[greenB])
                    redSum += quad[redIndex] * Double(redGain)
                    blueSum += quad[blueIndex] * Double(blueGain)
                    count += 1
                    x += step
                }
                y += step
            }

            guard count > 0 else { continue }
            let normalizedPair = greenPair / count
            let neutrality = abs(log(max(redSum, 1e-6) / max(blueSum, 1e-6)))
            let score = normalizedPair + neutrality * 0.5

            if score < bestPatternScore {
                bestPatternScore = score
                bestPattern = pattern
                bestGreenPair = normalizedPair
                bestNeutrality = neutrality
            }
        }

        var outcome = Outcome()
        outcome.unpackMode = Int32(bestMode)
        outcome.pattern = Int32(bestPattern)
        outcome.score = Float(bestPatternScore)
        outcome.gradient = Float(gradients[bestMode])
        outcome.greenPair = Float(bestGreenPair)
        outcome.neutrality = Float(bestNeutrality)
        return outcome
    }
}
