import Foundation
import AVFoundation
import Combine
import CoreGraphics

/// 录制状态机。
enum RecordingState: Equatable {
    case idle
    case preparing(String)
    case recording
    case finishing
    case finished
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .recording, .finishing: return true
        case .idle, .finished, .failed: return false
        }
    }

    var canStart: Bool {
        switch self {
        case .idle, .finished, .failed: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "待机"
        case .preparing(let text): return text
        case .recording: return "录制中"
        case .finishing: return "正在封盘…"
        case .finished: return "已完成"
        case .failed(let reason): return reason
        }
    }
}

/// 跨线程持有 recorder 的盒子。
/// 采集回调在后台队列，创建/销毁在主线程，靠锁隔开。
final class RecorderBox {
    private let lock = NSLock()
    private var value: MovieRecorder?

    func set(_ recorder: MovieRecorder?) {
        lock.lock(); defer { lock.unlock() }
        value = recorder
    }

    func get() -> MovieRecorder? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// 采集通路的计数快照。
///
/// 出问题时把「收帧 / 转换 / 写入」三个数字直接写在界面上，
/// 一眼就能分清是没收到帧、转换失败，还是编码器拒收。
final class FrameStats {
    struct Snapshot {
        var delivered = 0
        var converted = 0
        var appended = 0
        var lastFailure: String?
        var diagnostics: String?
        var diagnosticsDetail: String?
    }

    private let lock = NSLock()
    private var delivered = 0
    private var converted = 0
    private var appended = 0
    private var lastFailure: String?
    private var diagnostics: String?
    private var diagnosticsDetail: String?

    func markDelivered() { lock.lock(); delivered += 1; lock.unlock() }
    func markConverted() { lock.lock(); converted += 1; lock.unlock() }
    func markAppended() { lock.lock(); appended += 1; lock.unlock() }

    func markFailure(_ stage: String) { lock.lock(); lastFailure = stage; lock.unlock() }

    /// `detail` 是写进视频文件元数据的机器可读串，`text` 是给人看的一行摘要
    func markDiagnostics(_ text: String, detail: String? = nil) {
        lock.lock()
        diagnostics = text
        if let detail = detail { diagnosticsDetail = detail }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        delivered = 0; converted = 0; appended = 0
        lastFailure = nil; diagnostics = nil; diagnosticsDetail = nil
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            delivered: delivered,
            converted: converted,
            appended: appended,
            lastFailure: lastFailure,
            diagnostics: diagnostics,
            diagnosticsDetail: diagnosticsDetail
        )
    }
}

/// Bayer 转换很贵（19 MB 拷贝 + 1270 万像素 demosaic），
/// 源却按 60 fps 送帧。这里按 30 fps 放行，写入端再按 24 帧网格去重。
/// 设备 AWB 增益的跨线程传递。
///
/// 采集回调跑在专用队列上，而 `deviceWhiteBalanceGains` 只能在持有设备的
/// 线程上取；主线程算好写进来，回调只做一次加锁读。
final class WBGainsBox {
    private let lock = NSLock()
    private var value: (red: Float, blue: Float)?

    func set(red: Float, blue: Float) {
        lock.lock()
        value = (red, blue)
        lock.unlock()
    }

    func get() -> (red: Float, blue: Float)? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class FrameGate {
    private let lock = NSLock()
    private var last: CMTime = .invalid
    private let minimumInterval = 1.0 / 30.0

    func passes(_ pts: CMTime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pts.isValid else { return true }
        if last.isValid {
            let delta = CMTimeGetSeconds(CMTimeSubtract(pts, last))
            if delta.isFinite, delta >= 0, delta < minimumInterval { return false }
        }
        last = pts
        return true
    }
}

/// 把定位、采集、编码、落盘串起来。
@MainActor
final class RecordingEngine: ObservableObject {

    // MARK: - 对外状态

    @Published private(set) var state: RecordingState = .idle
    @Published var tier: QualityTier = .hevcLongGOP {
        didSet {
            // 录制中不允许切档：四档编码器参数不同，必须停录重建
            if state.isBusy && tier != oldValue {
                tier = oldValue
                return
            }
            guard tier != oldValue else { return }

            resetTierScopedState()

            // 白平衡按档位隔离：RAW 强制手动锁定，其它档恢复用户原来的设定。
            // 两边必须成对调用，否则录完 RAW 回到 HEVC 会一直停在锁死的白平衡上。
            if tier.isRawBayer {
                whiteBalance.enterRawMode()
            } else {
                whiteBalance.exitRawMode()
            }

            // ProRes RAW 的前提是全幅 Bayer 直通。会话一旦降级成系统 ISP，
            // 再切回来也不会自动恢复，必须在切档的这一刻重建会话。
            if tier.isRawBayer {
                Task { [weak self] in
                    await self?.rebuildSessionForRawIfNeeded()
                }
            }
        }
    }

    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var writtenBytes: Int64 = 0
    @Published private(set) var droppedFrames: Int64 = 0
    @Published private(set) var thermalNote: String?
    @Published private(set) var captureConfiguration: CaptureController.Configuration?
    @Published private(set) var lastLocationText: String = "尚未取位置"
    @Published private(set) var lastLocationDegraded = false
    @Published private(set) var history: [MovieRecorder.Outcome] = []
    @Published private(set) var sessionReady = false
    /// 录制中被空间逼停的原因，用于界面提示
    @Published private(set) var autoStopReason: String?

