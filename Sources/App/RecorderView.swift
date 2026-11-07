import SwiftUI

struct RecorderView: View {

    @StateObject private var engine = RecordingEngine()
    @State private var showDetails = false
    @State private var showLandscapeControls = false

    var onShowProbe: () -> Void

    private let accent = Color(red: 0.42, green: 0.85, blue: 0.82)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                if geometry.size.width > geometry.size.height {
                    landscapeLayout
                } else {
                    portraitLayout
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear { engine.prepareSession() }
        .preferredColorScheme(.dark)
    }

    // MARK: - 竖屏

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            header
            previewSection
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    engineCard
                    exposureCard
                    whiteBalanceCard
                    tierGrid
                    statusCard
                    if showDetails {
                        detailCard
                    }
                    if !engine.history.isEmpty {
                        historyCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            footer
        }
    }

    // MARK: - 横屏

    /// 横屏时 4:3 画面两侧会留出大片空区，正好放波形与档位，
    /// 不占用画面本身的高度。
    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            // 左空区：波形与实时参数
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("波形")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button {
                        engine.waveformEnabled.toggle()
                    } label: {
                        Image(systemName: engine.waveformEnabled ? "waveform" : "waveform.slash")
                            .font(.system(size: 11))
                            .foregroundStyle(engine.waveformEnabled ? accent : .white.opacity(0.4))
                    }
                }

                if engine.waveformEnabled {
                    WaveformView(image: engine.waveformImage, accent: accent)
                        .frame(height: 92)
                }

                LiveReadout(exposure: engine.exposure, whiteBalance: engine.whiteBalance, accent: accent)

                Spacer(minLength: 0)

                Text(engine.captureConfiguration?.resolutionText ?? "—")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))

                Text(engine.rotation.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)

            // 中间：取景器
            CameraPreviewView(
                session: engine.capture.session,
                rotationDegrees: engine.rotationDegrees
            )
            .aspectRatio(4.0 / 3.0, contentMode: .fit)

            // 右空区：档位与录制
            VStack(spacing: 8) {
                ForEach(QualityTier.allCases) { tier in
                    compactTierButton(tier)
                }

                Spacer(minLength: 0)

                recordButton

                Button {
                    showLandscapeControls = true
                } label: {
                    Label("曝光 / 白平衡", systemImage: "slider.horizontal.3")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showLandscapeControls) {
            landscapeControlsSheet
        }
    }

    private var landscapeControlsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ExposurePanel(exposure: engine.exposure, accent: accent)
                    WhiteBalancePanel(whiteBalance: engine.whiteBalance, accent: accent)
                    statusCard
                }
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("曝光 / 白平衡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showLandscapeControls = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func compactTierButton(_ tier: QualityTier) -> some View {
        let selected = engine.tier == tier
        let disabled = engine.state.isBusy

        return Button {
            engine.tier = tier
        } label: {
            VStack(spacing: 1) {
                Text(tier.displayName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.8))
                Text(String(format: "%.0f MB/s", tier.estimatedMegabytesPerSecond))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(selected ? Color.black.opacity(0.55) : Color.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? accent : Color.white.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && !selected ? 0.4 : 1)
    }

    // MARK: - 取景器

    private var previewSection: some View {
        ZStack(alignment: .bottomLeading) {
            CameraPreviewView(
                session: engine.capture.session,
                rotationDegrees: engine.rotationDegrees
            )
            .aspectRatio(4224.0 / 3024.0, contentMode: .fit)
            .background(Color.black)
            .padding(rotationInset)

            if engine.waveformEnabled {
                WaveformView(image: engine.waveformImage, accent: accent)
                    .frame(width: 148, height: 88)
                    .padding(10)
            }

            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    engine.waveformEnabled.toggle()
                } label: {
                    Image(systemName: engine.waveformEnabled ? "waveform" : "waveform.slash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(engine.waveformEnabled ? accent : .white.opacity(0.5))
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                }

                Button {
                    engine.rotation.cycle()
                } label: {
                    Text(engine.rotation.shortLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(engine.rotation.isLandscape ? accent : .white.opacity(0.75))
                        .frame(width: 34, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(0.45))
                        )
                }

                LiveReadout(exposure: engine.exposure, whiteBalance: engine.whiteBalance, accent: accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    /// 竖拍时画面被转成纵向，在 4:3 横向容器里会左右留黑边。
    /// 这里不做裁切，只用对称内缩让视觉重心回到容器中央。
    private var rotationInset: CGFloat {
        engine.rotation.isLandscape ? 0 : 44
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("A camera")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(engine.captureSummary)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showDetails.toggle() }
            } label: {
                Image(systemName: showDetails ? "info.circle.fill" : "info.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Button(action: onShowProbe) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.leading, 14)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 采集摘要

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.sessionReady ? accent : Color.orange)
                    .frame(width: 7, height: 7)
                Text(engine.sessionReady ? "采集就绪" : "采集未就绪")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(engine.audioSummary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }

            HStack(spacing: 0) {
                metric("分辨率", engine.captureConfiguration?.resolutionText ?? "—")
                divider
                metric("帧率", engine.captureConfiguration?.isExact24 == true ? "24.000" : "—")
                divider
                metric("像素格式", engine.captureConfiguration?.pixelFormat ?? "—")
            }

            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                Text("色彩管线：系统 ISP（SDR）· Apple Log 2 待接入 Metal 管线")
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Color.orange.opacity(0.85))
        }
        .padding(14)
        .background(panelBackground)
    }

    // MARK: - 曝光（独立子视图，避免整屏重绘）

    private var exposureCard: some View {
        ExposurePanel(exposure: engine.exposure, accent: accent)
    }

    // MARK: - 白平衡（独立子视图）

    private var whiteBalanceCard: some View {
        WhiteBalancePanel(whiteBalance: engine.whiteBalance, accent: accent)
    }

    // MARK: - 档位

    private var tierGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("编码档位", trailing: engine.state.isBusy ? "录制中不可切换" : nil)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(QualityTier.allCases) { tier in
                    tierCell(tier)
                }
            }
        }
    }

    private func tierCell(_ tier: QualityTier) -> some View {
        let selected = engine.tier == tier
        let disabled = engine.state.isBusy

        return Button {
            engine.tier = tier
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tier.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? accent : .white.opacity(0.85))
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(accent)
                    }
                }
                Text(tier.subtitle)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Text(String(format: "≈%.0f MB/s", tier.estimatedMegabytesPerSecond))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("·")
                        .foregroundStyle(.white.opacity(0.3))
                    Text(tier.roleDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.08 : 0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(selected ? accent.opacity(0.6) : Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && !selected ? 0.4 : 1)
    }

    // MARK: - 状态

    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(timecode(engine.elapsed))
                    .font(.system(size: 34, weight: .light, design: .monospaced))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(stateText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(stateColor)
                    Text(ByteCountFormatter.string(fromByteCount: engine.writtenBytes, countStyle: .file))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }

            HStack(spacing: 8) {
                Image(systemName: engine.lastLocationDegraded ? "location.slash" : "location.fill")
                    .font(.system(size: 11))
                Text(engine.lastLocationText)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .foregroundStyle(engine.lastLocationDegraded ? Color.orange : accent)

            if let thermal = engine.thermalNote {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer.high")
                        .font(.system(size: 11))
                    Text(thermal)
                        .font(.system(size: 11))
                    Spacer()
                }
                .foregroundStyle(Color.orange)
            }
        }
        .padding(14)
        .background(panelBackground)
    }

    // MARK: - 详情

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("当前状态")
            row("编码器", engine.tier.codecName)
            row("GOP", engine.tier.gopDescription)
            row("预估写入", String(format: "%.0f MB/s", engine.tier.estimatedMegabytesPerSecond))
            row("掉帧", "\(engine.droppedFrames)")
            row("可用空间", engine.availableSpaceText)
            row("可录时长", formatRemaining(engine.remainingSeconds))
            if let config = engine.captureConfiguration, !config.notes.isEmpty {
                Divider().overlay(Color.white.opacity(0.1))
                ForEach(config.notes, id: \.self) { note in
                    Text("· \(note)")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.orange.opacity(0.8))
                }
            }
        }
        .padding(14)
        .background(panelBackground)
    }

    // MARK: - 历史

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("本次会话产出", trailing: "\(engine.history.count) 条")
            ForEach(engine.history.prefix(6), id: \.url) { outcome in
                VStack(alignment: .leading, spacing: 3) {
                    Text(outcome.url.lastPathComponent)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text(timecode(outcome.duration))
                        Text(ByteCountFormatter.string(fromByteCount: outcome.fileSize, countStyle: .file))
                        Text(String(format: "%.2f fps", outcome.effectiveFrameRate))
                        if outcome.droppedVideoFrames > 0 {
                            Text("丢 \(outcome.droppedVideoFrames)")
                                .foregroundStyle(Color.orange)
                        }
                        if !outcome.finishedCleanly {
                            Text("未正常封盘")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.vertical, 3)
            }
        }
        .padding(14)
        .background(panelBackground)
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 10) {
            if case .failed(let reason) = engine.state {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            recordButton
                .padding(.bottom, 6)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.9))
    }

    private var recordButton: some View {
        Button(action: toggleRecording) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 3)
                    .frame(width: 74, height: 74)

                if case .recording = engine.state {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                } else if engine.state.isBusy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 60, height: 60)
                }
            }
        }
        .disabled(engine.state == .finishing)
    }

    private func toggleRecording() {
        switch engine.state {
        case .recording:
            engine.stopRecording()
        case .finished, .failed:
            engine.resetState()
        default:
            engine.startRecording()
        }
    }

    // MARK: - 组件

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
    }

    private func sectionTitle(_ text: String, trailing: String? = nil) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            if let trailing = trailing {
                Text(trailing)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 24)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    // MARK: - 辅助

    private var stateText: String {
        switch engine.state {
        case .idle: return engine.sessionReady ? "待机" : "准备中"
        case .preparing(let text): return text
        case .recording: return "录制中"
        case .finishing: return "封盘中"
        case .finished: return "已完成"
        case .failed: return "出错"
        }
    }

    private var stateColor: Color {
        switch engine.state {
        case .recording: return .red
        case .failed: return .red.opacity(0.8)
        case .finished: return accent
        default: return .white.opacity(0.5)
        }
    }

    private func timecode(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped)
        let minutes = total / 60
        let secs = total % 60
        let hundredths = Int((clamped - Double(total)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, secs, hundredths)
    }

    private func formatRemaining(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "—" }
        if seconds > 3600 {
            return String(format: "%.1f 小时", seconds / 3600)
        }
        return String(format: "%.0f 分钟", seconds / 60)
    }
}

