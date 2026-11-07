import Foundation
import CoreVideo

/// Bayer 解包方式与相位的自动标定。
///
/// `btp2` 的字节排列 Apple 没有公开文档，只能靠数据本身的统计性质反推。
/// 硬事实只有一条：`bytesPerRow = 6336 = 4224 × 1.5`，即**每像素 1.5 字节**。
/// 1.5 字节/像素可以有很多种切法，外观尺寸完全相同，只有把样本取出来才分得清。
///
/// 所以这里不做假设，直接把候选排法全列出来，**在真实帧上逐种打分**：
///
/// 判据是 Bayer 阵列的物理性质——(x, y) 与 (x+2, y)、(x, y+2) 落在同色滤光片下，
/// 它们的值必须高度接近；(x+1, y)、(x, y+1) 是异色，天然差得远。
/// 于是「同色差 / 异色差」这个比值在正确排法下明显小于 1，错排下逼近或超过 1。
/// 这个判据不需要知道黑电平、白平衡和相位，因此不受它们出错的影响。
///
/// 相位另用「一格里两个绿点之差」判定：正确相位下两绿点同色，差极小。
final class BayerCalibration {

    /// 候选排法数量
    static let candidateCount = 9

    struct Outcome {
        /// 选中的排法下标，与 `unpack(mode:)` 和着色器里的分支一一对应
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
        /// 原始样本的 min-max/mean（**未扣黑电平**），用来看黑白电平参数是否合理
        var rawRangeText: String = "—"
        /// 各候选排法的「同色/异色」比值，诊断用：数值最小者即最可能的正确排法
        var modeRatios: [Double] = []
        /// 标定算出的相位
        var calibratedPattern: Int32 = 0
        /// 设备通过 ProRAW 附件给出的相位
        var devicePattern: Int32 = 0
        /// 由场景本身算出的白平衡增益（灰世界，60% 分位），录制期间锁定
        var whiteBalanceRed: Float = 1
        var whiteBalanceBlue: Float = 1
        /// 场景原始的 R/G、B/G 比例（未加任何增益），诊断用
        var levelRed: Double = 1
        var levelBlue: Double = 1

        var summary: String {
            let patterns = ["RGGB", "BGGR", "GRBG", "GBRG"]
            let patternName = patterns[Int(max(0, min(3, pattern)))]
            let calibrated = patterns[Int(max(0, min(3, calibratedPattern)))]
            let device = patterns[Int(max(0, min(3, devicePattern)))]
            var text = "m\(unpackMode)·" + patternName
            text += "·" + String(format: "%.3f", gradient)
            if calibrated != patternName || device != patternName {
                text += "·标定" + calibrated + "/设备" + device
            }
            text += String(format: "·wb%.2f/%.2f", Double(whiteBalanceRed), Double(whiteBalanceBlue))
            text += String(format: "·lv%.2f/%.2f", min(levelRed, 9.99), min(levelBlue, 9.99))
            if !modeRatios.isEmpty {
                // 九种排法的比值，两位小数够看：最小那个就是被判为正确的排法
                let list = modeRatios.map { String(format: "%.2f", min($0, 9.99)) }
                text += "·r" + list.joined(separator: "/")
            }
            return text
        }
    }

    /// 每个相位是什么颜色：0=R 1=G 2=B
    private static let colors: [[Int]] = [
        [0, 1, 1, 2],   // RGGB
        [2, 1, 1, 0],   // BGGR
        [1, 0, 2, 1],   // GRBG
        [1, 2, 0, 1],   // GBRG
    ]

    // MARK: - 九种候选排法