    /// 当前生效的拍摄角度。转发自 `rotation`，让主界面能观察到变化。
    @Published private(set) var rotationDegrees: CGFloat = 90

    // MARK: - 依赖

    let capture = CaptureController()
    let location = LocationProvider()
    let exposure = ExposureController()
    let whiteBalance = WhiteBalanceController()
    let focus = FocusController()
    let waveform = WaveformSampler()
    let rotation = CaptureRotation()

    /// 波形图。6 Hz 更新，不是每帧。
    @Published private(set) var waveformImage: CGImage?
    /// 与波形图同批更新的削波读数：登顶＝高光已削平，触底＝暗部压死。
    @Published private(set) var waveformReading: WaveformSampler.Reading = .empty

    /// 波形开关。关掉后连采样都不做，省电而不只是省绘制。
    @Published var waveformEnabled = true {
        didSet { waveform.setEnabled(waveformEnabled) }
    }

    private let recorderBox = RecorderBox()

    /// 中转任务：录制时落 ProRes RAW，停止后转成用户选的档位。
    /// 记下临时文件与最终目标，成功后删临时文件，失败则保留素材。
    private var relayPending: (raw: URL, final: URL, tier: QualityTier)?
    /// 中转用的元数据在开录时生成一次，转码时复用，避免丢失拍摄信息
    private var relayMetadata: [AVMetadataItem] = []
    /// 自校准结果缓存。采集回调每帧都要用它，不能每帧读 UserDefaults。
    nonisolated(unsafe) private static var bayerSolution = BayerSelfCalibration.saved
    private var recordingStart: Date?
    private var tickTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var prepareTask: Task<Void, Never>?

    /// 全幅 Bayer 直出的唯一出路。初始化失败（Metal 不可用）时为 nil，
    /// 采集层会据此降级到系统 ISP 格式，而不是硬录出一个 0 字节文件。
    private let bayerConverter = BayerConverter()
    private let stats = FrameStats()
    private var recovering = false

    /// 设备 AWB 增益（绿归一），供采集回调读取
    private let wbGains = WBGainsBox()

    /// 管线降级说明，显示在设置页
    @Published private(set) var pipelineNote: String?

    /// 定位等待上限（秒）。够拿到冷启动首次定位的概率不高，
    /// 但配合 60 秒内的缓存足以覆盖连续拍摄场景。
    var locationTimeout: TimeInterval = 3.0

    // MARK: - 生命周期

    init() {
        wireCapture()
        observeThermalState()
        forwardRotation()
    }

    /// 把手动设定的角度转发成引擎状态。
    /// 主界面只需观察 `rotationDegrees`，不必自己订阅旋转控制器。
    private func forwardRotation() {
        rotation.$degrees
            .sink { [weak self] value in self?.rotationDegrees = value }
            .store(in: &cancellables)
    }

    private func wireCapture() {
        let box = recorderBox
        let sampler = waveform
        let converter = bayerConverter
        let gate = FrameGate()
        let statsBox = stats
        let wbBox = wbGains

        capture.onVideoSample = { [weak self] buffer in
            let recorder = box.get()
            guard let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else {
                recorder?.appendVideo(buffer)
                return
            }

            statsBox.markDelivered()
            var monitorable = imageBuffer

            // 全幅格式只吐 Bayer：先 demosaic 成 BGRA 再交给编码器。
            // 不做这一步 append 会被逐帧拒绝，文件停在 0 字节。
            if CVPixelBufferGetPixelFormatType(imageBuffer) == BayerConverter.bayerFormat {
                // 一次性诊断：把设备交付的 btp2 原始字节原样落盘（前两帧）。
                // 自研解包与官方 ProRes RAW 解码器对不上，只能拿真字节在 PC 上
                // 逐种排法还原比对，判据在这件事上已经不可信了。
                BayerDump.capture(imageBuffer)

                // 设备实际按 60 fps 供帧（会话启动会把帧时长改回默认），
                // 而写入只要 24 帧/秒。逐帧 demosaic 等于白烧 2.5 倍算力，
                // 先按 30 fps 掐一道，重复格点再交给写入端去重。
                guard gate.passes(CMSampleBufferGetPresentationTimeStamp(buffer)) else { return }

                // ProRes RAW：原始 Bayer 原样进容器，不做 demosaic、不做色彩处理。
                // 解码责任交给 Apple 的 ProRes RAW 解码器（Final Cut / DaVinci），
                // 这条路径完全不经过本机的 btp2 解包，因此不受排法问题影响。
                // 波形图不更新：没有可读的 RGB 画面。
                if recorder?.isRawBayer == true {
                    if recorder?.appendImageBuffer(
                        imageBuffer,
                        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(buffer)
                    ) == true {
                        statsBox.markAppended()
                    }
                    return
                }

                // 没有转换器时**绝不能**把 btp2 原样交给编码器：
                // 那正是早先“能录、但成片纯绿”的来源。宁可报错。
                guard let converter = converter else {
                    let reason = BayerConverter.compileNote ?? "未知原因"
                    statsBox.markFailure("Bayer 转换器不可用：" + reason)
                    return
                }

                guard let converted = converter.convert(
                    imageBuffer,
                    parameters: RecordingEngine.bayerParameters(from: imageBuffer, wb: wbBox.get())
                ) else {
                    let diag = converter.lastDiagnostics
                    statsBox.markDiagnostics(diag.summary, detail: diag.metadataText)
                    if let stage = converter.lastFailureStage { statsBox.markFailure(stage) }
                    return
                }

                monitorable = converted
                statsBox.markConverted()

                // 系统 AE 不可用时的兜底测光。每半秒取一帧，量的是**转换后的
                // BGRA**（已含 REC.709 传递函数），所以目标值直接按画面观感定，
                // 不用再折算线性 raw。
                let stamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
                if Int((stamp * 24).rounded()) % 12 == 0,
                   let mean = RecordingEngine.meanLuma(converted) {
                    Task { @MainActor in
                        self?.applyFallbackAutoExposure(mean: mean)
                    }
                }
                let diag = converter.lastDiagnostics
                statsBox.markDiagnostics(diag.summary, detail: diag.metadataText)
                if recorder?.appendImageBuffer(
                    converted,
                    presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(buffer)
                ) == true {
                    statsBox.markAppended()
                }
            } else {
                // ProRes RAW 只认未解码的 Bayer。走到这里说明当前格式是
                // 系统 ISP 已经处理过的 YUV，再往 RAW 写入器里塞一定被拒，
                // 与其静默出 0 字节文件，不如把原因说清楚。
                if recorder?.isRawBayer == true {
                    statsBox.markFailure("ProRes RAW 需要全幅 Bayer 源，当前格式不支持")
                    return
                }
                // 编码写入必须在采集队列上同步完成，不能异步延后
                if recorder?.appendVideo(buffer) == true { statsBox.markAppended() }
            }

            // 波形采样同队列串行执行（约 1.3 万次读取），
            // 只有产出新图时才跳回主线程，避免每帧都触发一次线程切换。
            if let image = sampler.process(monitorable) {
                let reading = sampler.currentReading()
                Task { @MainActor in
                    self?.waveformImage = image
                    self?.waveformReading = reading
                }
            }
        }
        capture.onAudioSample = { buffer in
            box.get()?.appendAudio(buffer)
        }
    }

