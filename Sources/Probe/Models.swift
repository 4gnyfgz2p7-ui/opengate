import Foundation
import CoreMedia
import Darwin

// MARK: - 结论

struct Verdict: Codable {
    enum Level: String, Codable {
        case pass
        case warn
        case fail
        case unknown
    }

    var key: String
    var level: Level
    var message: String
}

// MARK: - 设备与环境

struct DeviceInfo: Codable {
    var machineIdentifier: String
    var systemName: String
    var systemVersion: String
    var deviceName: String
    var cameraCount: Int
    var formatCount: Int
    var activeFormat: String
    var maxPhotoDimensions: String?
}

struct EnvironmentInfo: Codable {
    var thermalState: String
    var lowPowerMode: Bool
    var availableDiskBytes: Int64
    var totalDiskBytes: Int64
    var physicalMemoryBytes: Int64
    var processorCount: Int
}

// MARK: - 格式

struct FrameRateRangeInfo: Codable {
    var min: Double
    var max: Double
    var minDurationSeconds: Double
    var maxDurationSeconds: Double
}

struct FormatInfo: Codable {
    var index: Int
    var width: Int32
    var height: Int32
    var pixelFormat: String
    var isVideoCapable: Bool
    var is4x3: Bool
    var isOpenGateCandidate: Bool
    var megapixels: Double
    var ranges: [FrameRateRangeInfo]
    var supports24: Bool
    var maxFrameRate: Double
    var stabilizationOffSupported: Bool
}

// MARK: - 像素格式

struct PixelFormatProbe: Codable {
    var configuredFormat: String
    var availablePixelFormats: [String]
    var bayerFormats: [String]
    var has10Bit420: Bool
    var has8Bit420: Bool
    var hasBGRA: Bool
    var note: String
}

// MARK: - 编码器

struct EncoderCheck: Codable {
    var label: String
    var codecFourCC: String
    var width: Int32
    var height: Int32
    var queryStatus: Int32
    var queryOK: Bool
    var sessionCreateStatus: Int32
    var sessionCreated: Bool
    var profileSetStatus: Int32
    var realTimeSetStatus: Int32
    var encodeStatus: Int32
    var framesEmitted: Int
    var encodedWidth: Int32?
    var encodedHeight: Int32?
    var dimensionsPreserved: Bool?
    var profileLevelReadback: String?
    var note: String
}

// MARK: - Writer

struct WriterCheck: Codable {
    var label: String
    var codec: String
    var width: Int
    var height: Int
    var writerCreateStatus: Int32
    var canApplySettings: Bool
    var startWriting: Bool
    var note: String
}

// MARK: - 报告

struct ProbeReport: Codable {
    var schemaVersion: Int
    var appVersion: String
    var generatedAt: String
    var device: DeviceInfo
    var environment: EnvironmentInfo
    var formats: [FormatInfo]
    var pixelFormatProbe: PixelFormatProbe
    var encoderChecks: [EncoderCheck]
    var writerChecks: [WriterCheck]
    var frameRateCheck: FrameRateCheck? = nil
    var liveCapture: LiveCaptureResult? = nil
    var verdicts: [Verdict]
    var steps: [String]
}

// MARK: - Phase 2：真机实测

struct FrameRateCheck: Codable {
    var requestedSeconds: Double
    var actualValue: Int64
    var actualTimescale: Int32
    var actualSeconds: Double
    var isExact24: Bool
    var isNTSC23976: Bool
    var setStatus: String
    var rangeMin: Double
    var rangeMax: Double
    var rangeMinDurationSeconds: Double
}

struct FrameStructure: Codable {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var planeCount: Int
    var pixelFormat: String
    var dataSizeBytes: Int
    var expectedBytesPerRowFor12Bit: Int
    var matchesExpectedLayout: Bool
    var bayerBitDepth: Int?
}

struct LiveCaptureResult: Codable {
    var sessionStarted: Bool
    var framesReceived: Int
    var captureWallSeconds: Double
    var measuredFPS: Double
    var intervalMinMS: Double
    var intervalMaxMS: Double
    var intervalAvgMS: Double
    var structure: FrameStructure?
    var sampleBufferAttachmentKeys: [String]
    var pixelBufferAttachmentKeys: [String]
    var formatDescriptionExtensionKeys: [String]
    var note: String
}

// MARK: - 工具

enum FourCC {
    /// 由四字符码构造 OSType，避免依赖特定 SDK 版本才有的像素格式常量。
    static func code(_ text: String) -> OSType {
        var result: OSType = 0
        for byte in text.utf8.prefix(4) {
            result = (result << 8) + OSType(byte)
        }
        return result
    }

    static func string(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return String(bytes: bytes, encoding: .ascii) ?? "????"
        }
        return String(format: "0x%08X", code)
    }

    static func isBayer(_ code: FourCharCode) -> Bool {
        let s = string(code).lowercased()
        // btp2 = kCVPixelFormatType_96VersatileBayerPacked12（ProRes RAW 采集格式，12-bit packed）
        // bp16 = kCVPixelFormatType_16VersatileBayer
        // bp64 = kCVPixelFormatType_64RGBA_DownscaledProResRAW
        if s == "btp2" || s == "bp16" || s == "bp64" { return true }
        return s.hasSuffix("ba") || s.contains("bayer") || s.hasSuffix("b4")
    }

    static func bayerBitDepth(_ code: FourCharCode) -> Int? {
        switch string(code).lowercased() {
        case "btp2": return 12
        case "bp16": return 16
        case "14ba": return 14
        case "12ba": return 12
        case "10ba": return 10
        default: return nil
        }
    }

    static func is10Bit(_ code: FourCharCode) -> Bool {
        let s = string(code).lowercased()
        return s.contains("10") || s == "x420" || s == "xf20" || s == "x422"
    }
}

struct StepRecorder {
    private(set) var steps: [String] = []
    private let onStep: (String) -> Void

    init(onStep: @escaping (String) -> Void) {
        self.onStep = onStep
    }

    mutating func log(_ message: String) {
        let stamped = message
        steps.append(stamped)
        // 同步落盘：闪退后重新打开就能看到最后走到哪一步
        Diagnostics.mark(stamped)
        onStep(stamped)
    }
}

func isoNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

func machineIdentifier() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafePointer(to: &info.machine) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 1) { charPointer in
            String(cString: charPointer)
        }
    }
}
