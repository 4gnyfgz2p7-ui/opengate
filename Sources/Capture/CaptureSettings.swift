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
    /// 原始 Bayer 直录：不 demosaic，字节原样进容器，解码交给
    /// Apple 的 ProRes RAW 解码器（Final Cut / DaVinci）
    case proResRAW

    var id: String { rawValue }

    // MARK: - 显示

    /// 写进元数据的稳定标识
    var identifier: String {
        switch self {
        case .hevcLongGOP: return "hevc-long-gop"
        case .hevcAllIntra: return "hevc-all-intra"
        case .proResLT: return "prores422lt"
        case .proResHQ: return "prores422hq"
        case .proResRAW: return "proresraw"
        }
    }

    var displayName: String {
        switch self {
        case .hevcLongGOP: return "HEVC 长 GOP"
        case .hevcAllIntra: return "HEVC 全 I 帧"
        case .proResLT: return "ProRes 422 LT"
        case .proResHQ: return "ProRes 422 HQ"
        case .proResRAW: return "ProRes RAW"
        }
    }

    var subtitle: String {
        switch self {
        case .hevcLongGOP: return "10-bit 4:2:0 · 长 GOP"
        case .hevcAllIntra: return "10-bit 4:2:0 · 全 I 帧"
        case .proResLT: return "10-bit 4:2:2 · 全 I 帧"
        case .proResHQ: return "10-bit 4:2:2 · 全 I 帧"
        case .proResRAW: return "12-bit Bayer · 未解码"
        }
    }

    var roleDescription: String {
        switch self {
        case .hevcLongGOP: return "体积最小，录得最久"
        case .hevcAllIntra: return "逐帧可剪，体积居中"
        case .proResLT: return "ProRes 轻量档"
        case .proResHQ: return "调色母版"
        case .proResRAW: return "后期软件自行解码"
        }
    }

    var isProRes: Bool {
        self == .proResHQ || self == .proResLT
    }

    var isHEVC: Bool {
        self == .hevcLongGOP || self == .hevcAllIntra
    }

    /// 原始 Bayer 直录。解码不在本机做，因此不受 btp2 排法影响。
    var isRawBayer: Bool { self == .proResRAW }

    // MARK: - 编码

    var codec: AVVideoCodecType {
        switch self {
        case .proResHQ: return .proRes422HQ
        case .proResLT: return .proRes422LT
        case .hevcLongGOP, .hevcAllIntra: return .hevc
        case .proResRAW: return .proResRawCompat
        }
    }

    var codecName: String {
        switch self {
        case .proResHQ: return "proRes422HQ"
        case .proResLT: return "proRes422LT"
        case .hevcLongGOP, .hevcAllIntra: return "hevc"
        case .proResRAW: return "proResRAW"
        }
    }

    var gopDescription: String {
        switch self {
        case .proResHQ, .proResLT, .hevcAllIntra, .proResRAW: return "all-intra"
        case .hevcLongGOP: return "long-gop"
        }
    }

    /// 关键帧间隔（帧数）。ProRes 是全 I 帧结构，不适用该参数，返回 nil。
    var maxKeyFrameInterval: Int? {
        switch self {
        case .proResHQ, .proResLT, .proResRAW: return nil
        case .hevcAllIntra: return 1
        // 10 秒一个 I 帧 @24 fps
        case .hevcLongGOP: return 240
        }
    }

    /// HEVC 目标码率。ProRes 走固定质量档，不设码率，返回 nil。
    ///
    /// 数值按**每像素多少 bit** 折算，不按「感觉画质高」拍脑袋定。
    /// 4224×3024 @24fps = 306 M像素/秒，于是：
    ///   45 Mb/s ÷ 306 M = 0.147 bit/像素（长 GOP）
    ///   90 Mb/s ÷ 306 M = 0.294 bit/像素（全 I 帧，2 倍）
    ///
    /// 参照是 Apple 相机：3840×2160@24 的 H.264 是 12.4 Mb/s = 0.062 bit/像素。
    /// 但那是 H.264、而且 Apple 的编码器在高感场景会主动降码率。
    /// 全幅 4224×3024 的细节量比 4K 多 1.54 倍，实测 20 Mb/s 在纹理密集处
    /// 已经能看出块效应，所以长 GOP 拉到 45 Mb/s（日常实际落在 30–50 区间），
    /// 全 I 帧翻倍到 90 Mb/s——它每一帧都是关键帧，没有帧间冗余可省。
    ///
    /// 更早还写过 200 / 500 Mb/s（0.65 / 1.63 bit/像素），两个数都离谱：
    /// - 长 GOP 1.48 GB/分钟，比 iPhone 大 3 倍，「最小文件档」名不副实；
    /// - 全 I 帧 500 Mb/s 与 ProRes 422 LT 换算后的 503 Mb/s 几乎相等，
    ///   两档文件一样大，而 LT 是调色中间格式、画质更好——
    ///   那一档在阶梯里的位置等于白占。
    var averageBitRate: Int? {
        switch self {
        case .proResHQ, .proResLT, .proResRAW: return nil
        case .hevcLongGOP: return 45_000_000
        case .hevcAllIntra: return 90_000_000
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
        // 4224×3024 12-bit @24fps 裸数据约 458 MB/s，ProRes RAW 压缩后按 2:1 估
        case .proResRAW: return 230
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

        // ProRes RAW 存的是未解码的 Bayer，没有色彩空间可标，
        // 也不接受压缩属性——带上任何一项都会被 canAdd 拒绝。
        if tier.isRawBayer {
            return [
                AVVideoCodecKey: AVVideoCodecType.proResRawCompat,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        }

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
            // 最裸的 ProRes 请求：只要编码器与尺寸。
            // HEVC 与 ProRes RAW 不降到 422 LT：前者编码器不同，
            // 后者压根不是 YUV 通路，降过去等于悄悄换了档位。
            if tier.isHEVC || tier.isRawBayer {
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
    /// 传输函数**不能写 HLG**。早先那一版写的是
    /// `AVVideoTransferFunction_ITU_R_2100_HLG`，理由是"Log 曲线没有标准编码，
    /// 挑一个宽色域的非线性函数凑上去"——这是错的：HLG 是显示参考曲线，
    /// 播放器会按 HDR 通路做 OOTF 和 tone mapping，画面会被重新映射一遍，
    /// 表现为高光变白、中间调偏色。Apple Log 2 的官方容器写法是
    /// `colr = 9 / 2 / 9`（transfer 为 *unspecified*），AVFoundation 没有
    /// unspecified 常量，退到 BT.709 最接近"不做变换"。
    /// 真正的 Log 身份靠 `AVVideoLogTransferFunctionKey` 表达。
    static func colorProperties(appleLog2: Bool) -> [String: Any] {
        if appleLog2 {
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
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

// MARK: - ProRes RAW 编解码器

extension AVVideoCodecType {
    /// `AVVideoCodecType.proResRAW` 这个符号 iOS 26 才公开，而本工程的
    /// deployment target 是 17.0，直接写常量编译不过。
    ///
    /// 编解码器在容器里就是 FourCC，值本身是稳定的，用原始值构造即可：
    /// 系统不认识时有 `canApply` 会把它挡下来，不会静默写坏文件。
    static let proResRawCompat = AVVideoCodecType(rawValue: "aprn")
}