    /// 从设备取一次 AWB 增益写进盒子里。
    ///
    /// 录制期间白平衡是锁定的（解包后按场景自定或按设备值），所以只需要
    /// 在开录前取一次。取不到就留空，标定会退回灰度世界。
    @MainActor
    private func refreshWhiteBalanceGains() {
        guard let device = capture.videoDevice else { return }
        let gains = device.deviceWhiteBalanceGains
        guard gains.greenGain > 0.0001 else { return }
        let red = gains.redGain / gains.greenGain
        let blue = gains.blueGain / gains.greenGain
        // 越界说明这组值不可用（设备还没收敛），交给灰度世界
        guard red > 0.2, red < 5, blue > 0.2, blue < 5 else { return }
        wbGains.set(red: red, blue: blue)
    }

    /// 切档时清掉所有「只对某一档成立」的临时状态。
    ///
    /// 不清会串味，而且串得很难查：
    /// - `pipelineNote`：HEVC 降级留下「已切到系统 ISP」，切到 RAW 时若会话
    ///   本来就在 Bayer 通路上（不需要重建），这句会一直挂着，与实际状态矛盾；
    ///   反过来 RAW 失败留下的「没拿到全幅 Bayer」也会挂到 HEVC 上。
    /// - 帧统计：上一档累计的 converted 会让新档的 3 秒自查误判「通路是通的」，
    ///   该降级的场景不降级。
    /// - 波形：RAW 档不解码也就没有波形，不清会停在上一个档的最后一张图上。
    private func resetTierScopedState() {
        stats.reset()
        pipelineNote = nil
        autoStopReason = nil
        elapsed = 0
        writtenBytes = 0
        droppedFrames = 0
        waveformImage = nil
        waveformReading = .empty
    }

    /// 切到 ProRes RAW 时，如果会话还在系统 ISP 通路上就重建一次。
    ///
    /// 降级到 420v 是一次性的——`recoverPipelineIfNeeded` 不会自己升回来，
    /// 而 RAW 写入器只认 Bayer，所以这一档必须先强制走 `bayerDirect`。
    private func rebuildSessionForRawIfNeeded() async {
        guard !recovering, !state.isBusy else { return }
        guard captureConfiguration?.isBayer != true else { return }

        recovering = true
        capture.stop()
        exposure.detach()
        whiteBalance.detach()
        focus.detach()

        let config = capture.configure(
            path: .bayerDirect,
            audioEnabled: true,
            canProcessBayer: bayerConverter != nil
        )
        captureConfiguration = config
        capture.start()
        if let device = capture.videoDevice {
            exposure.attach(to: device)
            whiteBalance.attach(to: device)
            focus.attach(to: device)
            refreshWhiteBalanceGains()
        }
        sessionReady = capture.isRunning
        stats.reset()
        recovering = false
        pipelineNote = config.isBayer
            ? ""
            : "ProRes RAW 档没拿到全幅 Bayer 通路"
        if !state.isBusy { state = .idle }
    }