// MARK: - 曝光面板

/// 单独成型的原因：曝光参数会以 2 Hz 回读刷新，
/// 若放在 RecorderView 的 body 里，每次刷新都会连带重算档位网格与历史列表。
/// 拆成独立子视图后，只有这一块重绘。
struct ExposurePanel: View {

    @ObservedObject var exposure: ExposureController
    let accent: Color

    // 滑块草稿：拖动期间只改状态，松手才提交给设备，
    // 避免以 60 Hz 触发 lockForConfiguration
    @State private var isoDraft: Double?
    @State private var shutterDraft: Double?
    @State private var evDraft: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("曝光")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(exposure.liveExposureSummary)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(accent.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            HStack(spacing: 8) {
                ForEach(ExposureController.Mode.allCases) { mode in
                    modeButton(mode)
                }
            }

            if exposure.mode.isoIsManual {
                isoRow
            }
            if exposure.mode.shutterIsManual {
                shutterRow
            }
            evRow

            if exposure.isServoActive {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9))
                    Text("闭环运行中 · \(exposure.mode.shutterIsManual ? "固定快门，调 ISO" : "固定 ISO，调快门")")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    // MARK: 行

    private var isoRow: some View {
        sliderRow(
            title: "ISO",
            valueText: String(format: "%.0f", isoDraft.map { denormalizeISO($0) } ?? exposure.iso),
            position: isoDraft ?? exposure.isoSliderPosition,
            onDrag: { isoDraft = $0 },
            onCommit: {
                if let draft = isoDraft {
                    exposure.isoSliderPosition = draft
                    isoDraft = nil
                }
            }
        )
    }

