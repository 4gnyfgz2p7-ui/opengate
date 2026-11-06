import Foundation

enum ReportWriter {

    static func write(_ report: ProbeReport) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return nil }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = Int(Date().timeIntervalSince1970)
        let jsonURL = documents.appendingPathComponent("opengate-probe-\(stamp).json")
        let textURL = documents.appendingPathComponent("opengate-probe-\(stamp).txt")

        do {
            try data.write(to: jsonURL)
        } catch {
            return nil
        }

        if let text = summary(report).data(using: .utf8) {
            try? text.write(to: textURL)
        }

        return jsonURL
    }

    static func summary(_ report: ProbeReport) -> String {
        var lines: [String] = []

        lines.append("OpenGate 探针报告")
        lines.append("生成时间：\(report.generatedAt)")
        lines.append("机型：\(report.device.machineIdentifier)  \(report.device.systemName) \(report.device.systemVersion)")
        lines.append("格式总数：\(report.device.formatCount)")
        lines.append("")

        lines.append("一、结论")
        for verdict in report.verdicts {
            lines.append("[\(tag(verdict.level))] \(verdict.key)：\(verdict.message)")
        }
        lines.append("")

        lines.append("二、编码器")
        for check in report.encoderChecks {
            let dimensions = check.dimensionsPreserved == nil
                ? "无输出"
                : (check.dimensionsPreserved! ? "尺寸保持" : "尺寸被改为 \(check.encodedWidth ?? 0)x\(check.encodedHeight ?? 0)")
            lines.append("\(check.label)  codec=\(check.codecFourCC)  查询=\(check.queryStatus)  会话=\(check.sessionCreateStatus)  \(dimensions)")
            if let profile = check.profileLevelReadback {
                lines.append("    profile：\(profile)")
            }
            if !check.note.isEmpty {
                lines.append("    备注：\(check.note)")
            }
        }
        lines.append("")

        lines.append("三、Writer")
        for check in report.writerChecks {
            lines.append("\(check.label)  canApply=\(check.canApplySettings)  startWriting=\(check.startWriting)  \(check.note)")
        }
        lines.append("")

        lines.append("四、像素格式")
        lines.append("配置格式：\(report.pixelFormatProbe.configuredFormat)")
        lines.append("可用：\(report.pixelFormatProbe.availablePixelFormats.joined(separator: " "))")
        lines.append("Bayer：\(report.pixelFormatProbe.bayerFormats.isEmpty ? "无" : report.pixelFormatProbe.bayerFormats.joined(separator: " "))")
        lines.append("")

        lines.append("五、4:3 视频格式（按面积排序）")
        let candidates = report.formats
            .filter { $0.isVideoCapable && $0.is4x3 }
            .sorted { $0.megapixels > $1.megapixels }
        for format in candidates.prefix(20) {
            let ranges = format.ranges.map { "\(round($0.min))-\(round($0.max))" }.joined(separator: "|")
            lines.append("\(format.width)x\(format.height)  \(format.pixelFormat)  \(ranges) fps  防抖可关=\(format.stabilizationOffSupported)")
        }
        lines.append("")

        lines.append("六、环境")
        lines.append("热状态：\(report.environment.thermalState)  低电量模式：\(report.environment.lowPowerMode)")
        let free = Double(report.environment.availableDiskBytes) / 1_073_741_824
        lines.append(String(format: "可用空间：%.1f GB", free))

        return lines.joined(separator: "\n")
    }

    private static func tag(_ level: Verdict.Level) -> String {
        switch level {
        case .pass: return "通过"
        case .warn: return "注意"
        case .fail: return "不通过"
        case .unknown: return "未知"
        }
    }
}