    /// 从 Bayer 帧的附件里取黑电平 / 白电平 / 白平衡增益。
    ///
    /// 这些值跟着每一帧走（自动白平衡时每帧都在变），所以不缓存。
    /// 读不到就用 12-bit 的常规默认值：黑 0、白 4095、增益 1——
    /// 画面会偏一点，但不会因为缺一个键就完全不出来。
    nonisolated static func bayerParameters(
        from buffer: CVPixelBuffer,
        wb: (red: Float, blue: Float)? = nil
    ) -> BayerConverter.Parameters {
        var parameters = BayerConverter.Parameters()
        // 自校准算出的位序锁死在这里：搜索出来的 mode 一直与官方解码对不上，
        // 有了标准答案反推的结果就不该再让判据改回去。
        if let solution = bayerSolution, solution.score > 0.90 {
            parameters.lockMode = solution.mode
            parameters.pattern = solution.pattern
        }

        guard let attachments = CMCopyDictionaryOfAttachments(
            allocator: kCFAllocatorDefault,
            target: buffer,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        ) as? [String: Any] else { return parameters }

        var black = scalar(attachments["ProResRAW_BlackLevel"]) ?? 0
        var white = scalar(attachments["ProResRAW_WhiteLevel"]) ?? 4095
        if white > 0 && white <= 1.0 {
            // 归一化表示
            black *= 4095
            white *= 4095
        } else if white > 4095 {
            // 16-bit 容器
            let scale = 4095.0 / white
            black *= scale
            white *= scale
        }
        if black < 1 {
            // 设备没给黑电平时按 ProRes RAW 规范兜底：black_level 固定 0x100
            // （16-bit 容器），换算到 12-bit 就是 16。用 0 等于不扣黑，
            // 暗部底噪被当成信号，画面上是发灰、色相发虚。
            black = 16
        }
        parameters.blackLevel = max(0, black)
        parameters.whiteLevel = max(parameters.blackLevel + 1, white)

        // 白平衡用设备自己的 AWB 增益，不用 ProResRAW_WhiteBalance*Factor。
        // 后者量纲不明（0.5.14 按它乘完画面偏品红）；而 deviceWhiteBalanceGains
        // 是 Apple 相机 AWB 的原始输出，对这颗传感器的光谱响应与当前光源都已收敛，
        // 正是我们想要的。"绿归一"之后直接可以当 RGB 乘数用。
        if let wb = wb, wb.red > 0, wb.blue > 0 {
            parameters.redGain = wb.red
            parameters.blueGain = wb.blue
        }

        if let pattern = scalar(attachments["ProResRAW_BayerPattern"]) {
            // 设备上报的枚举与内部下标不是同一套：iPhone 17 Pro Max 在 btp2
            // 通路上恒定报 3，而真实排列是 RGGB（四种相位解出的相邻色度跳变
            // 149 vs 1284，分离 8.6 倍）。这里仍按下标存，相位由标定的统计
            // 判据裁决——两者不同族时统计值优先，所以上报值错了也不会带走相位。
            let index = Int(pattern)
            if index >= 0 && index < 4 { parameters.pattern = Int32(index) }
        }
        return parameters
    }

    private nonisolated static func scalar(_ value: Any?) -> Float? {
        if let number = value as? NSNumber { return number.floatValue }
        if let array = value as? [NSNumber], !array.isEmpty {
            let total = array.reduce(Float(0)) { $0 + $1.floatValue }
            return total / Float(array.count)
        }
        return nil
    }

    /// 把 CMSampleBuffer 里的画面换成转换后的 YUV 缓冲，时间戳原样保留。
    private nonisolated static func replacingImageBuffer(
        of sampleBuffer: CMSampleBuffer,
        with imageBuffer: CVPixelBuffer
    ) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let description = formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: .invalid
        )