    /// 从行首指针按 `mode` 取第 x 个像素的 12 位样本。
    ///
    /// 所有排法都建立在「每像素 1.5 字节」上，区别只在于这 12 位由哪几个字节拼成。
    /// 0/1：8 像素 12 字节，前 8 字节是各像素高 8 位，后 4 字节是低 4 位
    /// 2–5：2 像素 3 字节（MIPI RAW12 的几种常见位序）
    /// 6/7：4 像素 6 字节
    /// 8：8 像素 12 字节，但**低 4 位字节在前**
    @inline(__always)
    static func unpack(
        _ row: UnsafePointer<UInt8>,
        _ x: Int,
        mode: Int
    ) -> Double {
        switch mode {

        case 0:     // 8px/12B，偶像素取低半字节的高位
            let g = x >> 3
            let k = x & 7
            let blk = row + g * 12
            let lo = UInt32(blk[8 + (k >> 1)])
            let nib = (k & 1) == 0 ? (lo >> 4) : (lo & 0x0F)
            return Double((UInt32(blk[k]) << 4) | nib)

        case 1:     // 同 0，偶像素取低半字节
            let g = x >> 3
            let k = x & 7
            let blk = row + g * 12
            let lo = UInt32(blk[8 + (k >> 1)])
            let nib = (k & 1) == 0 ? (lo & 0x0F) : (lo >> 4)
            return Double((UInt32(blk[k]) << 4) | nib)

        case 2:     // 2px/3B：p0 = b0<<4 | b1>>4，p1 = (b1&0xF)<<8 | b2
            let g = x >> 1
            let blk = row + g * 3
            let b0 = UInt32(blk[0]), b1 = UInt32(blk[1]), b2 = UInt32(blk[2])
            return Double((x & 1) == 0 ? ((b0 << 4) | (b1 >> 4)) : (((b1 & 0x0F) << 8) | b2))

        case 3:     // 2px/3B：p0 = b0<<4 | b2>>4，p1 = (b2&0xF)<<8 | b1
            let g = x >> 1
            let blk = row + g * 3
            let b0 = UInt32(blk[0]), b1 = UInt32(blk[1]), b2 = UInt32(blk[2])
            return Double((x & 1) == 0 ? ((b0 << 4) | (b2 >> 4)) : (((b2 & 0x0F) << 8) | b1))

        case 4:     // 2px/3B 小端：p0 = b0 | (b1&0xF)<<8，p1 = b1>>4 | b2<<4
            let g = x >> 1
            let blk = row + g * 3
            let b0 = UInt32(blk[0]), b1 = UInt32(blk[1]), b2 = UInt32(blk[2])
            return Double((x & 1) == 0 ? (b0 | ((b1 & 0x0F) << 8)) : ((b1 >> 4) | (b2 << 4)))

        case 5:     // 2px/3B 小端变体：p0 = b0 | (b2&0xF)<<8，p1 = b2>>4 | b1<<4
            let g = x >> 1
            let blk = row + g * 3
            let b0 = UInt32(blk[0]), b1 = UInt32(blk[1]), b2 = UInt32(blk[2])
            return Double((x & 1) == 0 ? (b0 | ((b2 & 0x0F) << 8)) : ((b2 >> 4) | (b1 << 4)))

        case 6:     // 4px/6B：前 4 字节高 8 位，后 2 字节低 4 位
            let g = x >> 2
            let k = x & 3
            let blk = row + g * 6
            let lo = UInt32(blk[4 + (k >> 1)])
            let nib = (k & 1) == 0 ? (lo >> 4) : (lo & 0x0F)
            return Double((UInt32(blk[k]) << 4) | nib)

        case 7:     // 4px/6B：前 2 字节低 4 位，后 4 字节高 8 位
            let g = x >> 2
            let k = x & 3
            let blk = row + g * 6
            let lo = UInt32(blk[k >> 1])
            let nib = (k & 1) == 0 ? (lo >> 4) : (lo & 0x0F)
            return Double((UInt32(blk[2 + k]) << 4) | nib)

        default:    // 8：8px/12B，低 4 位字节在前
            let g = x >> 3
            let k = x & 7
            let blk = row + g * 12
            let lo = UInt32(blk[k >> 1])
            let nib = (k & 1) == 0 ? (lo >> 4) : (lo & 0x0F)
            return Double((UInt32(blk[4 + k]) << 4) | nib)
        }
    }

    // MARK: - 标定

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
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        @inline(__always)
        func value(_ mode: Int, _ x: Int, _ y: Int) -> Double {
            let row = bytes.advanced(by: y * rowBytes)
            return max(0.0, (unpack(row, x, mode: mode) - blackValue) * invRange)
        }

        // ---- 第一关：排法 ----
        //
        // 采样点只取偶数坐标，且从 step 起步：y = 0 行贴着传感器边缘，
        // 前几个像素可能是无效区（实测那一段会出现 3000 以上的孤立值），
        // 拿它当判据会误导。
        var sameDiff = [Double](repeating: 0, count: candidateCount)
        var crossDiff = [Double](repeating: 0, count: candidateCount)
        var sampleCount = 0.0

        var sampleY = step
        while sampleY + 2 < height {
            var sampleX = step
            while sampleX + 2 < width {
                for mode in 0..<candidateCount {
                    let center = value(mode, sampleX, sampleY)
                    sameDiff[mode] += abs(center - value(mode, sampleX + 2, sampleY))
                                   + abs(center - value(mode, sampleX, sampleY + 2))
                    crossDiff[mode] += abs(center - value(mode, sampleX + 1, sampleY))
                                    + abs(center - value(mode, sampleX, sampleY + 1))
                }
                sampleCount += 1
                sampleX += step
            }
            sampleY += step
        }

