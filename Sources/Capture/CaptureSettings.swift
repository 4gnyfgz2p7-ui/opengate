import Foundation
import AVFoundation
import CoreMedia

/// 四档定义。
///
/// 四档共用同一份全幅画面：切档只改末端编码器、色度、GOP，
/// 不改画幅、不改几何、不改帧率。
///
/// 体积量级实测预期（按 4224×3024 @ 24 fps 推算）：
/// HQ ≈ 136 MB/s ＞ LT ≈ 95 MB/s ≳ Plan B（All-Intra HEVC）＞ Plan A（长 GOP HEVC）。
/// 注意档 2 的体积小于档 3，与枚举顺序相反——这是编码结构决定的，不是笔误。
enum QualityTier: String, CaseIterable, Identifiable, Codable {
    case proResHQ
    case hevcLongGOP
    case hevcAllIntra
    case proResLT

    var id: String { rawValue }

    // MARK: - 显示

    /// 任务书编号，写进元数据便于对齐文档
    var identifier: String {
        switch self {
        case .proResHQ: return "档1-HQ"
        case .hevcLongGOP: return "档2-PlanA"
        case .hevcAllIntra: return "档3-PlanB"
        case .proResLT: return "档4-LT"
        }
    }

    var displayName: String {
        switch self {
        case .proResHQ: return "档 1 · HQ"
        case .hevcLongGOP: return "档 2 · Plan A"
        case .hevcAllIntra: return "档 3 · Plan B"
        case .proResLT: return "档 4 · LT"
        }
    }

    var subtitle: String {
        switch self {
        case .proResHQ: return "ProRes 422 HQ · 10-bit 4:2:2 · 全 I 帧"
        case .hevcLongGOP: return "HEVC Main10 · 10-bit 4:2:0 · 长 GOP"
        case .hevcAllIntra: return "HEVC Main10 · 10-bit 4:2:0 · 全 I 帧"
        case .proResLT: return "ProRes 422 LT · 10-bit 4:2:2 · 全 I 帧"
        }
    }

    var roleDescription: String {
        switch self {
        case .proResHQ: return "调色母版"
        case .hevcLongGOP: return "最小体积 · 录得最久"
        case .hevcAllIntra: return "逐帧可剪"
        case .proResLT: return "ProRes 瘦身档"
        }
    }

    var isProRes: Bool {
        self == .proResHQ || self == .proResLT
    }

    var isHEVC: Bool {
        self == .hevcLongGOP || self == .hevcAllIntra
    }

    // MARK: - 编码

    var codec: AVVideoCodecType {
        switch self {
        case .proResHQ: return .proRes422HQ
        case .proResLT: return .proRes422LT
        case .hevcLongGOP, .hevcAllIntra: return .hevc
        }
    }

    var codecName: String {
        switch self {
        case .proResHQ: return "proRes422HQ"
        case .proResLT: return "proRes422LT"
        case .hevcLongGOP, .hevcAllIntra: return "hevc"
        }
    }

    var gopDescription: String {
        switch self {
        case .proResHQ, .proResLT, .hevcAllIntra: return "all-intra"
        case .hevcLongGOP: return "long-gop"
        }
    }

    /// 关键帧间隔（帧数）。ProRes 是全 I 帧结构，不适用该参数，返回 nil。
    var maxKeyFrameInterval: Int? {
        switch self {
        case .proResHQ, .proResLT: return nil
        case .hevcAllIntra: return 1
        // 10 秒一个 I 帧 @24 fps
        case .hevcLongGOP: return 240
        }
    }

    /// HEVC 目标码率。ProRes 走固定质量档，不设码率，返回 nil。
    var averageBitRate: Int? {
        switch self {
        case .proResHQ, .proResLT: return nil
        case .hevcLongGOP: return 200_000_000
        case .hevcAllIntra: return 500_000_000
        }
    }

    /// 预估写入速率（MB/s），用于界面提示与剩余空间估算。
    /// 依据：ProRes 422 HQ 约 3.54 bit/像素（Apple ProRes 白皮书 1080p29.97 = 220 Mbps 反推）；
    /// HEVC 按设定码率折算。
    var estimatedMegabytesPerSecond: Double {
        switch self {
        case .proResHQ: return 135
        case .proResLT: return 95
        case .hevcLongGOP: return Double(averageBitRate ?? 0) / 8.0 / 1000.0
        case .hevcAllIntra: return Double(averageBitRate ?? 0) / 8.0 / 1000.0
        }
    }

