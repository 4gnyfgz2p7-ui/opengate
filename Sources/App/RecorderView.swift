import SwiftUI
import UniformTypeIdentifiers
import UIKit
import AVFoundation

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
    /// 最近一次「窗口方向与拍摄方向一致」时的完整布局。
    /// 方向切换的过渡期（窗口还没转到位）沿用它渲染，内容跟着窗口转过去，
    /// 全程不闪黑——黑屏从机制上被消掉，而不是靠缩短时长。
    @State private var cachedLayout: CachedLayout?
    @State private var escapeTask: Task<Void, Never>?
    /// 顶部小弹窗。录制失败、自动停止这类「必须看见」的消息走这里，
    /// 3 秒自动消失——不再指望用户去盯顶部那行 10.5pt 的小字。
    @State private var banner: String?
    @State private var bannerTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

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

    private func flashBanner(_ text: String) {
        banner = text
        bannerTask?.cancel()
        bannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            banner = nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let zones = layoutZones(size: size)
            let landscape = size.width > size.height

            // 窗口方向与拍摄方向一致才用当前尺寸算布局；
            // 方向键按下后、窗口转过去的过渡期沿用最近合法布局
            // （内容随窗口转过去再就位），不再有黑屏过渡帧。
            let captureLandscape = engine.rotationDegrees == 0 || engine.rotationDegrees == 180
            let inSync = landscape == captureLandscape

            // 界面跟着「拍摄方向」按钮走：按一下让窗口本身转过去，
            // 而不是把内容层转 90°（那会把取景和控件各转一次，画面压成一条）。
            ZStack(alignment: .topLeading) {
                Color.black

                if inSync {
                    layoutContent(zones: zones, landscape: landscape)
                } else if let cached = cachedLayout {
                    Color.clear
                        .overlay {
                            layoutContent(zones: cached.zones, landscape: cached.landscape, degrees: cached.degrees)
                                .frame(width: cached.size.width, height: cached.size.height)
                        }
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .top) {
                if let banner {
                    Text(banner)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.74), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                        .padding(.horizontal, 28)
                        .padding(.top, 52)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: banner)
            .onChange(of: size, initial: true) { _, newSize in
                // 旋转链路监测：窗口尺寸/安全区/方向，含实际像素分辨率
                let scene = foregroundScene
                RotationMonitor.shared.noteWindow(
                    size: newSize,
                    insets: windowInsets,
                    scale: scene?.screen.scale ?? 3,
                    orientationName: scene.map { orientationName($0.interfaceOrientation) } ?? "未知"
                )
                // 同步期间刷新最近合法布局缓存（过渡期就靠它撑住画面）
                let capLandscape = engine.rotationDegrees == 0 || engine.rotationDegrees == 180
                if (newSize.width > newSize.height) == capLandscape {
                    cachedLayout = CachedLayout(
                        zones: layoutZones(size: newSize),
                        size: newSize,
                        landscape: newSize.width > newSize.height,
                        degrees: engine.rotationDegrees
                    )
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            engine.prepareSession()
            forceInterface(engine.rotationDegrees)
        }
        .onChange(of: statusMessage) { _, message in
            if let message { flashBanner(message) }
        }
        // 通路降级（Bayer → 系统 ISP）也让用户看见：那时 RAW 一定录不了，
        // 不给提示就表现为「点了录制什么都没发生」。
        .onChange(of: engine.pipelineNote) { _, note in
            if let note { flashBanner(note) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                engine.resumeSession()
                forceInterface(engine.rotationDegrees)
            }
        }
        .onChange(of: engine.rotationDegrees) { _, degrees in
            forceInterface(degrees)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(engine: engine, onShowProbe: onShowProbe)
        }
    }

    // MARK: - 分区

    private struct Zones {
        var preview: CGRect
        var bar: CGRect
        var controls: CGRect
        /// 横屏时的镜头侧竖轨：时间码 + 波形
        var lens: CGRect?
    }

    /// 过渡期缓存的整块布局（含当时的拍摄角度，预览层在过渡期保持原角度不动）
    private struct CachedLayout {
        let zones: Zones
        let size: CGSize
        let landscape: Bool
        let degrees: CGFloat
    }

    /// 三块分区（预览 / 顶栏或镜头侧竖轨 / 控件）的统一装配。
    /// 正常态用当前 zones，过渡态用缓存的 zones。
    @ViewBuilder
    private func layoutContent(zones: Zones, landscape: Bool, degrees: CGFloat? = nil) -> some View {
        previewPane(rect: zones.preview, degrees: degrees ?? engine.rotationDegrees)

        if let lens = zones.lens {
            lensRail(rect: lens)
        } else {
            topBarPane(rect: zones.bar, landscape: false)
        }

        controlsPane(rect: zones.controls, landscape: landscape)
    }

    /// 窗口安全区：横屏时刘海/灵动岛在侧边，不能再按固定 14pt 贴边
    private var windowInsets: UIEdgeInsets {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .keyWindow?.safeAreaInsets ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
    }

    /// 前台 scene（监测与几何申请共用）
    private var foregroundScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private func orientationTarget(_ degrees: CGFloat) -> UIInterfaceOrientation {
        switch Int(degrees.rounded()) {
        case 0: return .landscapeRight
        case 180: return .landscapeLeft
        case 270: return .portraitUpsideDown
        default: return .portrait
        }
    }

    private func orientationName(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait: return "竖"
        case .portraitUpsideDown: return "倒竖"
        case .landscapeLeft: return "横左"
        case .landscapeRight: return "横右"
        default: return "未知"
        }
    }

    /// 拍摄方向 → 窗口方向。三个量必须严格同轴：
    /// `degrees`、`AVCaptureConnection.videoRotationAngle`、窗口 interface orientation，
    /// 即 90→portrait、0→landscapeRight、180→landscapeLeft、270→portraitUpsideDown。
    ///
    /// （旧映射把 180 与 270 写反：横拍 B 被塞进倒竖屏、倒置被塞进横屏，
    /// 布局分支与画幅同时错位——「一转就乱」的主根因。）
    private func forceInterface(_ degrees: CGFloat) {
        let monitor = RotationMonitor.shared
        let mask: UIInterfaceOrientationMask
        let targetName: String
        switch Int(degrees.rounded()) {
        case 0:   mask = .landscapeRight;      targetName = "landscapeRight(横拍A)"
        case 180: mask = .landscapeLeft;       targetName = "landscapeLeft(横拍B)"
        case 270: mask = .portraitUpsideDown;  targetName = "portraitUpsideDown(倒置)"
        default:  mask = .portrait;            targetName = "portrait(竖拍)"
        }
        // 支持面的写入挪到下方 async 块里，与「VC 重查 → 几何申请」同一轮 runloop，
        // 保证裁决链读到的支持面就是本次要申请的方向。
        monitor.note("锁定支持面 \(targetName)")

        guard let scene = foregroundScene else {
            monitor.note("没有可用的前台 scene，几何申请未发出")
            return
        }
        let target = orientationTarget(degrees)
        monitor.noteRequest(targetName, target: target, scene: scene)
        guard scene.interfaceOrientation != target else { return }

        // 两条铁律，缺一就被 UISceneErrorDomain 101 拒（「受支持：portrait」）：
        // 1) 申请挪出 SwiftUI 更新事务，下一轮 runloop 执行；
        // 2) 根视图控制器会缓存首次查到的支持方向（launch 时 = portrait），
        //    改完 AppDelegate 支持面必须先 setNeedsUpdateOfSupportedInterfaceOrientations
        //    让它重查，再发申请——0.5.19 及之前缺第 2 条，前两次申请全被拒，
        //    设备日志实测黑屏 6.7 s 的直接原因。
        DispatchQueue.main.async {
            AppDelegate.supportedMask = mask
            if let root = scene.keyWindow?.rootViewController
                ?? scene.windows.first(where: { !$0.isHidden })?.rootViewController {
                root.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                Task { @MainActor in
                    RotationMonitor.shared.noteRequestResult(error.localizedDescription)
                }
            }
        }
    }

    /// 逃生门：申请若仍被拒，1.5 s 后补发一次（期间缓存布局撑住画面，不会黑屏）。
    private func scheduleEscape(_ degrees: CGFloat) {
        escapeTask?.cancel()
        escapeTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            if escapeNeeded(degrees) {
                forceInterface(degrees)
            }
        }
    }

    private func escapeNeeded(_ degrees: CGFloat) -> Bool {
        guard let scene = foregroundScene else { return false }
        return scene.interfaceOrientation != orientationTarget(degrees)
    }

    /// 三块互不重叠的矩形：顶栏（或镜头侧竖轨）、取景、控件。
    ///
    /// 取景按**真实画幅**算尺寸（4224:3024），并且**贴着镜头侧**：
    /// 镜头侧留 12pt（波形轨 / 顶栏），富余黑区全部留在参数侧。
    /// 黑边只出现在几何上必然出现的那一侧，控件永远落在黑区里。
    private func layoutZones(size: CGSize) -> Zones {
        let insets = windowInsets
        let margin: CGFloat = 12
        let lensGap: CGFloat = 12
        let left = max(margin, insets.left + margin)
        let right = max(margin, insets.right + margin)
        let bottom = max(8, insets.bottom)
        let aspect = engine.captureAspect
        let landscape = size.width > size.height

        if landscape {
            // 镜头在背面左上角：横拍 A（0°）时在左侧，横拍 B（180°）时在右侧。
            // 时间码和波形就放在这条轨道上，绕开画面。
            let lensOnLeading = engine.rotation.degrees != 180
            let railWidth: CGFloat = 104
            let controlsWidth: CGFloat = min(300, size.width * 0.30)
            let top = max(6, insets.top * 0.4)
            let height = max(120, size.height - top - bottom)

            let lens = CGRect(
                x: lensOnLeading ? left : size.width - railWidth - right,
                y: top,
                width: railWidth,
                height: height
            )
            let controls = CGRect(
                x: lensOnLeading ? size.width - controlsWidth - right : left,
                y: top,
                width: controlsWidth,
                height: height
            )

            // 取景贴镜头侧 12pt，参数侧只留 10pt 分隔
            let minX = lensOnLeading ? lens.maxX + lensGap : controls.maxX + 10
            let maxX = lensOnLeading ? controls.minX - 10 : lens.minX - lensGap
            let freeWidth = max(80, maxX - minX)

            var previewWidth = min(height * aspect, freeWidth)
            var previewHeight = previewWidth / aspect
            if previewHeight > height {
                previewHeight = height
                previewWidth = previewHeight * aspect
            }
            let preview = CGRect(
                x: lensOnLeading ? minX : maxX - previewWidth,
                y: top + (height - previewHeight) / 2,
                width: previewWidth,
                height: previewHeight
            )
            return Zones(preview: preview, bar: .zero, controls: controls, lens: lens)
        }

        // ---- 竖屏：先按「镜头在顶部」算，倒置（270°）再整体垂直镜像 ----
        // 镜头/灵动岛那一条短边永远留给顶栏（波形+状态），控件在对面。
        let island = max(insets.top, insets.bottom)
        let other = min(insets.top, insets.bottom)
        let top = max(island - 6, 6)
        let barHeight: CGFloat = 44
        var bar = CGRect(x: left, y: top, width: size.width - left - right, height: barHeight)

        let controlsHeight: CGFloat = 224
        var controls = CGRect(
            x: 0,
            y: size.height - controlsHeight - max(0, other - 18),
            width: size.width,
            height: controlsHeight
        )

        let freeTop = bar.maxY + 8
        let freeBottom = controls.minY - 8
        let freeHeight = max(80, freeBottom - freeTop)

        var width = min(size.width - left - right, freeHeight * aspect)
        var height = width / aspect
        if height > freeHeight {
            height = freeHeight
            width = height * aspect
        }

        // 上贴镜头侧（竖拍镜头在机顶），富余黑区留在控件侧
        var preview = CGRect(
            x: (size.width - width) / 2,
            y: freeTop,
            width: width,
            height: height
        )

        // 倒置握持时镜头落到窗口底部：顶栏、控件、取景一起翻到对应侧
        if Int(engine.rotationDegrees.rounded()) == 270 {
            func flipY(_ r: CGRect) -> CGRect {
                CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
            }
            bar = flipY(bar)
            controls = flipY(controls)
            preview = flipY(preview)
        }
        return Zones(preview: preview, bar: bar, controls: controls, lens: nil)
    }

    /// 横屏的镜头侧竖轨：录制时间码在上，波形在下。
    private func lensRail(rect: CGRect) -> some View {
        VStack(spacing: 8) {
            if isRecording {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    Text(Self.timecode(engine.elapsed))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.45)))
            }

            waveform

            Spacer(minLength: 0)
        }
        .frame(width: rect.width, height: rect.height, alignment: .top)
        .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - 取景

    private func previewPane(rect: CGRect, degrees: CGFloat) -> some View {
        CameraPreviewView(
            session: engine.capture.session,
            rotationDegrees: degrees
        )
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    /// 顶栏：档位 / 波形 / 方向 / 设置，一行放完，不压画面。
    private func topBarPane(rect: CGRect, landscape: Bool) -> some View {
        HStack(spacing: 8) {
            if isRecording {
                recordingTimecode
            } else {
                statusChip
            }
            waveform
            Spacer(minLength: 0)
            topActions
        }
        .frame(width: rect.width, height: rect.height, alignment: .leading)
        .position(x: rect.midX, y: rect.midY)
    }

    private func controlsPane(rect: CGRect, landscape: Bool) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            controls(landscape: landscape, size: rect.size)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - 控件层

    @ViewBuilder
    private func controls(landscape: Bool, size: CGSize) -> some View {
        if isRecording {
            recordingControls(landscape: landscape)
        } else {
            standbyControls(landscape: landscape)
        }
    }

    /// 待机：一块参数面板 + 一行录制条。面板统一底色与圆角，
    /// 不再让曝光、白平衡各自漂一块浮层。
    private func standbyControls(landscape: Bool) -> some View {
        VStack(spacing: 8) {
            if landscape {
                HStack(spacing: 8) {
                    statusChip
                    Spacer(minLength: 0)
                    topActions
                }
            }

            if let message = statusMessage {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red.opacity(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            VStack(spacing: 8) {
                ExposureStrip(exposure: engine.exposure, accent: accent, compact: landscape, embedded: true)
                WhiteBalanceStrip(whiteBalance: engine.whiteBalance, accent: accent, embedded: true)
                FocusStrip(focus: engine.focus, accent: accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )

            recordBar
        }
        .padding(.horizontal, 14)
    }

    /// 录制中只保留：监看画面、时间码、曝光、停止键。
    private func recordingControls(landscape: Bool) -> some View {
        VStack(spacing: 8) {
            VStack(spacing: 6) {
                ExposureStrip(exposure: engine.exposure, accent: accent, compact: true, embedded: true)
                // 录制中也要能调对焦：跟焦是拍摄过程中的常规操作，
                // 只在待机时可用等于这一档用不了。
                FocusStrip(focus: engine.focus, accent: accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )

            stopBar
        }
        .padding(.horizontal, 14)
    }

    // MARK: - 顶部元素

    /// 录制中的时间码：红点 + 时:分:秒
    private var recordingTimecode: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text(Self.timecode(engine.elapsed))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }

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
                    .lineLimit(1)
                // 画面是怎么来的必须写在明面上：
                // 全幅 Bayer 走自建管线，降级时是系统 ISP、尺寸也不一样。
                Text(engine.formatBadge)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
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
                let from = engine.rotationDegrees
                engine.rotation.cycle()
                let to = engine.rotationDegrees
                // 黑屏/无响应的证据链从这里开始：按键瞬间 + 会话状态
                RotationMonitor.shared.notePress(
                    from: from,
                    to: to,
                    sessionReady: engine.sessionReady,
                    sessionRunning: engine.capture.isRunning
                )
                scheduleEscape(to)
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
                .frame(width: 104, height: 40)
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
                    .frame(width: 64, height: 64)

                if engine.state == .recording {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.red)
                        .frame(width: 24, height: 24)
                } else if engine.state.isBusy {
                    ProgressView().tint(.white)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 52, height: 52)
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
    /// 由外层统一画一块面板时，自己不再叠背景
    var embedded: Bool = false

    @State private var isoDraft: Double?
    @State private var shutterDraft: Double?
    @State private var evDraft: Double?

    var body: some View {
        VStack(spacing: compact ? 6 : 8) {
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

            // 全手动：两维都锁死，此时才给一个反算出来的场景 EV
            if exposure.mode == .manualBoth, let ev = exposure.estimatedEV100 {
                HStack(spacing: 6) {
                    Text("EV100")
                        .foregroundStyle(.white.opacity(0.45))
                    Text(String(format: "%.1f", ev))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            }
        }
        .padding(.horizontal, embedded ? 0 : 12)
        .padding(.vertical, embedded ? 0 : 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(embedded ? Color.clear : Color.black.opacity(0.52))
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
    var embedded: Bool = false

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
        .padding(.horizontal, embedded ? 0 : 12)
        .padding(.vertical, embedded ? 0 : 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(embedded ? Color.clear : Color.black.opacity(0.42))
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
    @ObservedObject private var monitor = RotationMonitor.shared

    @Environment(\.dismiss) private var dismiss
    private let accent = Color(red: 0.42, green: 0.85, blue: 0.82)

    /// 离线处理本地文件：输入固定成一个文件，改一版就能对同一段素材比对一次。
    @StateObject private var processor = FileProcessor()
    @State private var showImporter = false
    @State private var showLUTImporter = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    captureSection
                    tierSection
                    storageSection
                    displaySection
                    rotationSection
                    historySection
                    offlineSection
                    lutSection
                }
                .padding(18)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.movie],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { processor.process(url) }
                case .failure(let error):
                    processor.reportPickerFailure(error)
                }
            }
            .fileImporter(
                isPresented: $showLUTImporter,
                allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { processor.importLUT(from: url) }
                case .failure(let error):
                    processor.reportPickerFailure(error)
                }
            }
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
            row("画面通路", engine.captureConfiguration?.pipelineText ?? "—")
            row("像素格式", engine.captureConfiguration?.pixelFormat ?? "—")
            row("GPU 自检", engine.pipelineBadge)
            row("定位", engine.lastLocationText)

            if let note = engine.thermalNote {
                row("机身温度", note)
            }
            if let note = engine.pipelineNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let config = engine.captureConfiguration, !config.notes.isEmpty {
                Text(config.notes.joined(separator: "；"))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
                            Text("\(tier.subtitle) · \(Int(tier.estimatedMegabytesPerSecond)) MB/s")
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
            row("可用空间", engine.availableSpaceText)
            row("本档可录", RecorderView.durationText(engine.remainingSeconds))
            row("已写入", String(format: "%.1f MB", Double(engine.writtenBytes) / 1_000_000))
        }
    }

    private var displaySection: some View {
        section("显示") {
            Toggle(isOn: $engine.waveformEnabled) {
                Text("波形监看")
                    .font(.system(size: 13))
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

    /// 旋转链路时间线：黑屏/无响应的证据，一键分享。
    private var rotationSection: some View {
        section("方向监测") {
            if let pending = monitor.pendingElapsed, pending < 10 {
                Text("几何申请已发出 \(String(format: "%.1f", pending)) s，窗口未跟上")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
            }

            ForEach(Array(monitor.events.reversed().prefix(14))) { event in
                HStack(alignment: .top, spacing: 8) {
                    Text(String(format: "%7.1f", event.t))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(event.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(event.text.hasPrefix("──") ? Color.white.opacity(0.95) : Color.white.opacity(0.72))
                }
            }

            HStack(spacing: 12) {
                ShareLink(item: monitor.logURL) {
                    Text("导出日志")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
                Button {
                    UIPasteboard.general.string = monitor.logText
                } label: {
                    Text("复制")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var offlineSection: some View {
        section("离线处理") {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    showImporter = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text(processor.busy ? "处理中…" : "选择文件")
                        Spacer(minLength: 0)
                        if processor.busy {
                            ProgressView().scaleEffect(0.7)
                        }
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 9)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                .disabled(processor.busy)

                if let toast = processor.toast {
                    HStack(spacing: 6) {
                        Image(systemName: toast.hasPrefix("失败")
                              ? "exclamationmark.triangle.fill"
                              : "checkmark.circle.fill")
                        Text(toast)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(toast.hasPrefix("失败") ? Color.red : Color.green)
                }
            }
        }
    }

    private var lutSection: some View {
        section("LUT") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 12))
                        .foregroundStyle(processor.lutName == nil ? Color.white.opacity(0.35) : accent)
                    Text(processor.lutName ?? "未装入")
                        .font(.system(size: 12))
                        .foregroundStyle(processor.lutName == nil ? Color.white.opacity(0.45) : Color.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if processor.lutBusy {
                        ProgressView().scaleEffect(0.7)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        showLUTImporter = true
                    } label: {
                        Label("导入 .cube", systemImage: "square.and.arrow.down")
                            .font(.system(size: 11.5))
                    }
                    .disabled(processor.lutBusy)

                    if processor.lutName != nil {
                        Button(role: .destructive) {
                            processor.removeLUT()
                        } label: {
                            Text("移除").font(.system(size: 11.5))
                        }
                        .disabled(processor.lutBusy)
                    }
                    Spacer(minLength: 0)
                }

                if processor.lutName != nil {
                    Toggle(isOn: Binding(
                        get: { processor.lutEnabled },
                        set: { processor.setLUTEnabled($0) }
                    )) {
                        Text("转码时烧录 LUT")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .tint(accent)
                }

                if let message = processor.lutMessage {
                    Text(message)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(message.hasPrefix("LUT 导入失败") ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
