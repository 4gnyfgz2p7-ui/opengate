import SwiftUI
import AVFoundation
import UIKit

// MARK: - 状态模型

@MainActor
final class ProbeModel: ObservableObject {
    @Published var isRunning = false
    @Published var steps: [String] = []
    @Published var report: ProbeReport?
    @Published var reportURL: URL?
    @Published var statusText = "待运行"
    @Published var permissionDenied = false

    func run() {
        guard !isRunning else { return }
        isRunning = true
        steps = []
        report = nil
        reportURL = nil
        permissionDenied = false
        statusText = "请求相机权限"

        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                self.isRunning = false
                self.permissionDenied = true
                self.statusText = "相机权限被拒绝"
                return
            }

            self.statusText = "探测中"

            let result = await Task.detached(priority: .userInitiated) { () -> ProbeReport in
                ProbeEngine.run(onStep: { _ in })
            }.value

            self.steps = result.steps
            self.report = result
            self.reportURL = ReportWriter.write(result)
            self.isRunning = false

            let failures = result.verdicts.filter { $0.level == .fail }.count
            let warnings = result.verdicts.filter { $0.level == .warn }.count
            self.statusText = "完成：\(failures) 项不通过，\(warnings) 项需注意"
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @StateObject private var model = ProbeModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    Button(action: { model.run() }) {
                        HStack(spacing: 8) {
                            if model.isRunning {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.black)
                            }
                            Text(model.isRunning ? "探测中" : "运行探测")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(model.isRunning ? Color(white: 0.6) : Color.white)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(model.isRunning)

                    Text(model.statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if model.permissionDenied {
                        Text("请在「设置 → OpenGate → 相机」中开启权限后重试。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    if let report = model.report {
                        verdictCard(report)

                        if let url = model.reportURL {
                            ShareLink(item: url) {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("导出 JSON 报告")
                                }
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Color(white: 0.17))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }

                        deviceCard(report)
                        encoderCard(report)
                        liveCard(report)
                        formatCard(report)
                    }

                    if !model.steps.isEmpty {
                        logCard
                    }
                }
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("A camera")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("全幅 4:3 · Apple Log 2 · 24fps")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("能力探测：格式枚举、Bayer 可得性、HEVC 分辨率天花板、ProRes 与 writer 接受度")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 结论

    private func verdictCard(_ report: ProbeReport) -> some View {
        Card(title: "结论") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(report.verdicts.enumerated()), id: \.offset) { _, verdict in
                    VerdictRow(verdict: verdict)
                }
            }
        }
    }

    // MARK: 设备

    private func deviceCard(_ report: ProbeReport) -> some View {
        Card(title: "设备") {
            VStack(alignment: .leading, spacing: 6) {
                KeyValueRow(key: "机型", value: report.device.machineIdentifier)
                KeyValueRow(key: "系统", value: "\(report.device.systemName) \(report.device.systemVersion)")
                KeyValueRow(key: "格式总数", value: "\(report.device.formatCount)")
                KeyValueRow(key: "当前格式", value: report.device.activeFormat)
                KeyValueRow(key: "热状态", value: report.environment.thermalState)
                KeyValueRow(key: "低电量模式", value: report.environment.lowPowerMode ? "开" : "关")
                KeyValueRow(
                    key: "可用空间",
                    value: String(format: "%.1f GB", Double(report.environment.availableDiskBytes) / 1_073_741_824)
                )
            }
        }
    }

    // MARK: 编码器

    private func encoderCard(_ report: ProbeReport) -> some View {
        Card(title: "编码器") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(report.encoderChecks.enumerated()), id: \.offset) { _, check in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(check.label)
                                .font(.caption.monospaced())
                                .foregroundStyle(.white)
                            Spacer()
                            Text(check.dimensionsPreserved == true ? "尺寸保持"
                                 : (check.dimensionsPreserved == false ? "尺寸被改" : "无输出"))
                                .font(.caption2)
                                .foregroundStyle(check.dimensionsPreserved == true ? .green : .red)
                        }
                        Text("查询 \(check.queryStatus) · 会话 \(check.sessionCreateStatus) · 帧 \(check.framesEmitted)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        if let width = check.encodedWidth, let height = check.encodedHeight {
                            Text("实际输出 \(width)x\(height)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if !check.note.isEmpty {
                            Text(check.note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if check.label != report.encoderChecks.last?.label {
                        Divider().overlay(Color(white: 0.22))
                    }
                }
            }
        }
    }

    // MARK: 格式

    private func liveCard(_ report: ProbeReport) -> some View {
        Card(title: "Phase 2 实测") {
            VStack(alignment: .leading, spacing: 6) {
                if let rate = report.frameRateCheck {
                    KeyValueRow(key: "帧率回读", value: rate.setStatus)
                } else {
                    Text("未执行帧率实测")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let live = report.liveCapture {
                    KeyValueRow(key: "收到帧数", value: "\(live.framesReceived)")
                    KeyValueRow(key: "实测帧率", value: String(format: "%.3f fps", live.measuredFPS))
                    KeyValueRow(
                        key: "帧间隔",
                        value: String(format: "%.2f – %.2f ms", live.intervalMinMS, live.intervalMaxMS)
                    )
                    if let structure = live.structure {
                        KeyValueRow(
                            key: "帧格式",
                            value: "\(structure.width)x\(structure.height) \(structure.pixelFormat)"
                        )
                        KeyValueRow(
                            key: "bytesPerRow",
                            value: "\(structure.bytesPerRow)（期望 \(structure.expectedBytesPerRowFor12Bit)）"
                        )
                    }
                    KeyValueRow(
                        key: "元数据键",
                        value: "sample \(live.sampleBufferAttachmentKeys.count) · pixel \(live.pixelBufferAttachmentKeys.count)"
                    )
                    if !live.note.isEmpty && live.note != "正常" {
                        Text(live.note)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func formatCard(_ report: ProbeReport) -> some View {
        let candidates = report.formats
            .filter { $0.isVideoCapable }
            .sorted { $0.megapixels > $1.megapixels }

        return Card(title: "视频格式（按面积，前 8 项）") {
            VStack(alignment: .leading, spacing: 8) {
                if candidates.isEmpty {
                    Text("未发现 4:3 视频格式")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(candidates.prefix(8).enumerated()), id: \.offset) { _, format in
                        HStack {
                            Text("\(format.width)x\(format.height)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.white)
                                .frame(width: 108, alignment: .leading)
                            Text(format.pixelFormat)
                                .font(.caption2.monospaced())
                                .foregroundStyle(format.isOpenGateCandidate ? .green : .secondary)
                                .frame(width: 44, alignment: .leading)
                            Text(format.isOpenGateCandidate ? "OG" : (format.is4x3 ? "4:3" : "—"))
                                .font(.caption2.monospaced())
                                .foregroundStyle(format.isOpenGateCandidate ? .green : .secondary)
                                .frame(width: 30, alignment: .leading)
                            Text(format.supports24 ? "24fps ✓" : "—")
                                .font(.caption2)
                                .foregroundStyle(format.supports24 ? .green : .secondary)
                            Spacer()
                            Text(String(format: "%.1fMP", format.megapixels))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: 日志

    private var logCard: some View {
        Card(title: "执行日志") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.steps.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - 组件

struct Card<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct VerdictRow: View {
    let verdict: Verdict

    private var color: Color {
        switch verdict.level {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        case .unknown: return .gray
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(verdict.key)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text(verdict.message)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
    }
}
