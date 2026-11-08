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
    static let candidateCount = 11

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
        /// R/B 是否被自检翻转
        var redBlueSwapped = false
        /// 实际生效的黑白电平
        var blackLevel: Double = 0
        var whiteLevel: Double = 4095
        /// 选中排法的平均总变差（诊断用）
        var bestVariation: Double = 0
        /// 各排法的 mod-8 同色方差。只作历史对照，不参与选择
        var modePeriodicities: [Double] = []
        /// 各排法的相邻差均方根，最小者即选中（真正的主判据）
        var modeCross: [Double] = []
        /// 四种相位各自的 R/G、B/G（八个数），用于在设备值与图像统计冲突时裁决
        var patternLevels: [Double] = []
        /// 四种相位的「两绿点相对差」，最小者即真实相位
        var patternGreen: [Double] = []
        /// 白平衡是否来自设备 AWB（false 表示退回了灰度世界）
        var wbFromDevice = false

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
            if redBlueSwapped { text += "·sw" }
            text += String(format: "·wb%.2f/%.2f", Double(whiteBalanceRed), Double(whiteBalanceBlue))
            text += (wbFromDevice ? "d" : "g")
            text += String(format: "·lv%.2f/%.2f", min(levelRed, 9.99), min(levelBlue, 9.99))
            text += String(format: "·bw%.0f/%.0f", blackLevel, whiteLevel)
            text += "·dev" + patterns[Int(max(0, min(3, devicePattern)))]
            let pl = patternLevels.map { String(format: "%.2f", min($0, 9.99)) }
            text += "·p4" + pl.joined(separator: "/")
            let pg = patternGreen.map { String(format: "%.3f", min($0, 9.999)) }
            text += "·gp" + pg.joined(separator: "/")
            text += String(format: "·tv%.4f", bestVariation)
            if !modeCross.isEmpty {
                // 各排法的相邻差均值，最小者即选中。真实数据上的分离度约 14 倍
                // 三位小数：这些值是归一化到 0–1 的平均相邻差，
                // 正确排法约 0.05、错排 0.7–0.8。用整数格式会全变成 0
                let list = modeCross.map { $0.isFinite ? String(format: "%.3f", min($0, 9.999)) : "x" }
                text += "·cx" + list.joined(separator: "/")
            }
            if !modePeriodicities.isEmpty {
                let list = modePeriodicities.map { String(format: "%.2f", min($0, 9.99)) }
                text += "·p" + list.joined(separator: "/")
            }
            // 每种排法的同色/异色比，留档用
            if !modeRatios.isEmpty {
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

        case 8:     // 8px/12B，低 4 位字节在前
            let g = x >> 3
            let k = x & 7
            let blk = row + g * 12
            let lo = UInt32(blk[k >> 1])
            let nib = (k & 1) == 0 ? (lo >> 4) : (lo & 0x0F)
            return Double((UInt32(blk[4 + k]) << 4) | nib)

        case 9:     // 2px/3B：两个字节各做一个像素的高 8 位，第三个字节装两个低 4 位
            let g = x >> 1
            let blk = row + g * 3
            let b0 = UInt32(blk[0]), b1 = UInt32(blk[1]), b2 = UInt32(blk[2])
            return Double((x & 1) == 0 ? ((b0 << 4) | (b2 >> 4)) : ((b1 << 4) | (b2 & 0x0F)))

        default:    // 10：同 9，两个低 4 位的归属对调
            let g = x >> 1
            let blk = row + g * 3
            let b0 = UInt32(blk[0]), b1 = UInt32(blk[1]), b2 = UInt32(blk[2])
            return Double((x & 1) == 0 ? ((b0 << 4) | (b2 & 0x0F)) : ((b1 << 4) | (b2 >> 4)))
        }
    }

    /// 并列时的固定优先级：9 最优先，其次 10，其余按编号。
    ///
    /// 9 与 10 只差「低 4 位归偶数像素还是奇数像素」，对图像的影响上限
    /// 15/4095 ≈ 0.4%，肉眼不可分。但两者必须固定其一，否则同一场景
    /// 前后两次录制可能各选一个，检查时容易被这 0.4% 误导成"又变了"。
    static func rank(_ mode: Int) -> Int {
        switch mode {
        case 9: return 0
        case 10: return 1
        default: return 2 + mode
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

        /// 相位/白平衡采样的步长。必须是**偶数**：quad 四个位置的
        /// 颜色分配假设 index 0 落在 (偶, 偶)，步长为奇数会让对齐逐次旋转。
        let step = 24

        /// 排法比对的扫描步长，必须是**奇数**。
        ///
        /// 这里踩过一个很隐蔽的坑：打包周期是 8 个像素一组（2px/3B 时
        /// 每 4 组共 12 字节），而步长 24 正好是 8 的整数倍 —— 采样永远落在
        /// 每组第 0、1 个字节上，而那两位在真实格式里恰好都是合法高字节。
        /// 于是 8px/12B 那几种错排也被算成「很平滑」，和正确排法打平：
        ///   step=24 → 0.017 0.018 … 0.017 0.017（mode 0/1/6/9/10 并列）
        ///   step=27 → 0.415 0.417 … 0.018 0.017（只有 9/10 低）
        /// 奇数步长与 8、4、2 都互质，能把所有字节位置都扫到。
        let scanStep = 27

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
        // 判据是「相邻像素总变差」最小：真实场景相邻像素连续，取错字节会
        // 制造大量虚假边缘（画面上就是浮雕）。
        //
        // 早先用的是「同色差 ÷ 异色差」，那个指标有原理性缺陷：它奖励
        // 「异色差大」，而正确排法恰恰让异色差也变小，于是正确排法反而
        // 被判成最差。0.5.18 就是这么选错的。
        //
        // 采样从 step 起步、只取偶数坐标：y = 0 贴着传感器边缘，
        // 前几个像素是无效区（实测会出现 3000 以上的孤立值），拿它当判据会误导。
        var sameDiff = [Double](repeating: 0, count: candidateCount)
        var crossDiff = [Double](repeating: 0, count: candidateCount)
        // 相邻差的平方和。判据用它而不是均值，原因见下面的说明
        var crossSqDiff = [Double](repeating: 0, count: candidateCount)
        var minSample = [Double](repeating: .greatestFiniteMagnitude, count: candidateCount)
        var maxSample = [Double](repeating: 0, count: candidateCount)
        var sampleCount = 0.0

        var sampleY = scanStep
        while sampleY + 2 < height {
            var sampleX = scanStep
            while sampleX + 2 < width {
                for mode in 0..<candidateCount {
                    let center = value(mode, sampleX, sampleY)
                    let right = value(mode, sampleX + 1, sampleY)
                    let down = value(mode, sampleX, sampleY + 1)
                    let toRight = abs(center - right)
                    let toDown = abs(center - down)
                    sameDiff[mode] += abs(center - value(mode, sampleX + 2, sampleY))
                                   + abs(center - value(mode, sampleX, sampleY + 2))
                    crossDiff[mode] += toRight + toDown
                    crossSqDiff[mode] += toRight * toRight + toDown * toDown
                    if center < minSample[mode] { minSample[mode] = center }
                    if center > maxSample[mode] { maxSample[mode] = center }
                }
                sampleCount += 1
                sampleX += scanStep
            }
            sampleY += scanStep
        }

        // 每种排法的同色/异色比，只作为诊断留档
        var ratios = [Double](repeating: .greatestFiniteMagnitude, count: candidateCount)
        for mode in 0..<candidateCount {
            guard crossDiff[mode] > 1e-9 * max(sampleCount, 1) else { continue }
            ratios[mode] = sameDiff[mode] / crossDiff[mode]
        }

        // ---- mod-8 同色位置一致性：只作诊断，不参与选择 ----
        //
        // 这个指标在 8px/12B 那套排法上曾经很有效，但对 2px/3B 完全失效：
        // 2px/3B 的错排会把某个字节的噪声当成高 8 位，而噪声在成千上万个
        // 样本上求均值会收敛到同一个数——四个槽位的均值反而彼此相等，
        // 同色方差被判成 0，于是六种排法并列 0.00，谁也没赢。
        // 0.5.21 的实测就是这么选中 mode 2 的（诊断里 p 全为 0.00）。
        // 留着只为对照历史，决策一律看上面的相邻差。
        var mod8Sums = [[Double]](repeating: [Double](repeating: 0, count: 8), count: candidateCount)
        var mod8Rows = 0.0
        var sampleRow = step
        while sampleRow < height {
            let row = bytes.advanced(by: sampleRow * rowBytes)
            var x = 0
            while x < width {
                let slot = x & 7
                for mode in 0..<candidateCount {
                    mod8Sums[mode][slot] += unpack(row, x, mode: mode)
                }
                x += 1
            }
            mod8Rows += 1
            sampleRow += 60
        }

        var periodicities = [Double](repeating: .greatestFiniteMagnitude, count: candidateCount)
        if mod8Rows > 0 {
            for mode in 0..<candidateCount {
                var means = [Double](repeating: 0, count: 8)
                var overall = 0.0
                for slot in 0..<8 {
                    means[slot] = mod8Sums[mode][slot] / mod8Rows
                    overall += means[slot]
                }
                overall /= 8
                var totalVariance = 0.0
                for slot in 0..<8 {
                    totalVariance += (means[slot] - overall) * (means[slot] - overall)
                }
                guard totalVariance > 1e-12 else { continue }
                var sameColorVariance = 0.0
                for parity in 0..<2 {
                    var groupMean = 0.0
                    for slot in stride(from: parity, to: 8, by: 2) { groupMean += means[slot] }
                    groupMean /= 4
                    for slot in stride(from: parity, to: 8, by: 2) {
                        sameColorVariance += (means[slot] - groupMean) * (means[slot] - groupMean)
                    }
                }
                periodicities[mode] = sameColorVariance / totalVariance
            }
        }

        // ---- 选排法：相邻像素差最小 ----
        //
        // 真实数据给出了明确分离。用 0.5.21 成片里存的原始字节跑全部十一种：
        //
        //   mode 9  = 107      ← 正确（双高字节 + 低位容器）
        //   mode 10 = 110
        //   mode 6  = 458
        //   mode 0/1/7 ≈ 975
        //   mode 8  = 785
        //   mode 3  = 1309
        //   mode 4  = 1349
        //   mode 2  = 1535     ← 0.5.21 实际选中的就是这个
        //
        // 差距 14 倍。原理很直白：错排把某个字节的噪声当成高 8 位，
        // 每两个像素就制造一次上千的跳变，这些跳变在视觉上就是浮雕和条纹。
        // 正确排法下相邻像素只差真实场景的变化量。
        //
        // 这也解释了为什么之前两次在这个指标上失败：0.5.15 用的是
        // 「同色差 ÷ 异色差」，比值里的分母被噪声撑大，正确排法反而吃亏；
        // 0.5.19 换成总变差、0.5.19b 换成 mod-8，都是在合成数据上调的，
        // 而合成数据里没有真实噪声，两种错法的差距被磨平了。
        // 用**均方根**而不是均值，这一处是 0.5.27 失败的根因：
        //
        // 采样是稀疏的整幅扫，暗场景里大片像素扣掉黑电平后是 0，
        // 所有排法在这些点上差值也都是 0。均值把它们算进去，
        // 等于用「一片零」稀释掉真正有信息的高光区——0.5.27 的诊断里
        //   cx = 0.010/0.010/0.308/0.459/0.422/0.773/0.010/0.802/0.484/0.011/0.009
        // 四个排法挤在 0.009-0.011，判据完全失去分辨力。
        //
        // 同一份 512 字节真实数据在 PC 上跑：
        //   均值：mode10=62.6  mode6=897   → 14 倍
        //   均方根：mode10=68.3  mode6=1455 → 21 倍
        // 且均方根对「大片零」免疫：零仍是零，高光区的跳变被放大。
        var crossMeans = [Double](repeating: .greatestFiniteMagnitude, count: candidateCount)
        var crossRms = [Double](repeating: .greatestFiniteMagnitude, count: candidateCount)
        for mode in 0..<candidateCount {
            guard maxSample[mode] - minSample[mode] > 0.02 else { continue }
            let n = max(sampleCount * 2, 1)
            crossMeans[mode] = crossDiff[mode] / n
            crossRms[mode] = (crossSqDiff[mode] / n).squareRoot()
        }

        // 取最优；与最优相差 15% 以内的视为并列。
        // 并列时按固定优先级挑：9 优先于 10——两者只差低 4 位归谁，
        // 对图像的影响上限是 15/4095 ≈ 0.4%，肉眼不可见，但必须固定，
        // 否则同一次录制前后可能来回跳。
        let finite = crossRms.filter { $0 < .greatestFiniteMagnitude }
        var bestMode = 9
        if let low = finite.min() {
            let threshold = low * 1.20
            let tied = (0..<candidateCount).filter { crossRms[$0] <= threshold }
            bestMode = tied.min(by: { rank($0) < rank($1) }) ?? tied.first ?? 9
        }
        let bestVariation = (crossDiff[bestMode] + sameDiff[bestMode]) / max(sampleCount, 1)

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
        // 四种相位各自解出的 R/G、B/G，按 pattern 顺序排：
        // [RGGB_R/G, RGGB_B/G, BGGR_…, GRBG_…, GBRG_…]。
        // 暖光下 R 应当高于 B；哪一组同时满足「R>B 且 G 不是最弱」，
        // 哪一组就是真实相位。设备给的 BayerPattern 和图像统计冲突时，
        // 靠这八个数直接裁决。
        var patternLevels = [Double](repeating: 0, count: 8)
        // 四种相位的「两绿点相对差」。正确相位约 0.002，错族 0.15 以上；
        // 写进容器后，一次录制就能看出相位判据有没有选对。
        var patternGreen = [Double](repeating: 9.99, count: 4)

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
            // 原始（未加增益）的三通道和，用来给每种相位算 R/G、B/G
            var redRaw = 0.0
            var blueRaw = 0.0
            var greenRaw = 0.0
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
                    redRaw += quad[redIndex]
                    blueRaw += quad[blueIndex]
                    greenRaw += (quad[greenA] + quad[greenB]) * 0.5
                    count += 1
                    x += step
                }
                y += step
            }

            guard count > 0 else { continue }
            if greenRaw > 1e-9 {
                patternLevels[pattern * 2] = redRaw / greenRaw
                patternLevels[pattern * 2 + 1] = blueRaw / greenRaw
            }
            let meanLevel = max(greenRaw / count, 1e-6)
            let normalizedPair = greenPair / count

            // 判据必须是**相对量**：两个绿点之差除以画面平均电平。
            //
            // 0.5.30 用的是绝对差 + neutrality 惩罚，在暗画面下彻底失效：
            // 那条片子 raw 只到 861/4095，两绿点差折算成归一化单位只有 0.008，
            // 而 neutrality 是 log 比值、与亮度无关，量级 0.36，乘 0.5 后
            // 完全压过前者 —— 于是选中了把红蓝当绿点的那一族（GBRG），
            // 画面被解成灰的（rgb_mean 55/55/56），这就是"颜色还是错"。
            //
            // 除以平均电平之后，这个量对曝光不敏感：正确相位约为 0.002，
            // 错族约为 0.15 以上，分离度在任何亮度下都成立。
            let relativeGreen = normalizedPair / meanLevel
            patternGreen[pattern] = relativeGreen

            let neutrality = abs(log(max(redSum, 1e-6) / max(blueSum, 1e-6)))
            let score = relativeGreen

            if score < bestPatternScore {
                bestPatternScore = score
                bestPattern = pattern
                bestGreenPair = normalizedPair
                bestNeutrality = neutrality
            }
        }

        // ---- R/B 顺序 ----
        //
        // 「两绿点差」判据对 RGGB 与 BGGR 完全对称（绿点都落在反对角），
        // 也对 GRBG 与 GBRG 对称。也就是说它能定绿点位置，定不了红蓝谁在前。
        // 这件事只有设备驱动知道：同组时采用设备给的 BayerPattern，
        // 跨组冲突时以标定的绿点为准（绿点判据分离度极高，可信）。
        let devicePattern = Int(preferredPattern)
        let greenOnAntiDiagonal = (0...1).contains(bestPattern)
        let deviceOnAntiDiagonal = (0...1).contains(devicePattern)
        if greenOnAntiDiagonal == deviceOnAntiDiagonal, (0...3).contains(devicePattern) {
            bestPattern = devicePattern
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

        var levelR = percentile(samplesR, 0.6)
        var levelG = percentile(samplesG, 0.6)
        var levelB = percentile(samplesB, 0.6)

        // R/B 自检：蓝通道的量子效率是三个里最低的，任何常见光源下
        // raw 的 B 都不该比 R 强三倍以上。出现这种比例，几乎一定是
        // 红蓝相位反了——绿点判据在数学上分不出这两者。
        // pattern ^ 1 正好完成 0↔1（RGGB↔BGGR）与 2↔3（GRBG↔GBRG）的翻转。
        var redBlueSwapped = false
        if levelR > 1e-6, levelB > levelR * 3 {
            bestPattern = bestPattern ^ 1
            swap(&levelR, &levelB)
            redBlueSwapped = true
        }

        // ---- 白平衡：只做部分校正 ----
        //
        // 全量白平衡（把每通道 60% 分位拉到相等）在推导上无懈可击，实拍不对：
        // 它默认「画面平均是中性灰」，于是把暖光下的暖白墙、木色家具一并拉成冷白。
        // 0.5.32 那条片子墙面 B/R 到 1.16、白窗帘发青，根子就在这里。
        //
        // 所以增益按 0.40 次幂收敛：通道失衡 20% 只修 8%，现场暖调留得住；
        // 真偏色（失衡 60% 以上）仍然压得下去。这个指数在真实 RAW 上量过——
        // 暖白墙 B/R 落在 0.92 附近、木桌保持暖棕，观感与 Apple 相机同场景一致。
        //
        // 设备 AWB 增益只在它明确偏离 1 的时候才用（说明当前确实偏色）。
        // 设备在 RAW 通路上经常只回 (1,1,1)，那不是「不用校正」，是「没有数据」，
        // 直接采信等于完全不做白平衡，画面就退回传感器原生的偏色。
        let wbStrength = 0.40
        var whiteBalanceRed: Float = 1
        var whiteBalanceBlue: Float = 1
        var wbFromDevice = false
        let deviceRed = Double(redGain)
        let deviceBlue = Double(blueGain)
        let deviceValid = deviceRed > 0.2 && deviceRed < 5 && deviceBlue > 0.2 && deviceBlue < 5
        let deviceDeviation = max(abs(deviceRed - 1), abs(deviceBlue - 1))
        if deviceValid, deviceDeviation > 0.15 {
            whiteBalanceRed = Float(pow(deviceRed, wbStrength))
            whiteBalanceBlue = Float(pow(deviceBlue, wbStrength))
            wbFromDevice = true
        } else if levelG > 0.003 {
            // 画面太暗时三通道都被噪声主导，算出来的比例没有意义。
            // 但阈值不能定太高：RAW 域的绿通道分位本来就低（这张片子均值
            // 只有 0.026 满量程），按 0.01 卡会把正常场景一并拒掉，
            // 增益停在 1.00/1.00——诊断里的 wb1.00/1.00 就是这么来的。
            if levelR > 1e-6 {
                // 4 倍之外的比例不是白平衡能解释的，多半是通道算错了，别硬拉
                let ratio = min(4.0, max(0.25, levelG / levelR))
                whiteBalanceRed = Float(pow(ratio, wbStrength))
            }
            if levelB > 1e-6 {
                let ratio = min(4.0, max(0.25, levelG / levelB))
                whiteBalanceBlue = Float(pow(ratio, wbStrength))
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
        outcome.redBlueSwapped = redBlueSwapped
        outcome.blackLevel = Double(black)
        outcome.whiteLevel = Double(white)
        outcome.bestVariation = bestVariation
        outcome.modePeriodicities = periodicities
        outcome.modeCross = crossRms
        outcome.patternLevels = patternLevels
        outcome.patternGreen = patternGreen
        outcome.wbFromDevice = wbFromDevice
        return outcome
    }
}
