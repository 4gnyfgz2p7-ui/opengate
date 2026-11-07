import Foundation
import AVFoundation
import CoreLocation
import UIKit

/// 组装写入 .mov 文件头的元数据。
///
/// 三条硬约束，任何一条不满足位置就**静默丢失**（不报错、文件照常）：
/// 1. 只能在 `AVAssetWriter.startWriting()` 之前赋给 `writer.metadata`；
/// 2. 容器必须是 `.mov`——`.mp4` 对自定义键会静默丢弃；
/// 3. `identifier` 与 `dataType` 必须成对匹配，否则该条目被忽略。
enum MovieMetadata {

    // MARK: - 位置

    /// ISO 6709 字符串，Apple 官方 AVCaptureLocation 示例采用的格式。
    /// 例：`+39.9042+116.4074/`；带海拔时为 `+39.9042+116.4074+43.500/`。
    static func iso6709(
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil
    ) -> String {
        var text = String(format: "%+08.4lf%+09.4lf", latitude, longitude)
        if let altitude = altitude {
            text += String(format: "%+.3lf", altitude)
        }
        return text + "/"
    }

    static func locationItem(_ fix: LocationProvider.Fix) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataLocationISO6709
        item.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String
        item.value = iso6709(
            latitude: fix.latitude,
            longitude: fix.longitude,
            altitude: fix.altitude
        ) as NSString
        return item
    }

    /// 位置精度与来源，方便后期判断这条位置能不能用来对轨。
    static func locationAccuracyItem(_ fix: LocationProvider.Fix) -> AVMutableMetadataItem {
        var parts = [String(format: "h_accuracy_m=%.1f", fix.horizontalAccuracy)]
        parts.append("source=\(fix.isCached ? "cached" : "live")")
        parts.append("reduced_accuracy=\(fix.isReducedAccuracy ? 1 : 0)")
        parts.append("fix_time=\(timestampFormatter.string(from: fix.timestamp))")
        return customItem(key: "com.aitimes.acamera.location", value: parts.joined(separator: ";"))
    }

    // MARK: - 通用

    static func creationDateItem(_ date: Date = Date()) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataCreationDate
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = timestampFormatter.string(from: date) as NSString
        return item
    }

    static func modelItem() -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataModel
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = hardwareIdentifier() as NSString
        return item
    }

    static func makeItem() -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataMake
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = "Apple" as NSString
        return item
    }

    static func softwareItem(version: String) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataSoftware
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = "A camera \(version)" as NSString
        return item
    }

    /// 自定义键：写入档位、色彩管线、帧率等工程参数，
    /// 后期在 ffprobe / MediaInfo 里能直接看出这条素材是哪个档。
    static func customItem(key: String, value: String) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        if let identifier = AVMetadataItem.identifier(forKey: key, keySpace: .quickTimeMetadata) {
            item.identifier = identifier
        } else {
            item.keySpace = .quickTimeMetadata
            item.key = key as NSString
        }
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = value as NSString
        return item
    }

    // MARK: - 汇总

    struct RecordingContext {
        let tier: QualityTier
        let width: Int
        let height: Int
        let frameRate: Int
        let colorPipeline: String
        let audioDescription: String
        let locationOutcome: LocationProvider.Outcome
        let startedAt: Date
        let orientation: String
    }

    static func items(for context: RecordingContext) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        items.append(creationDateItem(context.startedAt))
        items.append(makeItem())
        items.append(modelItem())
        items.append(softwareItem(version: appVersion()))

        // 位置：只有确实拿到 fix 才写，拿不到就不写，不写空串
        if let fix = context.locationOutcome.fix {
            items.append(locationItem(fix))
            items.append(locationAccuracyItem(fix))
        }

        items.append(customItem(key: "com.aitimes.acamera.tier", value: context.tier.identifier))
        items.append(customItem(key: "com.aitimes.acamera.codec", value: context.tier.codecName))
        items.append(customItem(key: "com.aitimes.acamera.gop", value: context.tier.gopDescription))
        items.append(customItem(
            key: "com.aitimes.acamera.frame_size",
            value: "\(context.width)x\(context.height)"
        ))
        items.append(customItem(
            key: "com.aitimes.acamera.frame_rate",
            value: "\(context.frameRate)"
        ))
        items.append(customItem(key: "com.aitimes.acamera.color_pipeline", value: context.colorPipeline))
        items.append(customItem(key: "com.aitimes.acamera.audio", value: context.audioDescription))
        items.append(customItem(key: "com.aitimes.acamera.orientation", value: context.orientation))

        return items
    }

    // MARK: - 工具

    private static var timestampFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        return formatter
    }

    /// 机型标识，如 `iPhone18,2`。写进元数据便于区分素材来源机位。
    private static func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partial.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }

    private static func appVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version)(\(build))"
    }
}
