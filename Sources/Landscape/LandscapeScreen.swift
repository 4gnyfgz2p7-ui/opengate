import SwiftUI

/// 横屏主界面（顺时针 90°）。
///
/// 版式全部由 `LandscapeLayout` 解算，这里只负责摆放与绑定，不写死坐标。
/// 交互与采集的耦合压到最低：只读 `RecordingEngine` 的公开属性，
/// 只调它的公开方法，不碰 `Sources/Capture` 内部状态。
struct LandscapeScreen: View {

    @ObservedObject var engine: RecordingEngine
    /// 顶部小弹窗文案（录制失败、自动停止等）
    let banner: String?
    /// 窗口安全区，由外层按 `UIWindowScene` 传入
    let insets: EdgeInsets
    var onSettings: () -> Void

    /// 当前选中的参数。选中只影响颜色与拖拽条指向，不改设备。
    @State private var selection: LandscapeParameter = .shutter
    /// 曝光的「自动」是本层语义：自动＝补偿归零且不接受拖拽。
    @State private var exposureManual = false

    var body: some View {
        GeometryReader { geo in
            let layout = LandscapeLayout(size: geo.size, insets: insets)

            ZStack(alignment: .topLeading) {
                Color.black

                previewPane(layout)
                lensRail(layout)
                parameterRail(layout)
                sideBar(layout)
                recordOrb(layout)
                settingsOrb(layout)
                chipsRow(layout)

                if let banner {
                    Text(banner)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .liquidGlass(Capsule(), tint: .white.opacity(0.16), interactive: false)
                        .frame(maxWidth: layout.preview.width * 0.8)
                        .position(x: layout.preview.midX, y: layout.preview.minY + 72)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: banner)
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - 取景

    private func previewPane(_ layout: LandscapeLayout) -> some View {
        CameraPreviewView(
            session: engine.capture.session,
            rotationDegrees: engine.rotationDegrees
        )
        .frame(width: layout.preview.width, height: layout.preview.height)
        .position(x: layout.preview.midX, y: layout.preview.midY)
    }

    // MARK: - 焦距（镜头）轨

    private func lensRail(_ layout: LandscapeLayout) -> some View {
        // 相邻玻璃圆钮放进同一个容器，让它们在靠近时按系统规则彼此融合，
        // 而不是各自独立的一层模糊。
        GlassEffectContainer(spacing: LandscapeLayout.lensGap) {
            VStack(spacing: LandscapeLayout.lensGap) {
                ForEach(engine.lenses) { lens in
                    LandscapeLensButton(
                        label: lens.label,
                        isActive: lens.id == engine.activeLensID,
                        isAvailable: !engine.state.isBusy
                    ) {
                        engine.selectLens(lens)
                    }
                }
            }
        }
        .frame(width: layout.lensRail.width, height: layout.lensRail.height, alignment: .top)
        .position(x: layout.lensRail.midX, y: layout.lensRail.midY)
    }

    // MARK: - 参数轨

    private func parameterRail(_ layout: LandscapeLayout) -> some View {
        GlassEffectContainer(spacing: LandscapeLayout.knobGap) {
            VStack(spacing: LandscapeLayout.knobGap) {
            ForEach(LandscapeParameter.allCases) { parameter in
                LandscapeKnob(
                    title: parameter.title,
                    value: knobValue(parameter),
                    detail: isAuto(parameter) ? "AUTO" : "手动",
                    isAuto: isAuto(parameter),
                    isSelected: selection == parameter
                ) {
                    tap(parameter)
                }
            }

            // 唯一的 A 钮：一次把所有参数交还系统
            Button {
                setAllAuto()
            } label: {
                VStack(spacing: 1) {
                    Text("A")
                        .font(.system(size: 18, weight: .semibold))
                    Text("全部自动")
                        .font(.system(size: 7))
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
                .frame(width: LandscapeLayout.knobSize, height: LandscapeLayout.knobSize)
                .liquidGlass(Circle(), tint: .white.opacity(0.14))
            }
            .buttonStyle(.plain)
            }
        }
        .frame(width: layout.rail.width, height: layout.rail.height, alignment: .top)
        .position(x: layout.rail.midX, y: layout.rail.midY)
    }

    // MARK: - 拖拽条：全屏唯一一条，贴最右边

    /// 竖向拖拽条。
    ///
    /// SwiftUI 没有原生竖向滑块，这里用系统 `Slider` 旋转 -90° 实现：
    /// 交互、惯性与无障碍全部是系统的，只是摆成竖的。
    /// 旋转不改变布局尺寸，所以必须外套一个显式 frame，否则会溢出胶囊。
    private func sideBar(_ layout: LandscapeLayout) -> some View {
        VStack(spacing: 6) {
            Text(selection.title)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)

            Slider(value: sliderBinding, in: 0...1)
                .tint(.white)
                .frame(width: 150)
                .rotationEffect(.degrees(-90))
                .frame(width: 30, height: 150)
                .disabled(isAuto(selection))
                .opacity(isAuto(selection) ? 0.4 : 1)

            Text(readout(selection))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.vertical, 14)
        .frame(width: layout.bar.width, height: layout.bar.height)
        .liquidGlass(Capsule(), tint: .white.opacity(0.10))
        .position(x: layout.bar.midX, y: layout.bar.midY)
    }

    // MARK: - 录制键 / 设置

    private func recordOrb(_ layout: LandscapeLayout) -> some View {
        Button {
            if engine.state == .recording {
                engine.stopRecording()
            } else {
                engine.startRecording()
            }
        } label: {
            Circle()
                .fill(engine.state == .recording ? Color.white : Color.red)
                .frame(
                    width: LandscapeLayout.recordSize * (engine.state == .recording ? 0.34 : 0.4),
                    height: LandscapeLayout.recordSize * (engine.state == .recording ? 0.34 : 0.4)
                )
                .frame(width: LandscapeLayout.recordSize, height: LandscapeLayout.recordSize)
                .liquidGlass(Circle(), tint: .white.opacity(0.10))
        }
        .buttonStyle(.plain)
        .position(x: layout.record.midX, y: layout.record.midY)
    }

    private func settingsOrb(_ layout: LandscapeLayout) -> some View {
        Button(action: onSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: layout.gear.width, height: layout.gear.height)
                .liquidGlass(Circle(), tint: .white.opacity(0.10))
        }
        .buttonStyle(.plain)
        .position(x: layout.gear.midX, y: layout.gear.midY)
    }

    /// 顶部信息：压在画面左上角，横向一行
    private func chipsRow(_ layout: LandscapeLayout) -> some View {
        HStack(spacing: 8) {
            if engine.state == .recording {
                chip(timecode(engine.elapsed), tint: .red.opacity(0.9), dot: true)
            }
            chip("\(engine.tier.displayName) · 24fps", tint: .white.opacity(0.10))
            chip("剩 \(Self.duration(engine.remainingSeconds))", tint: .white.opacity(0.10))
            Spacer(minLength: 0)
        }
        .padding(.leading, layout.chipsOrigin.x)
        .padding(.top, layout.chipsOrigin.y)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func chip(_ text: String, tint: Color, dot: Bool = false) -> some View {
        HStack(spacing: 5) {
            if dot {
                Circle().fill(Color.red).frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .liquidGlass(Capsule(), tint: tint, interactive: false)
    }

    // MARK: - 参数状态

    private func isAuto(_ parameter: LandscapeParameter) -> Bool {
        switch parameter {
        case .shutter:
            return engine.exposure.mode != .manualShutter && engine.exposure.mode != .manualBoth
        case .iso:
            return engine.exposure.mode != .manualISO && engine.exposure.mode != .manualBoth
        case .focus:
            return engine.focus.mode != .manual
        case .exposure:
            return !exposureManual
        case .whiteBalance:
            return engine.whiteBalance.mode != .manual
        }
    }

    /// 第一次按只选中；已选中的再按一次切自动 / 手动。
    private func tap(_ parameter: LandscapeParameter) {
        guard selection == parameter else {
            selection = parameter
            return
        }
        toggleAuto(parameter)
    }

    private func toggleAuto(_ parameter: LandscapeParameter) {
        let targetAuto = !isAuto(parameter)
        switch parameter {
        case .shutter:
            let isoAuto = isAuto(.iso)
            switch (targetAuto, isoAuto) {
            case (true, true): engine.exposure.mode = .autoBoth
            case (true, false): engine.exposure.mode = .manualISO
            case (false, true): engine.exposure.mode = .manualShutter
            case (false, false): engine.exposure.mode = .manualBoth
            }
        case .iso:
            let shutterAuto = isAuto(.shutter)
            switch (targetAuto, shutterAuto) {
            case (true, true): engine.exposure.mode = .autoBoth
            case (true, false): engine.exposure.mode = .manualShutter
            case (false, true): engine.exposure.mode = .manualISO
            case (false, false): engine.exposure.mode = .manualBoth
            }
        case .focus:
            engine.focus.mode = targetAuto ? .continuous : .manual
        case .exposure:
            exposureManual = !targetAuto
            if targetAuto { engine.exposure.ev = 0 }
        case .whiteBalance:
            engine.whiteBalance.mode = targetAuto ? .auto : .manual
        }
    }

    private func setAllAuto() {
        engine.exposure.mode = .autoBoth
        engine.exposure.ev = 0
        exposureManual = false
        engine.focus.mode = .continuous
        engine.whiteBalance.mode = .auto
    }

    // MARK: - 拖拽条取值

    private var sliderBinding: Binding<Double> {
        Binding(get: { position }, set: { apply(position: $0) })
    }

    private var position: Double {
        switch selection {
        case .shutter: return engine.exposure.shutterSliderPosition
        case .iso: return engine.exposure.isoSliderPosition
        case .focus: return Double(engine.focus.lensPosition)
        case .exposure: return normalize(Double(engine.exposure.ev), -3, 3)
        case .whiteBalance: return normalize(Double(engine.whiteBalance.temperature), 2000, 9000)
        }
    }

    private func apply(position t: Double) {
        switch selection {
        case .shutter:
            engine.exposure.shutterSliderPosition = t
        case .iso:
            engine.exposure.isoSliderPosition = t
        case .focus:
            engine.focus.mode = .manual
            engine.focus.lensPosition = Float(t)
        case .exposure:
            exposureManual = true
            engine.exposure.ev = Float(denormalize(t, -3, 3))
        case .whiteBalance:
            engine.whiteBalance.mode = .manual
            engine.whiteBalance.temperature = Float(denormalize(t, 2000, 9000))
        }
    }

    private func normalize(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard high > low else { return 0 }
        return min(max((value - low) / (high - low), 0), 1)
    }

    private func denormalize(_ position: Double, _ low: Double, _ high: Double) -> Double {
        low + (high - low) * min(max(position, 0), 1)
    }

    // MARK: - 读数

    private func knobValue(_ parameter: LandscapeParameter) -> String {
        switch parameter {
        case .shutter:
            return engine.exposure.formatShutter(
                engine.exposure.liveShutterSeconds > 0
                    ? engine.exposure.liveShutterSeconds
                    : engine.exposure.shutterSeconds
            )
        case .iso:
            let live = engine.exposure.liveISO
            return String(format: "%.0f", live > 0 ? live : engine.exposure.iso)
        case .focus:
            return String(format: "%.2f", engine.focus.liveLensPosition)
        case .exposure:
            return String(format: "%+.1f", engine.exposure.ev)
        case .whiteBalance:
            let live = engine.whiteBalance.liveTemperature
            return String(format: "%.0f", live > 0 ? live : engine.whiteBalance.temperature)
        }
    }

    private func readout(_ parameter: LandscapeParameter) -> String {
        switch parameter {
        case .shutter:
            return engine.exposure.formatShutter(engine.exposure.liveShutterSeconds)
        case .iso:
            return String(format: "ISO %.0f", engine.exposure.liveISO)
        case .focus:
            return String(format: "%.2f", engine.focus.liveLensPosition)
        case .exposure:
            return String(format: "%+.1f EV", engine.exposure.ev)
        case .whiteBalance:
            let live = engine.whiteBalance.liveTemperature
            return String(format: "%.0fK", live > 0 ? live : engine.whiteBalance.temperature)
        }
    }

    // MARK: - 格式化

    private func timecode(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds >= 3600 { return String(format: "%.1fh", seconds / 3600) }
        if seconds >= 60 { return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
        return String(format: "0:%02d", Int(seconds))
    }
}