    private var shutterRow: some View {
        sliderRow(
            title: "快门",
            valueText: exposure.formatShutter(shutterDraft.map { denormalizeShutter($0) } ?? exposure.shutterSeconds),
            position: shutterDraft ?? exposure.shutterSliderPosition,
            onDrag: { shutterDraft = $0 },
            onCommit: {
                if let draft = shutterDraft {
                    exposure.shutterSliderPosition = draft
                    shutterDraft = nil
                }
            }
        )
    }

    private var evRow: some View {
        sliderRow(
            title: "EV",
            valueText: String(format: "%+.1f", evDraft.map { Float($0 * 4 - 2) } ?? exposure.ev),
            position: evDraft ?? Double((exposure.ev + 2) / 4),
            onDrag: { evDraft = $0 },
            onCommit: {
                if let draft = evDraft {
                    exposure.ev = Float(draft * 4 - 2)
                    evDraft = nil
                }
            }
        )
    }

    // MARK: 组件

    private func modeButton(_ mode: ExposureController.Mode) -> some View {
        let selected = exposure.mode == mode
        return Button {
            exposure.mode = mode
            isoDraft = nil
            shutterDraft = nil
        } label: {
            VStack(spacing: 2) {
                Text(mode.shortLabel)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.8))
                Text(modeCaption(mode))
                    .font(.system(size: 8))
                    .foregroundStyle(selected ? Color.black.opacity(0.55) : Color.white.opacity(0.35))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? accent : Color.white.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }

    private func modeCaption(_ mode: ExposureController.Mode) -> String {
        switch mode {
        case .autoBoth: return "全自动"
        case .manualISO: return "快门自动"
        case .manualShutter: return "ISO 自动"
        case .manualBoth: return "全手动"
        }
    }

    private func sliderRow(
        title: String,
        valueText: String,
        position: Double,
        onDrag: @escaping (Double) -> Void,
        onCommit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 30, alignment: .leading)