        var rebuilt: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &rebuilt
        )
        guard status == noErr else { return nil }
        return rebuilt
    }

    private func observeThermalState() {
        updateThermalState()
        NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateThermalState() }
            .store(in: &cancellables)
    }

    private func updateThermalState() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            thermalNote = nil
        case .fair:
            thermalNote = "机身偏热，编码器可能降频"
        case .serious:
            thermalNote = "机身过热，可能出现丢帧"
        case .critical:
            thermalNote = "过热，建议停止录制"
        @unknown default:
            thermalNote = nil
        }
    }

    // MARK: - 准备

    /// 请求相机与麦克风权限，然后建立采集会话。
    func prepareSession() {
        guard prepareTask == nil else { return }
        prepareTask = Task { [weak self] in
            guard let self = self else { return }

            let cameraOK = await Self.requestAccess(for: .video)
            guard cameraOK else {
                self.state = .failed("相机权限被拒绝，请到「设置 → A camera」开启")
                self.prepareTask = nil
                return
            }
            _ = await Self.requestAccess(for: .audio)

            let config = self.capture.configure(
                path: .systemProcessed,
                audioEnabled: true,
                canProcessBayer: self.bayerConverter != nil
            )
            self.captureConfiguration = config
            self.capture.start()
            self.sessionReady = self.capture.isRunning

            // 会话跑起来之后再接管曝光与白平衡：此时 activeFormat 已生效，
            // ISO 与快门范围才是这台设备真正可用的范围。
            if let device = self.capture.videoDevice {
                self.exposure.attach(to: device)
                self.whiteBalance.attach(to: device)
            }
            if self.bayerConverter == nil {
                let reason = BayerConverter.compileNote ?? "未知原因"
                self.pipelineNote = "Bayer 转换器不可用：" + reason
            }
            self.prepareTask = nil

            // 三秒后自查一次：全幅 Bayer 通路要是连一帧都转换不出来，
            // 立刻换系统 ISP 格式，而不是让用户录出一个 0 字节文件。
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.recoverPipelineIfNeeded()
            }
        }
    }

    func teardownSession() {
        exposure.detach()
        whiteBalance.detach()
        focus.detach()
        capture.stop()
        sessionReady = false
    }

    /// 全幅通路没跑通时自动降级到系统 ISP。
    ///
    /// 判据刻意做得保守：三秒内**一帧都没转换出来**才算失败。
    /// 降级后分辨率为 4032×3024（真 4:3），但录制能出片——
    /// 比留一个打不开的 0 字节文件有用。
    ///
    /// ProRes RAW 例外：那一档本来就不做 demosaic，`converted` 恒为 0。
    /// 若照旧用它当判据，会话会在三秒后自己切到系统 ISP，
    /// 而 RAW 写入器只收 Bayer，于是第一次点录制必定失败。
    /// 这一档改看「已写入帧数」。
    private func recoverPipelineIfNeeded(force: Bool = false) async {
        guard !recovering, captureConfiguration?.isBayer == true else { return }
        let snap = stats.snapshot
        let progress = tier.isRawBayer ? snap.appended : snap.converted
        guard force || progress == 0 else { return }

        recovering = true
        let stage = snap.lastFailure ?? "未知"
        pipelineNote = "全幅转换未出帧：\(stage)（收帧 \(snap.delivered)），已切到系统 ISP"
        capture.stop()
        exposure.detach()
        whiteBalance.detach()
        focus.detach()

        let config = capture.configure(
            path: .systemProcessed,
            audioEnabled: true,
            canProcessBayer: false
        )
        captureConfiguration = config
        capture.start()
        if let device = capture.videoDevice {
            exposure.attach(to: device)
            whiteBalance.attach(to: device)
            focus.attach(to: device)
            refreshWhiteBalanceGains()
        }
        sessionReady = capture.isRunning
        stats.reset()
        recovering = false
        if !state.isBusy { state = .idle }
        autoStopReason = pipelineNote
    }

    /// 回到前台时重新拉起采集。
    ///
    /// `AVCaptureSession` 在后台会被系统停掉，而 `sessionReady` 还停在 true，
    /// 指示灯是绿的、开关也能按，画面却是黑的——这正是「切一下就没画面」的
    /// 另一半原因。回前台必须无条件检查一次运行状态。
    func resumeSession() {
        guard capture.videoDevice != nil else { return }
        if !capture.isRunning {
            capture.start()
        }
        sessionReady = capture.isRunning
    }

    private static func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    // MARK: - 录制

    func startRecording() {
        guard state.canStart else { return }
        guard sessionReady else {
            state = .failed("采集会话未就绪")
            return
        }
        // ProRes RAW 依赖全幅 Bayer 直通。若会话已经降级成系统 ISP 格式，
        // 写入器一定拒收——在这里就说清楚，而不是录了两秒再报错。
        if tier.isRawBayer, captureConfiguration?.isBayer != true {
            let width = captureConfiguration?.width ?? 0
            let height = captureConfiguration?.height ?? 0
            state = .failed("ProRes RAW 需要全幅 Bayer 通路，当前会话是系统 ISP（\(width)×\(height)）。切走再切回该档位可重建会话。")
            return
        }

        // 开录这一刻取一次设备的 AWB 增益：attach 之后光线可能已经变了，
        // 而录制期间白平衡是锁定的，这一次就是整段的值。
        refreshWhiteBalanceGains()

        let selectedTier = tier
        // 每次开录重读一次校准结果：上次录制可能刚把它算出来
        Self.bayerSolution = BayerSelfCalibration.saved
        // 颜色链路：不再用自研 btp2 解包。
        //
        // 相机给的是 btp2 私有打包，自研解包与官方解码始终对不上
        // （偶/奇位比实测 0.762 vs 官方 1.106，均值差 2.8 倍），
        // 换十几版判据都没找到正确位序。这里改成先按 ProRes RAW 录：
        // 写入器内部用的是 Apple 自己的解包，已在成片上验证正确；
        // 停止后再用 VideoToolbox 解回 bp16（每 sensel 一个 16-bit 值，
        // 不需解包，相位由 buffer attachment 声明），走已验证的色彩管线
        // 重新编码成用户选的档位。
        //
        // 代价是临时空间与一次转码等待，换来的是颜色由 Apple 解码器保证。
        // 自校准一旦成立，自研解包就有了可信位序，可以直接实时录，
        // 不必再走 ProRes RAW 中转（省掉临时空间和转码等待）。
        let needsRelay = !BayerSelfCalibration.hasSolution
        let relay = needsRelay
            && !selectedTier.isRawBayer
            && captureConfiguration?.isBayer == true
        let recordingTier: QualityTier = relay ? .proResRAW : selectedTier
        let width = Int(captureConfiguration?.width ?? 4224)
        let height = Int(captureConfiguration?.height ?? 3024)
        // 角度在按下的瞬间定格：录制中转向不应改变已写文件的显示矩阵
        let degrees = rotation.degrees
        let rotationLabel = rotation.label
        autoStopReason = nil

        Task { [weak self] in
            guard let self = self else { return }

            // ---- 步骤 1：取一次精确位置 ----
            // 必须在建 writer 之前完成，因为元数据要在 startWriting 之前赋好。
            self.state = .preparing("正在获取精确位置…")
            let locationOutcome = await self.location.requestOnce(timeout: self.locationTimeout)
            self.lastLocationText = locationOutcome.displayText
            self.lastLocationDegraded = locationOutcome.isDegraded

            // ---- 步骤 2：空间检查 ----
            self.state = .preparing("正在检查存储…")
            if let spaceError = MovieRecorder.preflightSpaceCheck(tier: recordingTier) {
                self.state = .failed(spaceError.localizedDescription)
                return
            }

            // ---- 步骤 3：建 writer 并写入元数据 ----
            self.state = .preparing("正在准备编码器…")

            // ProRes RAW 需要先完成三件系统要求的事，任何一件不满足都开不了录。
            // 放在建 writer 之前做，是因为白平衡必须先锁定、元数据必须从当前
            // 已启动的会话里取，而且失败原因能直接报给用户，不用等录完发现 0 字节。
            var rawSettings: [String: Any]?
            var rawMetadata: [AVMetadataItem]?
            if recordingTier.isRawBayer {
                let prep = self.capture.prepareProResRAW()
                if let reason = prep.reason {
                    self.state = .failed("ProRes RAW 无法开录：\(reason)")
                    return
                }
                rawSettings = prep.settings
                rawMetadata = prep.metadata
            }

            let startedAt = Date()
            let outputURL = MovieRecorder.makeOutputURL(tier: recordingTier, date: startedAt)
            let finalURL = relay
                ? MovieRecorder.makeOutputURL(tier: selectedTier, date: startedAt)
                : outputURL

            let context = MovieMetadata.RecordingContext(
                tier: recordingTier,
                width: width,
                height: height,
                frameRate: VideoSettingsBuilder.frameRate,
                colorPipeline: selectedTier.isRawBayer
                    ? "proresraw-bayer-passthrough"
                    : (self.captureConfiguration?.isBayer == true
                        ? "bayer12-demosaic-rec709"
                        : "system-isp-sdr"),
                audioDescription: AudioSettings.description,
                locationOutcome: locationOutcome,
                startedAt: startedAt,
                orientation: rotationLabel,
                pipelineDiagnostics: pipelineDiagnosticsText
            )
            let metadata = MovieMetadata.items(for: context)

            do {
                let recorder = try MovieRecorder(
                    outputURL: outputURL,
                    tier: recordingTier,
                    width: width,
                    height: height,
                    metadata: metadata,
                    withAudio: self.captureConfiguration?.audioEnabled ?? false,
                    appleLog2: false,
                    videoTransform: CGAffineTransform(rotationAngle: degrees * .pi / 180),
                    rawSettings: rawSettings,
                    rawMetadata: rawMetadata
                )
                self.recorderBox.set(recorder)
                self.relayPending = relay
                    ? (raw: outputURL, final: finalURL, tier: selectedTier)
                    : nil
                self.relayMetadata = metadata
                // 中转的这一次顺便把 btp2 原始字节存下来，
                // 转码时用官方解码结果反推位序，成功后就不必再中转
                if relay { BayerDump.enable() }
            } catch {
                self.state = .failed(error.localizedDescription)
                return
            }

            // ---- 步骤 4：开录 ----
            self.recordingStart = Date()
            self.elapsed = 0
            self.writtenBytes = 0
            self.droppedFrames = 0
            self.state = .recording
            self.startTicking()
        }
    }

    func stopRecording() {
        guard case .recording = state else { return }
        state = .finishing
        stopTicking()

        Task { [weak self] in
            guard let self = self else { return }
            guard let recorder = self.recorderBox.get() else {
                self.state = .failed("没有活动的录制器")
                return
            }
            self.recorderBox.set(nil)
            var outcome = await recorder.finish()

            // ---- 中转：把刚录的 ProRes RAW 转成用户选的档位 ----
            if let relay = self.relayPending {
                self.relayPending = nil
                let metadata = self.relayMetadata
                self.state = .finishing
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try RawTranscoder.run(
                            rawURL: relay.raw,
                            outputURL: relay.final,
                            tier: relay.tier,
                            metadata: metadata
                        )
                    }.value
                    // 转码成功才删临时文件；失败保留，素材不能丢
                    try? FileManager.default.removeItem(at: relay.raw)
                    BayerDump.disable()
                    outcome = MovieRecorder.Outcome(
                        url: relay.final,
                        tier: relay.tier,
                        duration: outcome.duration,
                        fileSize: MovieRecorder.fileSize(at: relay.final),
                        writtenVideoFrames: Int64(result.frames),
                        droppedVideoFrames: Int64(result.dropped),
                        writtenAudioBuffers: Int64(result.audioBuffers),
                        discardedAudioBuffers: 0,
                        effectiveFrameRate: outcome.effectiveFrameRate,
                        averageWriteRateMBps: Double(result.frames) / max(result.elapsed, 0.001),
                        finishedCleanly: true,
                        note: "官方解码中转 · \(result.probe) · \(result.gains)"
                    )
                } catch {
                    // 失败时把 RAW 交回给用户，并把原因写进记录
                    outcome = MovieRecorder.Outcome(
                        url: relay.raw,
                        tier: .proResRAW,
                        duration: outcome.duration,
                        fileSize: MovieRecorder.fileSize(at: relay.raw),
                        writtenVideoFrames: outcome.writtenVideoFrames,
                        droppedVideoFrames: outcome.droppedVideoFrames,
                        writtenAudioBuffers: outcome.writtenAudioBuffers,
                        discardedAudioBuffers: outcome.discardedAudioBuffers,
                        effectiveFrameRate: outcome.effectiveFrameRate,
                        averageWriteRateMBps: outcome.averageWriteRateMBps,
                        finishedCleanly: outcome.finishedCleanly,
                        note: "转码失败，已保留 ProRes RAW：\(error.localizedDescription)"
                    )
                }
            }

            self.history.insert(outcome, at: 0)
            self.state = .finished
            self.refreshWrittenBytes()
            // 计时归零：上一段的时长留在 history 里，屏幕上不该继续挂着
            self.elapsed = 0
            self.droppedFrames = 0
        }
    }

    func resetState() {
        guard !state.isBusy else { return }
        state = .idle
        elapsed = 0
        writtenBytes = 0
        droppedFrames = 0
    }

    // MARK: - 计时

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                // 2 Hz 足够读秒，再快只是白白触发 SwiftUI 重绘
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self = self else { return }
                await MainActor.run {
                    guard case .recording = self.state else { return }
                    if let start = self.recordingStart {
                        self.elapsed = Date().timeIntervalSince(start)
                    }
                    // 真实丢帧来自写入器，不能靠墙钟与理论帧率推算
                    if let recorder = self.recorderBox.get() {
                        self.droppedFrames = recorder.liveDroppedFrames

                        // 两秒还没有一帧落进写入器 = 编码器拒收画面。
                        // 继续计时只会得到一个 0 字节文件，不如立刻收手并说明原因。
                        if self.elapsed > 2.0, recorder.liveWrittenFrames == 0 {
                            let snap = self.stats.snapshot
                            let detail = recorder.appendFailureDescription ?? "编码器未接受该画面格式"
                            self.autoStopReason = "画面未能写入（收帧 \(snap.delivered) · 转换 \(snap.converted) · 写入 \(snap.appended)）：\(detail)"
                            // ProRes RAW 只认 Bayer：切到系统 ISP 也喂不进去，
                            // 降级只会把同一个错误重演一遍，不如原地报明原因。
                            let needsFallback = self.captureConfiguration?.isBayer == true
                                && snap.appended == 0
                                && !self.tier.isRawBayer
                            self.stopRecording()
                            // 全幅通路写不进去：这次收尾之后直接换成系统 ISP，
                            // 下一次按录制键就能出片，而不是再失败一遍。
                            if needsFallback {
                                Task { [weak self] in
                                    try? await Task.sleep(nanoseconds: 800_000_000)
                                    await self?.recoverPipelineIfNeeded(force: true)
                                }
                            }
                            return
                        }
                    }
                    self.refreshWrittenBytes()

                    // 空间见底时主动收尾，而不是让 writer 在半路失败：
                    // 正常收尾能保住文件与 moov，失败只会留下无法播放的残片。
                    if self.remainingSeconds < 20 {
                        self.autoStopReason = "存储空间将满，已自动停止并保存"
                        self.stopRecording()
                    }
                }
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// 录制中按已写帧数估算当前体积（真实文件大小要等封盘才准确）
    private func refreshWrittenBytes() {
        if case .recording = state {
            let seconds = elapsed
            writtenBytes = Int64(tier.estimatedMegabytesPerSecond * seconds * 1_000_000)
        } else if let last = history.first {
            writtenBytes = last.fileSize
        }
    }

    // MARK: - 派生信息

    var captureSummary: String {
        guard let config = captureConfiguration else { return "未配置" }
        return "\(config.resolutionText) · \(config.pixelFormat) · \(config.frameRateText)"
    }

    /// 真实画幅比例（宽/高，按显示方向）。4224:3024 = 1.397，不是 4:3。
    var captureAspect: CGFloat {
        guard let config = captureConfiguration, config.height > 0 else {
            return rotation.isLandscape ? 4224.0 / 3024.0 : 3024.0 / 4224.0
        }
        let longSide = CGFloat(max(config.width, config.height))
        let shortSide = CGFloat(min(config.width, config.height))
        let ratio = shortSide > 0 ? longSide / shortSide : 4.0 / 3.0
        return rotation.isLandscape ? ratio : 1.0 / ratio
    }

    /// GPU 自检读数：kernel 有没有进来、读到多大、输出 RGB 的极值
    var pipelineBadge: String {
        stats.snapshot.diagnostics ?? "—"
    }

    /// 写进视频文件的诊断串，录完直接从文件读，不用再截图
    /// 抽样 BGRA 画面的平均亮度（0–1，已含传递函数）。每 24 像素取一个点，
    /// 4224×3024 约 2.2 万点，够稳且不影响帧率。
    nonisolated static func meanLuma(_ buffer: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)

        var sum = 0.0
        var count = 0
        var y = 0
        while y < height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < width {
                let pixel = row + x * 4
                // BGRA
                sum += 0.0722 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.2126 * Double(pixel[2])
                count += 1
                x += 24
            }
            y += 24
        }
        guard count > 0 else { return nil }
        return sum / Double(count) / 255.0
    }

    /// 系统 AE 不可用时的兜底：按画面平均亮度调 ISO。
    ///
    /// 只在两件事同时成立时动手：
    /// 1. 曝光模式是「自动」（用户没选手动，就不该抢他的 ISO）
    /// 2. `activeFormat.isAutoExposureSupported == false` —— 这条格式下
    ///    写 `exposureMode = .continuousAutoExposure` 会被静默忽略，
    ///    画面于是停在默认曝光上，正是「0EV 偏暗」的来源
    ///
    /// 目标 0.42 是画面平均亮度：正常曝光的中灰大约落在 0.4–0.5。
    /// 步长限在 ±40%，半秒一次，避免在灯光边沿来回过冲。
    @MainActor
    private func applyFallbackAutoExposure(mean: Double) {
        guard exposure.mode == .autoBoth else { return }
        guard let device = capture.videoDevice else { return }
        // 判断「系统 AE 到底有没有真的在跑」，只能看实测状态：
        // 已经在 continuousAutoExposure 就交给它，不抢；
        // 我们请求过却仍不在这条模式上，说明这条格式下它被静默忽略了，
        // 这时才接管。一旦接管（写 custom），这个条件会一直成立，控制权稳定。
        guard device.exposureMode != .continuousAutoExposure else { return }
        let error = 0.42 - mean
        guard abs(error) > 0.04 else { return }
        let factor = min(max(1 + error * 1.3, 0.65), 1.5)
        exposure.nudgeISO(factor: factor)
    }

    var pipelineDiagnosticsText: String {
        var text = stats.snapshot.diagnosticsDetail ?? "—"
        // EV 滑块失效、手动对焦没滑块，两个现象都可能是「这条格式下系统
        // 不给这项能力」。把实测能力值写进容器，一次录制就能判定，
        // 不用靠猜：
        //   eb  = min/maxExposureTargetBias，两者相等说明 EV 完全无效
        //   fp  = isLockingFocusWithCustomLensPositionSupported，false 说明只能冻结位置
        if let device = capture.videoDevice {
            text += String(format: "·eb%.1f/%.1f",
                           device.minExposureTargetBias, device.maxExposureTargetBias)
            text += "·fp\(device.isLockingFocusWithCustomLensPositionSupported ? 1 : 0)"
            text += "·fpi\(device.isFocusPointOfInterestSupported ? 1 : 0)"

            // ---- 曝光/对焦的真实运行状态 ----
            //
            // 「默认 0EV 偏暗」到底是系统 AE 没在跑、还是 AE 跑了但亮度曲线不同，
            // 靠猜没有意义，把这四个数写进容器一次就能定：
            //   ae  = isExposureModeSupported(.continuousAutoExposure)。
            //         系统"声称"支持；但如果同时 em≠2，说明写了没生效——
            //         这两项组合起来看，才是"AE 有没有在跑"的可靠判断。
            //         0 或 (1 且 em≠2) 都会让画面停在默认曝光上（"偏暗"）
            //   em  = 实际 exposureMode（0 锁定 / 1 自动 / 2 连续自动 / 3 自定义）
            //   iso / dur = 当前 ISO 与快门（dur 写成 1/x）
            //   ofs = exposureTargetOffset，AE 在跑时应当接近 0
            //   fm / lp   = 对焦模式与镜头实际位置，验证滑块写入有没有落地
            text += "·ae\(device.isExposureModeSupported(.continuousAutoExposure) ? 1 : 0)"
            text += "·em\(device.exposureMode.rawValue)"
            text += "·iso\(Int(device.iso.rounded()))"
            let seconds = CMTimeGetSeconds(device.exposureDuration)
            text += seconds > 0 ? "·dur1/\(Int((1 / seconds).rounded()))" : "·dur?"
            text += String(format: "·ofs%.2f", device.exposureTargetOffset)
            text += "·fm\(device.focusMode.rawValue)"
            text += String(format: "·lp%.2f", device.lensPosition)
            if let error = focus.lastError {
                text += "·fx\(error.prefix(24))"
            }
        }
        return text
    }

    /// 档位旁的一行小字：画面从哪来、多大
    var formatBadge: String {
        guard let config = captureConfiguration else { return "—" }
        return "\(config.width)×\(config.height) · \(config.pixelFormat)"
    }

    var audioSummary: String {
        guard let config = captureConfiguration, config.audioEnabled else { return "无音轨" }
        return AudioSettings.description
    }

    var availableSpaceText: String {
        let bytes = MovieRecorder.availableCapacity(at: MovieRecorder.recordingDirectory())
        guard bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 在当前档位下，可用空间还能录多久（秒）
    var remainingSeconds: Double {
        let bytes = Double(MovieRecorder.availableCapacity(at: MovieRecorder.recordingDirectory()))
        let rate = tier.estimatedMegabytesPerSecond * 1_000_000
        guard rate > 0, bytes > 0 else { return 0 }
        return bytes / rate
    }
}