    var fileExtension: String { "mov" }

    /// 四档统一 .mov。
    /// .mp4 容器对自定义元数据键会静默丢弃，而位置正是通过自定义键写入的；
    /// ProRes 本身也只能装进 QuickTime 容器。
    var fileType: AVFileType { .mov }
}

// MARK: - 视频输出设置

enum VideoSettingsBuilder {

    /// 帧率锁死，不给 UI 暴露选项
    static let frameRate: Int = 24

    /// `AVVideoLogTransferFunctionKey` 与其取值目前只在 iOS 26 SDK 有符号；
    /// 这里用字符串字面量，避免 SDK 版本差异导致编译失败。
    /// 键名与 Apple 的常量同名，运行时若系统不识别会被忽略，不会破坏文件。
    private static let logTransferFunctionKey = "AVVideoLogTransferFunctionKey"
    private static let logTransferFunctionAppleLog2 = "AppleLog2"

    /// 组装 AVAssetWriterInput 的 videoSettings。
    ///
    /// - Parameters:
    ///   - tier: 四档之一
    ///   - width: 全幅宽度（4224）
    ///   - height: 全幅高度（3024）
    ///   - appleLog2: 是否写入 Apple Log 2 的 Log 传输函数标记
    static func videoSettings(
        tier: QualityTier,
        width: Int,
        height: Int,
        appleLog2: Bool
    ) -> [String: Any] {

        var settings: [String: Any] = [
            AVVideoCodecKey: tier.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: colorProperties(appleLog2: appleLog2),
            AVVideoExpectedSourceFrameRateKey: frameRate,
        ]

        // 明确要求不做帧重排：锁 24 fps 且要求时间戳精确，重排会引入解码时序偏差
        settings[AVVideoAllowFrameReorderingKey] = false

        if let bitRate = tier.averageBitRate {
            settings[AVVideoAverageBitRateKey] = bitRate
        }

        if let interval = tier.maxKeyFrameInterval {
            // 以帧数计，不是秒；不设 Duration 键，两者互斥
            settings[AVVideoMaxKeyFrameIntervalKey] = interval
        }

        if tier.isHEVC {
            settings[AVVideoProfileLevelKey] = hevcProfileLevel
        }

        if appleLog2 {
            // 与 AVVideoColorPropertiesKey 平级，不嵌在 colorProperties 里
            settings[logTransferFunctionKey] = logTransferFunctionAppleLog2
        }

        return settings
    }

    static let hevcProfileLevel = "HEVC_Main10_AutoLevel"

    /// 色彩标记。
    ///
    /// Apple Log 2 的原色是 Apple Gamut（比 BT.2020 更宽），但 AVFoundation 没有
    /// 公开的 `AVVideoColorPrimaries_AppleGamut` 常量。这里写 BT.2020 作为可被
    /// 主流 NLE 正确识别的近似标记，真实色彩空间另用自定义元数据键记录。
    ///
    /// 这是已知偏差，验证方式是导入 DaVinci 后看 Color Space 识别结果。
    static func colorProperties(appleLog2: Bool) -> [String: Any] {
        if appleLog2 {
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
        // 过渡期（系统 ISP 输出的 SDR 画面）
        return [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
    }

    static var colorPipelineDescription: String {
        "AppleLog2 · Apple Gamut(标记为 BT.2020) · 10-bit 4:2:2/4:2:0"
    }
}

// MARK: - 音频输出设置

enum AudioSettings {

    static let sampleRate: Double = 48_000
    static let bitDepth: Int = 16
    static let channelCount: Int = 2

    /// 采集侧：要求 AVCaptureAudioDataOutput 直接吐 LPCM，
    /// 避免先压 AAC 再由 writer 解压，白白多一轮有损。
    static var captureSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// 写入侧：同样是 LPCM。源与目标格式一致时 AVAssetWriter 直通，
    /// 不发生任何重采样或再量化。
    static var writerSettings: [String: Any] {
        captureSettings
    }

    static var description: String {
        "LPCM \(Int(sampleRate / 1000)) kHz / \(bitDepth)-bit / \(channelCount) ch"
    }

    /// 音频大小估算（字节/秒）：48000 × 2ch × 2B = 192 000 B/s
    static var bytesPerSecond: Double {
        sampleRate * Double(channelCount) * Double(bitDepth / 8)
    }
}