        var ratios = [Double](repeating: .greatestFiniteMagnitude, count: candidateCount)
        var bestMode = 0
        var bestRatio = Double.greatestFiniteMagnitude
        for mode in 0..<candidateCount {
            // 异色差接近 0 说明这一排法把画面解成了一片死平（或全被黑电平压成 0），
            // 不能因为分子分母同时接近 0 就判它最优
            guard crossDiff[mode] > 1e-9 * max(sampleCount, 1) else { continue }
            let ratio = sameDiff[mode] / crossDiff[mode]
            ratios[mode] = ratio
            if ratio < bestRatio {
                bestRatio = ratio
                bestMode = mode
            }
        }

        // 原始样本统计：不扣黑电平，直接看传感器给了什么
        var rawMin = Double.greatestFiniteMagnitude
        var rawMax = 0.0
        var rawSum = 0.0
        var rawCount = 0.0
        var rawY = step
        while rawY + 4 < height {
            var rawX = step
            while rawX + 4 < width {
                let sample = unpack(bytes.advanced(by: rawY * rowBytes), rawX, mode: bestMode)
                if sample < rawMin { rawMin = sample }
                if sample > rawMax { rawMax = sample }
                rawSum += sample
                rawCount += 1
                rawX += step
            }
            rawY += step
        }
        let rawRangeText: String
        if rawCount > 0, rawMin.isFinite {
            rawRangeText = String(format: "%.0f-%.0f/%.0f", rawMin, rawMax, rawSum / rawCount)
        } else {
            rawRangeText = "—"
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

            var y = step
            while y + 1 < height {
                var x = step
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

        // ---- 第三关：场景白平衡 ----
        //
        // 设备给的 ProResRAW_WhiteBalance*Factor 量纲不可靠：0.5.14 实测按它乘完，
        // G 只有 63 而 R 到 100、B 到 91，画面整体偏品红。这里不猜量纲，
        // 直接用场景自己定：取每通道 60% 分位（避开暗部噪声与高光削顶），让三者相等。
        // 结果在整段录制里锁定，等于固定白平衡。
        let wbTable = colors[bestPattern]
        var samplesR: [Double] = []
        var samplesG: [Double] = []
        var samplesB: [Double] = []
        samplesR.reserveCapacity(8192)
        samplesG.reserveCapacity(8192)
        samplesB.reserveCapacity(8192)

        var wbY = step
        while wbY + 1 < height {
            var wbX = step
            while wbX + 1 < width {
                for index in 0..<4 {
                    let sample = value(bestMode, wbX + (index & 1), wbY + (index >> 1))
                    switch wbTable[index] {
                    case 0: samplesR.append(sample)
                    case 1: samplesG.append(sample)
                    default: samplesB.append(sample)
                    }
                }
                wbX += step
            }
            wbY += step
        }

        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let position = Int(Double(sorted.count - 1) * fraction)
            return sorted[max(0, min(sorted.count - 1, position))]
        }

        let levelR = percentile(samplesR, 0.6)
        let levelG = percentile(samplesG, 0.6)
        let levelB = percentile(samplesB, 0.6)

        var whiteBalanceRed: Float = 1
        var whiteBalanceBlue: Float = 1
        // 画面太暗（绿通道分位低于 1% 满量程）时三通道都被噪声主导，
        // 算出来的比例没有意义，宁可不动白平衡
        if levelG > 0.01 {
            if levelR > 1e-6 {
                // 0.35–2.8 之外的比例不是白平衡能解释的，多半是通道算错了，别硬拉
                whiteBalanceRed = Float(min(2.8, max(0.35, levelG / levelR)))
            }
            if levelB > 1e-6 {
                whiteBalanceBlue = Float(min(2.8, max(0.35, levelG / levelB)))
            }
        }

        var outcome = Outcome()
        outcome.unpackMode = Int32(bestMode)
        outcome.pattern = Int32(bestPattern)
        outcome.modeRatios = ratios
        outcome.calibratedPattern = Int32(bestPattern)
        outcome.devicePattern = Int32(preferredPattern)
        outcome.score = Float(bestPatternScore)
        outcome.gradient = Float(sameDiff[bestMode] / max(sampleCount * 2, 1))
        outcome.greenPair = Float(bestGreenPair)
        outcome.neutrality = Float(bestNeutrality)
        outcome.rawRangeText = rawRangeText
        outcome.whiteBalanceRed = whiteBalanceRed
        outcome.whiteBalanceBlue = whiteBalanceBlue
        outcome.levelRed = levelR / max(levelG, 1e-9)
        outcome.levelBlue = levelB / max(levelG, 1e-9)
        return outcome
    }
}
