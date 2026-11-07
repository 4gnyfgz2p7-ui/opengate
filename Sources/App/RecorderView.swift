import SwiftUI

/// 拍摄主界面。
///
/// 布局原则：**画面优先**。取景器铺满全屏，控件作为半透明浮层叠在上面，
/// 横竖屏只是浮层落点不同（竖屏落底部、横屏落右侧），
/// 画面本身始终是一个尺寸撑满的整块——不再有"切横竖只有画面变"的割裂感。
///
/// 信息分层：
/// - 拍摄时常驻：曝光、白平衡、档位、监看读数
/// - 录制中只留：监看画面、时间码、曝光、停止键（其余全部隐去）
/// - 采集规格、音频、色彩管线、存储、历史、探针 → 设置
struct RecorderView: View {

    @StateObject private var engine = RecordingEngine()
    @State private var showSettings = false

    var onShowProbe: () -> Void

    private let accent = Color(red: 0.42, green: 0.85, blue: 0.82)

    private var isRecording: Bool {
        engine.state == .recording
    }

    /// 只在真正需要时才出现的一行状态：失败原因或自动停止说明。
    private var statusMessage: String? {
        if case .failed(let reason) = engine.state { return reason }
        return engine.autoStopReason
    }

    var body: some View {
        GeometryReader { geometry in
            let physical = geometry.size
            let physicalLandscape = physical.width > physical.height

            // 采集方向已是横拍、但窗口仍竖着（这台机器上窗口不会自己转）：
            // 把**整层内容**一起转 90°，取景与控件才不会一个横一个竖。
            let rotateAll = engine.rotation.isLandscape && !physicalLandscape
            let contentSize = rotateAll
                ? CGSize(width: physical.height, height: physical.width)
                : physical
            let angle = rotateAll ? Double(engine.rotation.degrees) - 90 : 0
            let contentLandscape = contentSize.width > contentSize.height

            // 整层转过之后，预览层自己的方向要补回去，否则画面是歪的
            let previewDegrees: CGFloat = rotateAll ? 90 : engine.rotationDegrees
            // 旋转后的坐标里画面是竖的 3:4，转回去正好铺成横的 4:3
            let aspect: CGFloat = rotateAll
                ? 3.0 / 4.0
                : (engine.rotation.isLandscape ? 4.0 / 3.0 : 3.0 / 4.0)

            ZStack {
                Color.black

                previewView(
                    available: contentSize,
                    anchor: previewAnchor(rotated: rotateAll, contentLandscape: contentLandscape),
                    aspect: aspect,
                    degrees: previewDegrees
                )

                controls(landscape: contentLandscape, size: contentSize)
                    .frame(width: contentSize.width, height: contentSize.height)
            }
            .frame(width: contentSize.width, height: contentSize.height)
            .rotationEffect(.degrees(angle))
            .frame(width: physical.width, height: physical.height)
        }
        .ignoresSafeArea()
        .onAppear { engine.prepareSession() }
        .preferredColorScheme(.dark)
        .statusBarHidden(isRecording)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(engine: engine, onShowProbe: onShowProbe)
        }
    }

    // MARK: - 取景

    /// 取景画面永远贴向镜头模组一侧，绝不在中间居中。
    ///
    /// 后置模组在机身背面左上角，换算到屏幕就是：竖拍贴顶、横 A（0°）贴左、
    /// 横 B（180°）贴右、倒置（270°）贴底。
    /// 整层旋转模式下坐标已经转过 90°，所以"贴顶"在旋转坐标里就等于物理上的
    /// 对应侧边，直接用 .top 即可——这一步搞错就会贴到握持手那一侧去。
    private func previewAnchor(rotated: Bool, contentLandscape: Bool) -> Alignment {
        if rotated { return .top }
        if contentLandscape {
            return engine.rotation.degrees == 180 ? .trailing : .leading
        }
        return engine.rotation.degrees == 270 ? .bottom : .top
    }

    private func previewView(
        available: CGSize,
        anchor: Alignment,
        aspect: CGFloat,
        degrees: CGFloat
    ) -> some View {
        var width = available.width
        var height = width / aspect
        if height > available.height {
            height = available.height
            width = height * aspect
        }

        return CameraPreviewView(
            session: engine.capture.session,
            rotationDegrees: degrees
        )
        .frame(width: width, height: height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor)
    }

    // MARK: - 控件层

    @ViewBuilder
    private func controls(landscape: Bool, size: CGSize) -> some View {
        if isRecording {
            recordingControls(landscape: landscape)
        } else {
            standbyControls(landscape: landscape, size: size)
        }
    }

    private func standbyControls(landscape: Bool, size: CGSize) -> some View {
        Group {
            if landscape {
                // 横屏：一边塞波形，另一边放参数与录制
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        statusChip
                        waveform
                        Spacer(minLength: 0)
                    }

                    Spacer(minLength: 0)

                    VStack(spacing: 10) {
                        topActions
                        Spacer(minLength: 0)
                        ExposureStrip(exposure: engine.exposure, accent: accent)
                        WhiteBalanceStrip(whiteBalance: engine.whiteBalance, accent: accent)
                        recordBar
                    }
                    .frame(width: min(340, size.width * 0.34))
                }
                .padding(14)
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            statusChip
                            waveform
                        }
                        Spacer(minLength: 0)
                        topActions
                    }

                    Spacer(minLength: 0)

                    VStack(spacing: 10) {
                        if let message = statusMessage {
                            Text(message)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.red.opacity(0.9))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        ExposureStrip(exposure: engine.exposure, accent: accent)
                        WhiteBalanceStrip(whiteBalance: engine.whiteBalance, accent: accent)
                        recordBar
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 6)
            }
        }
    }

    /// 录制中只保留：监看画面、时间码、曝光、停止键。
    private func recordingControls(landscape: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                Text(Self.timecode(engine.elapsed))
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            Spacer(minLength: 0)

            if landscape {
                HStack(alignment: .bottom, spacing: 12) {
                    waveform
                    Spacer(minLength: 0)
                    ExposureStrip(exposure: engine.exposure, accent: accent, compact: true)
                        .frame(width: 340)
                }
                .padding(.horizontal, 16)
            } else {
                VStack(spacing: 8) {
                    HStack {
                        waveform
                        Spacer(minLength: 0)
                    }
                    ExposureStrip(exposure: engine.exposure, accent: accent, compact: true)
                }
                .padding(.horizontal, 14)
            }

            stopBar
        }
    }


    // MARK: - 顶部元素

    private var statusChip: some View {
        Menu {
            ForEach(QualityTier.allCases) { tier in
                Button {
                    engine.tier = tier
                } label: {
                    Text("\(tier.displayName) · \(Int(tier.estimatedMegabytesPerSecond)) MB/s")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(engine.sessionReady ? accent : Color.orange)
                    .frame(width: 6, height: 6)
                Text(engine.tier.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(Int(engine.tier.estimatedMegabytesPerSecond)) MB/s")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color.black.opacity(0.45))
            )
        }
    }

    private var topActions: some View {
        HStack(spacing: 8) {
            Button {
                engine.rotation.cycle()
            } label: {
                Text(engine.rotation.shortLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            .buttonStyle(.plain)

            iconButton("slider.horizontal.3", active: false) {
                showSettings = true
            }
        }
    }

    private func iconButton(_ name: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(active ? accent : Color.white.opacity(0.8))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
        .buttonStyle(.plain)
    }

    /// 有数据才画。没有波形时不留空框——空框本身就是视觉噪音。
    @ViewBuilder
    private var waveform: some View {
        if engine.waveformImage != nil {
            WaveformView(image: engine.waveformImage, accent: accent, reading: engine.waveformReading)
                .frame(width: 132, height: 78)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                )
        }
    }

    // MARK: - 录制条

    private var recordBar: some View {
        HStack(spacing: 12) {
            Text(Self.timecode(engine.elapsed))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(engine.state == .recording ? 1 : 0.55))
                .frame(width: 62, alignment: .leading)

            Spacer(minLength: 0)

            recordButton

            Spacer(minLength: 0)

            Text(engine.state.isBusy && engine.state != .recording ? "准备中" : "剩 \(Self.durationText(engine.remainingSeconds))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.top, 2)
    }

    private var stopBar: some View {
        HStack {
            Spacer()
            recordButton
            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var recordButton: some View {
        Button {
            if engine.state == .recording {
                engine.stopRecording()
            } else {
                engine.startRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 3)
                    .frame(width: 70, height: 70)

                if engine.state == .recording {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.red)
                        .frame(width: 26, height: 26)
                } else if engine.state.isBusy {
                    ProgressView().tint(.white)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 57, height: 57)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(engine.state == .finishing)
    }

    // MARK: - 格式化

    static func timecode(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds >= 3600 {
            return String(format: "%.1fh", seconds / 3600)
        }
        if seconds >= 60 {
            return String(format: "%.0fm", seconds / 60)
        }
        return String(format: "%.0fs", seconds)
    }
}

// MARK: - 曝光条

struct ExposureStrip: View {

    @ObservedObject var exposure: ExposureController
    let accent: Color
    var compact: Bool = false

    @State private var isoDraft: Double?
    @State private var shutterDraft: Double?
    @State private var evDraft: Double?

    var body: some View {
        VStack(spacing: compact ? 6 : 8) {
            // 当前实测值常驻：录制中也要能看见实际落到的 ISO 与快门，
            // 而不是只知道滑块停在哪。
            HStack(spacing: 10) {
                Text(String(format: "ISO %.0f", exposure.liveISO))
                Text(exposure.formatShutter(exposure.liveShutterSeconds))
                if exposure.mode != .manualBoth {
                    Text(String(format: "%+.1f EV", exposure.liveOffsetEV))
                        .foregroundStyle(abs(exposure.liveOffsetEV) > 0.5 ? accent : Color.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.75))

            HStack(spacing: 6) {
                ForEach(ExposureController.Mode.allCases) { mode in
                    modeChip(mode)
                }
                Spacer(minLength: 0)
            }

            // EV 是半自动与自动模式下唯一的亮度旋钮；
            // 全手动时亮暗由 ISO 与快门各自决定，不给 EV 以免两套控制打架。
            if exposure.mode.showsEVSlider {
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

            if exposure.mode.isoIsManual {
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

            if exposure.mode.shutterIsManual {
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.52))
        )
    }

    private func modeChip(_ mode: ExposureController.Mode) -> some View {
        let selected = exposure.mode == mode
        return Button {
            exposure.mode = mode
            isoDraft = nil
            shutterDraft = nil
            evDraft = nil
        } label: {
            Text(mode.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? accent : Color.white.opacity(0.07))
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
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: 30, alignment: .leading)

            Slider(
                value: Binding(get: { position }, set: { onDrag($0) }),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing { onCommit() }
                }
            )
            .tint(accent)

            Text(valueText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 58, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

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

// MARK: - 白平衡条

/// 一行常驻 + 手动档弹面板。
///
/// 白平衡不是每次都要动，常驻两个滑块会把曝光条挤走；
/// 而"手动"是一个持续调的过程，所以放在弹出面板里：
/// 第一次点「手动」选中它，再点一次才弹滑块，调完关闭。
struct WhiteBalanceStrip: View {

    @ObservedObject var whiteBalance: WhiteBalanceController
    let accent: Color

    @State private var showManual = false

    var body: some View {
        HStack(spacing: 6) {
            Text("白平衡")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.42))

            ForEach(WhiteBalanceController.Mode.allCases) { mode in
                chip(mode)
            }

            Spacer(minLength: 0)

            Text(whiteBalance.liveSummary)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.42))
        )
        .sheet(isPresented: $showManual) {
            manualSheet
        }
    }

    private func chip(_ mode: WhiteBalanceController.Mode) -> some View {
        let selected = whiteBalance.mode == mode
        return Button {
            // 已处于手动档时再点一次 → 弹出滑块
            if mode == .manual && whiteBalance.mode == .manual {
                showManual = true
            } else {
                whiteBalance.mode = mode
                if mode == .manual { showManual = true }
            }
        } label: {
            Text(mode.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.7))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(selected ? accent : Color.white.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: 手动面板

    private var manualSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                sliderRow(
                    title: "色温",
                    valueText: String(format: "%.0f K", tempDraft ?? whiteBalance.temperature),
                    position: tempDraft.map { normalizedTemp($0) } ?? normalizedTemp(whiteBalance.temperature),
                    onDrag: { tempDraft = denormalizeTemp($0) },
                    onCommit: {
                        if let draft = tempDraft {
                            whiteBalance.temperature = draft
                            tempDraft = nil
                        }
                    }
                )

                sliderRow(
                    title: "色调",
                    valueText: String(format: "%+.0f", tintDraft ?? whiteBalance.tint),
                    position: tintDraft.map { normalizedTint($0) } ?? normalizedTint(whiteBalance.tint),
                    onDrag: { tintDraft = denormalizeTint($0) },
                    onCommit: {
                        if let draft = tintDraft {
                            whiteBalance.tint = draft
                            tintDraft = nil
                        }
                    }
                )

                Text("按住滑块拖动，松手即生效。关闭面板后参数保持不变。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("白平衡 · 手动")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showManual = false }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.height(300)])
    }

    @State private var tempDraft: Float?
    @State private var tintDraft: Float?

    private var tempSpan: Double {
        Double(WhiteBalanceController.temperatureRange.upperBound - WhiteBalanceController.temperatureRange.lowerBound)
    }

    private var tintSpan: Double {
        Double(WhiteBalanceController.tintRange.upperBound - WhiteBalanceController.tintRange.lowerBound)
    }

    private func normalizedTemp(_ value: Float) -> Double {
        let low = Double(WhiteBalanceController.temperatureRange.lowerBound)
        return min(max(Double(value) - low, 0), tempSpan) / tempSpan
    }

    private func normalizedTint(_ value: Float) -> Double {
        let low = Double(WhiteBalanceController.tintRange.lowerBound)
        return min(max(Double(value) - low, 0), tintSpan) / tintSpan
    }

    private func denormalizeTemp(_ position: Double) -> Float {
        Float(Double(WhiteBalanceController.temperatureRange.lowerBound) + position * tempSpan)
    }

    private func denormalizeTint(_ position: Double) -> Float {
        Float(Double(WhiteBalanceController.tintRange.lowerBound) + position * tintSpan)
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
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 34, alignment: .leading)

            Slider(
                value: Binding(get: { position }, set: { onDrag($0) }),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing { onCommit() }
                }
            )
            .tint(accent)

            Text(valueText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 66, alignment: .trailing)
        }
    }
}

// MARK: - 设置

/// 拍摄时不看的东西全放这里：采集规格、音频、色彩管线、存储、历史、探针。
struct SettingsSheet: View {

    @ObservedObject var engine: RecordingEngine
    var onShowProbe: () -> Void

    @Environment(\.dismiss) private var dismiss
    private let accent = Color(red: 0.42, green: 0.85, blue: 0.82)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    captureSection
                    tierSection
                    storageSection
                    displaySection
                    historySection
                }
                .padding(18)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }

    private var captureSection: some View {
        section("采集") {
            row("分辨率", engine.captureConfiguration?.resolutionText ?? "未配置")
            row("帧率", String(format: "%.3f fps", Double(VideoSettingsBuilder.frameRate)))
            row("音频", "LPCM 48 kHz / 16-bit / 2 ch")
            row("色彩管线", "系统 ISP · SDR · 未启用 Log")
            row("定位", engine.lastLocationText)
            if let note = engine.thermalNote {
                row("机身温度", note)
            }
        }
    }

    private var tierSection: some View {
        section("档位") {
            ForEach(QualityTier.allCases) { tier in
                Button {
                    engine.tier = tier
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: engine.tier == tier ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(engine.tier == tier ? accent : Color.white.opacity(0.25))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(tier.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                            Text("\(tier.subtitle) · \(Int(tier.estimatedMegabytesPerSecond)) MB/s · \(tier.roleDescription)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var storageSection: some View {
        section("存储") {
            row("本档可录", RecorderView.durationText(engine.remainingSeconds))
            row("已写入", String(format: "%.1f MB", Double(engine.writtenBytes) / 1_000_000))
            if engine.remainingSeconds < 60 && engine.remainingSeconds > 0 {
                Text("空间紧张：开录约 1 分钟后会触发自动停止并保存")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var displaySection: some View {
        section("显示") {
            Toggle(isOn: $engine.waveformEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("波形监看")
                        .font(.system(size: 13))
                    Text("关闭后连采样都不做，省电")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(accent)

            Button {
                dismiss()
                onShowProbe()
            } label: {
                HStack {
                    Text("能力探针")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !engine.history.isEmpty {
            section("最近录制") {
                ForEach(Array(engine.history.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.url.lastPathComponent)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(String(
                                format: "%.2f MB · %.1f 秒 · %.1f fps · 丢 %lld 帧",
                                Double(item.fileSize) / 1_000_000,
                                item.duration,
                                item.effectiveFrameRate,
                                item.droppedVideoFrames
                            ))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: 组件

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 9) {
                content()
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
        }
    }
}