            Slider(
                value: Binding(
                    get: { position },
                    set: { onDrag($0) }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing { onCommit() }
                }
            )
            .tint(accent)

            Text(valueText)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 58, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: 反归一化（只用于拖动中的数值预览）

    private func denormalizeISO(_ position: Double) -> Float {
        let low = Double(exposure.isoRange.lowerBound)
        let high = Double(exposure.isoRange.upperBound)
        guard low > 0, high > low else { return exposure.iso }
        return Float(low * pow(high / low, position))
    }

    private func denormalizeShutter(_ position: Double) -> Double {
        let low = exposure.shutterRange.lowerBound
        let high = exposure.shutterRange.upperBound
        guard low > 0, high > low else { return exposure.shutterSeconds }
        return low * pow(high / low, position)
    }
}

// MARK: - 取景器实时读数

/// 叠在取景器右上角。独立成型的原因同 ExposurePanel：
/// ISO / 快门 / 色温都是 2 Hz 回读，混在主界面里会带着整屏一起重算。
struct LiveReadout: View {

    @ObservedObject var exposure: ExposureController
    @ObservedObject var whiteBalance: WhiteBalanceController
    let accent: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(String(format: "ISO %.0f", exposure.liveISO))
            Text(exposure.formatShutter(exposure.liveShutterSeconds))
            Text(whiteBalance.liveSummary)
        }
        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.45))
        )
    }
}

// MARK: - 白平衡面板

struct WhiteBalancePanel: View {

    @ObservedObject var whiteBalance: WhiteBalanceController
    let accent: Color

    @State private var tempDraft: Double?
    @State private var tintDraft: Double?

    private var temperatureSpan: Double {
        Double(WhiteBalanceController.temperatureRange.upperBound - WhiteBalanceController.temperatureRange.lowerBound)
    }

    private var tintSpan: Double {
        Double(WhiteBalanceController.tintRange.upperBound - WhiteBalanceController.tintRange.lowerBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("白平衡")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(whiteBalance.liveSummary)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(accent.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            HStack(spacing: 8) {
                ForEach(WhiteBalanceController.Mode.allCases) { mode in
                    modeButton(mode)
                }
            }

            if whiteBalance.mode == .manual {
                temperatureRow
                tintRow
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    // MARK: 行

    private var temperatureRow: some View {
        sliderRow(
            title: "色温",
            valueText: String(format: "%.0f K", tempDraft.map { denormalizeTemperature($0) } ?? whiteBalance.temperature),
            position: tempDraft ?? normalizedTemperature,
            onDrag: { tempDraft = $0 },
            onCommit: {
                if let draft = tempDraft {
                    whiteBalance.temperature = denormalizeTemperature(draft)
                    tempDraft = nil
                }
            }
        )
    }

    private var tintRow: some View {
        sliderRow(
            title: "色调",
            valueText: String(format: "%+.0f", tintDraft.map { denormalizeTint($0) } ?? whiteBalance.tint),
            position: tintDraft ?? normalizedTint,
            onDrag: { tintDraft = $0 },
            onCommit: {
                if let draft = tintDraft {
                    whiteBalance.tint = denormalizeTint(draft)
                    tintDraft = nil
                }
            }
        )
    }

    // MARK: 组件

    private func modeButton(_ mode: WhiteBalanceController.Mode) -> some View {
        let selected = whiteBalance.mode == mode
        return Button {
            whiteBalance.mode = mode
            tempDraft = nil
            tintDraft = nil
        } label: {
            Text(mode.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.8))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? accent : Color.white.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }

    private func sliderRow(
        title: String,
        valueText: String,
        position: Double,
        onDrag: @escaping (Double) -> Void,
        onCommit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 30, alignment: .leading)

            Slider(
                value: Binding(
                    get: { position },
                    set: { onDrag($0) }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing { onCommit() }
                }
            )
            .tint(accent)

            Text(valueText)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 58, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: 归一化

    private var normalizedTemperature: Double {
        let low = Double(WhiteBalanceController.temperatureRange.lowerBound)
        return min(max(Double(whiteBalance.temperature) - low, 0), temperatureSpan) / temperatureSpan
    }

    private var normalizedTint: Double {
        let low = Double(WhiteBalanceController.tintRange.lowerBound)
        return min(max(Double(whiteBalance.tint) - low, 0), tintSpan) / tintSpan
    }

    private func denormalizeTemperature(_ position: Double) -> Float {
        Float(Double(WhiteBalanceController.temperatureRange.lowerBound) + position * temperatureSpan)
    }

    private func denormalizeTint(_ position: Double) -> Float {
        Float(Double(WhiteBalanceController.tintRange.lowerBound) + position * tintSpan)
    }
}
