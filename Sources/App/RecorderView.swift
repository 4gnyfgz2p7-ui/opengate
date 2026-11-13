import SwiftUI
import UniformTypeIdentifiers
import UIKit
import AVFoundation

/// 拍摄主界面外壳。
///
/// 版式已经全部交给两个独立界面：
/// - 横屏 → `Sources/Landscape/LandscapeScreen`
/// - 竖屏 → `Sources/Portrait/PortraitScreen`
///
/// 这里只剩四件事：按窗口方向选界面、方向申请、顶部弹窗、设置入口。
/// 不再持有任何布局数字——上一版三套版式混在一个 1400 行的文件里，
/// 改一处要翻到底，隔离也无从谈起。
struct RecorderView: View {

    @StateObject private var engine = RecordingEngine()
    @State private var showSettings = false
    /// 最近一次「窗口方向与拍摄方向一致」时的尺寸与方向。
    /// 方向切换的过渡期（窗口还没转到位）沿用它渲染，内容跟着窗口转过去，
    /// 全程不闪黑。
    @State private var cachedLayout: CachedLayout?
    /// 顶部小弹窗。录制失败、自动停止这类「必须看见」的消息走这里，
    /// 3 秒自动消失。
    @State private var banner: String?
    @State private var bannerTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    var onShowProbe: () -> Void

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
            let landscape = size.width > size.height
            let captureLandscape = engine.rotationDegrees == 0 || engine.rotationDegrees == 180
            // 窗口方向与拍摄方向一致才用当前尺寸算布局；
            // 切换过渡期沿用最近合法布局，内容随窗口转过去再就位。
            let inSync = landscape == captureLandscape

            ZStack(alignment: .topLeading) {
                Color.black

                if inSync {
                    screen(landscape: landscape)
                } else if let cached = cachedLayout {
                    Color.clear
                        .overlay {
                            screen(landscape: cached.landscape)
                                .frame(width: cached.size.width, height: cached.size.height)
                        }
                }
            }
            .frame(width: size.width, height: size.height)
            .onChange(of: size, initial: true) { _, newSize in
                // 旋转链路监测：窗口尺寸/安全区/方向，含实际像素分辨率
                let scene = foregroundScene
                RotationMonitor.shared.noteWindow(
                    size: newSize,
                    insets: windowInsets,
                    scale: scene?.screen.scale ?? 3,
                    orientationName: scene.map { orientationName($0.interfaceOrientation) } ?? "未知"
                )
                let capLandscape = engine.rotationDegrees == 0 || engine.rotationDegrees == 180
                if (newSize.width > newSize.height) == capLandscape {
                    cachedLayout = CachedLayout(size: newSize, landscape: newSize.width > newSize.height)
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
            // 一次申请被拒（弹层、系统忙）时补一次：1.2 秒后方向还没到位就重发。
            // 这就是「切不到横屏」的最后一道保险。
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard engine.rotationDegrees == degrees else { return }
                let target: UIInterfaceOrientation = (degrees == 0 || degrees == 180) ? .landscapeRight : .portrait
                if foregroundScene?.interfaceOrientation != target {
                    forceInterface(degrees)
                }
            }
        }
        // 设置里改了方向：弹层收起的瞬间窗口才转得动，
        // 所以关掉之后再补一次申请，保证界面和选择一致。
        .onChange(of: showSettings) { _, shown in
            guard !shown else { return }
            forceInterface(engine.rotationDegrees)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                forceInterface(engine.rotationDegrees)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(engine: engine, onShowProbe: onShowProbe)
        }
    }

    /// 过渡期缓存的整块布局（含当时的窗口方向）
    private struct CachedLayout {
        let size: CGSize
        let landscape: Bool
    }

    /// 两个界面都自己算版式、自己取安全区，这里只做入口。
    @ViewBuilder
    private func screen(landscape: Bool) -> some View {
        let insets = windowInsets
        let edge = EdgeInsets(
            top: insets.top,
            leading: insets.left,
            bottom: insets.bottom,
            trailing: insets.right
        )
        if landscape {
            LandscapeScreen(
                engine: engine,
                banner: banner,
                insets: edge,
                onSettings: { showSettings = true }
            )
        } else {
            PortraitScreen(
                engine: engine,
                banner: banner,
                insets: edge,
                onSettings: { showSettings = true }
            )
        }
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
        (degrees == 0 || degrees == 180) ? .landscapeRight : .portrait
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
    /// `degrees`、`AVCaptureConnection.videoRotationAngle`、窗口 interface orientation。
    ///
    /// 0° 与 180° 都落到横屏（横拍 B 时窗口仍是横的，只是预览镜像），
    /// 90° 与 270° 都落到竖屏。方向只分横竖两档，不再四向轮转。
    private func forceInterface(_ degrees: CGFloat) {
        let monitor = RotationMonitor.shared
        let landscape = degrees == 0 || degrees == 180
        let mask: UIInterfaceOrientationMask = landscape ? .landscapeRight : .portrait
        let targetName = landscape ? "landscapeRight(横屏)" : "portrait(竖屏)"
        monitor.note("锁定支持面 \(targetName)")

        guard let scene = foregroundScene else {
            monitor.note("没有可用的前台 scene，几何申请未发出")
            return
        }
        let target: UIInterfaceOrientation = landscape ? .landscapeRight : .portrait
        monitor.noteRequest(targetName, target: target, scene: scene)
        guard scene.interfaceOrientation != target else { return }

        // 两条铁律，缺一就被 UISceneErrorDomain 101 拒：
        // 1) 申请挪出 SwiftUI 更新事务，下一轮 runloop 执行；
        // 2) 根视图控制器会缓存首次查到的支持方向（launch 时），
        //    改完 AppDelegate 支持面必须先 setNeedsUpdateOfSupportedInterfaceOrientations
        //    让它重查，再发申请。
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
                    interfaceSection
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

    /// 界面方向：横屏（默认）/ 竖屏。
    /// 低一层的入口在画面里——镜头那一行末尾有个小按钮，随手能切；
    /// 这里是「记住选择」的地方，也是开机默认值的唯一来源。
    private var interfaceSection: some View {
        section("界面方向") {
            HStack(spacing: 8) {
                ForEach(InterfaceMode.allCases) { mode in
                    Button {
                        switchInterface(to: mode)
                    } label: {
                        Text(mode.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(engine.rotation.mode == mode ? Color.black : Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(
                                    engine.rotation.mode == mode
                                        ? accent
                                        : Color.white.opacity(0.08)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("默认横屏。切换后会立即重排，选择会被记住，下次打开沿用。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    /// 弹层还在时窗口转不动，所以先收起再转；收起后外层会补一次申请。
    private func switchInterface(to mode: InterfaceMode) {
        guard engine.rotation.mode != mode else { return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            engine.setInterfaceMode(mode)
        }
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
            row("本档可录", CameraFormat.duration(engine.remainingSeconds))
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
