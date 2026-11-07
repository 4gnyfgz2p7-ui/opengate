import Foundation
import AVFoundation
import CoreMedia

/// 四档定义，按写入码率从低到高排列。
///
/// 四档共用同一份全幅画面：切档只改末端编码器、色度、GOP，
/// 不改画幅、不改几何、不改帧率。
///
/// 命名直接用编码名称，不用"档 1 / Plan A"这类编号——
/// 编号在切换、归档、对文档时都要回查对照表，编码名称自带含义。
enum QualityTier: String, CaseIterable, Identifiable, Codable {
    case hevcLongGOP
    case hevcAllIntra
    case proResLT
    case proResHQ

    var id: String { rawValue }

    // MARK: - 显示

    /// 写进元数据的稳定标识
    var identifier: String {
        switch self {
        case .hevcLongGOP: return "hevc-long-gop"
        case .hevcAllIntra: return "hevc-all-intra"
        case .proResLT: return "prores422lt"
        case .proResHQ: return "prores422hq"
        }
    }

    var displayName: String {
        switch self {
        case .hevcLongGOP: return "HEVC 长 GOP"
        case .hevcAllIntra: return "HEVC 全 I 帧"
        case .proResLT: return "ProRes 422 LT"
        case .proResHQ: return "ProRes 422 HQ"
        }
    }

    var subtitle: String {
        switch self {
        case .hevcLongGOP: return "10-bit 4:2:0 · 长 GOP"
        case .hevcAllIntra: return "10-bit 4:2:0 · 全 I 帧"
        case .proResLT: return "10-bit 4:2:2 · 全 I 帧"
        case .proResHQ: return "10-bit 4:2:2 · 全 I 帧"
        }
    }

    var roleDescription: String {
        switch self {
        case .hevcLongGOP: return "体积最小，录得最久"
        case .hevcAllIntra: return "逐帧可剪，体积居中"
        case .proResLT: return "ProRes 轻量档"
        case .proResHQ: return "调色母版"
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

    /// 预估写入速率（MB/s）。
    ///
    /// 单位必须统一为 MB/s。旧实现里 HEVC 返回的是 KB/s（少除一个 1000），
    /// 而空间检查按 MB 乘 1e6，需求被放大一千倍——
    /// 于是 94 GB 可用空间被判成"需要 22.5 TB"而拒绝开录。
    var estimatedMegabytesPerSecond: Double {
        if let bitRate = averageBitRate {
            return Double(bitRate) / 8.0 / 1_000_000.0
        }
        switch self {
        case .proResHQ: return 135
        case .proResLT: return 95
        default: return 0
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

        // 码率、GOP、profile 这些**必须**放进 AVVideoCompressionPropertiesKey，
        // 放顶层不会被报错，但 AVAssetWriter 会在 canAdd 阶段直接拒绝输入，
        // 表现为"写入器不接受该档的视频参数"。
        var compression: [String: Any] = [:]

        if let bitRate = tier.averageBitRate {
            compression[AVVideoAverageBitRateKey] = bitRate
        }
        if let interval = tier.maxKeyFrameInterval {
            // 以帧数计，不是秒；不设 Duration 键，两者互斥
            compression[AVVideoMaxKeyFrameIntervalKey] = interval
        }
        if tier.isHEVC {
            compression[AVVideoProfileLevelKey] = hevcProfileLevel
        }
        compression[AVVideoExpectedSourceFrameRateKey] = frameRate
        // 锁 24 fps 且要求时间戳精确，帧重排会引入解码时序偏差
        compression[AVVideoAllowFrameReorderingKey] = false

        var settings: [String: Any] = [
            AVVideoCodecKey: tier.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: colorProperties(appleLog2: appleLog2),
            AVVideoCompressionPropertiesKey: compression,
        ]

        if appleLog2 {
            // 与 AVVideoColorPropertiesKey 平级，不嵌进 compression
            settings[logTransferFunctionKey] = logTransferFunctionAppleLog2
        }

        return settings
    }

    /// 逐级降级的备选设置。
    ///
    /// 首选项被写入器拒绝时按顺序试，直到能录为止：
    /// 宁可少一个码率约束，也不要整档录不了。
    static func fallbackSettings(
        tier: QualityTier,
        width: Int,
        height: Int,
        appleLog2: Bool,
        level: Int
    ) -> [String: Any]? {
        switch level {
        case 0:
            return videoSettings(tier: tier, width: width, height: height, appleLog2: appleLog2)

        case 1:
            // 去掉码率与 GOP，交给编码器自选
            return [
                AVVideoCodecKey: tier.codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: colorProperties(appleLog2: appleLog2),
            ]

        case 2:
            // 连色彩标记也去掉
            return [
                AVVideoCodecKey: tier.codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]

        case 3:
            // 最裸的 ProRes 请求：只要编码器与尺寸
            if tier.isHEVC {
                return nil
            }
            return [
                AVVideoCodecKey: AVVideoCodecType.proRes422LT,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]

        default:
            return nil
        }
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
