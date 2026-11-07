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

/// Bayer 转换很贵（19 MB 拷贝 + 1270 万像素 demosaic），
/// 源却按 60 fps 送帧。这里按 30 fps 放行，写入端再按 24 帧网格去重。
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
    private var recordingStart: Date?
    private var tickTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var prepareTask: Task<Void, Never>?

    /// 全幅 Bayer 直出的唯一出路。初始化失败（Metal 不可用）时为 nil，
    /// 采集层会据此降级到系统 ISP 格式，而不是硬录出一个 0 字节文件。
    private let bayerConverter = BayerConverter()

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

        capture.onVideoSample = { [weak self] buffer in
            let recorder = box.get()
            guard let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else {
                recorder?.appendVideo(buffer)
                return
            }

            var monitorable = imageBuffer

            // 全幅格式只吐 Bayer：先 demosaic 成 10-bit YUV 再交给编码器。
            // 不做这一步 append 会被逐帧拒绝，文件停在 0 字节。
            if let converter = converter,
               CVPixelBufferGetPixelFormatType(imageBuffer) == BayerConverter.bayerFormat {
                // 设备实际按 60 fps 供帧（会话启动会把帧时长改回默认），
                // 而写入只要 24 帧/秒。逐帧 demosaic 等于白烧 2.5 倍算力，
                // 先按 30 fps 掐一道，重复格点再交给写入端去重。
                guard gate.passes(CMSampleBufferGetPresentationTimeStamp(buffer)) else { return }

                guard let converted = converter.convert(
                    imageBuffer,
                    chroma422: recorder?.wantsChroma422 ?? false,
                    parameters: RecordingEngine.bayerParameters(from: imageBuffer)
                ) else { return }

                monitorable = converted
                if let rebuilt = RecordingEngine.replacingImageBuffer(of: buffer, with: converted) {
                    recorder?.appendVideo(rebuilt)
                }
            } else {
                // 编码写入必须在采集队列上同步完成，不能异步延后
                recorder?.appendVideo(buffer)
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

    /// 从 Bayer 帧的附件里取黑电平 / 白电平 / 白平衡增益。
    ///
    /// 这些值跟着每一帧走（自动白平衡时每帧都在变），所以不缓存。
    /// 读不到就用 12-bit 的常规默认值：黑 0、白 4095、增益 1——
    /// 画面会偏一点，但不会因为缺一个键就完全不出来。
    nonisolated static func bayerParameters(from buffer: CVPixelBuffer) -> BayerConverter.Parameters {
        var parameters = BayerConverter.Parameters()

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
        parameters.blackLevel = max(0, black)
        parameters.whiteLevel = max(parameters.blackLevel + 1, white)

        if let red = scalar(attachments["ProResRAW_WhiteBalanceRedFactor"]), red > 0 {
            parameters.redGain = red
        }
        if let blue = scalar(attachments["ProResRAW_WhiteBalanceBlueFactor"]), blue > 0 {
            parameters.blueGain = blue
        }
        if let gain = scalar(attachments["ProResRAW_GainFactor"]), gain > 0, gain != 1 {
            parameters.redGain /= gain
            parameters.greenGain /= gain
            parameters.blueGain /= gain
        }

        if let pattern = scalar(attachments["ProResRAW_BayerPattern"]) {
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
            self.prepareTask = nil
        }
    }

    func teardownSession() {
        exposure.detach()
        whiteBalance.detach()
        capture.stop()
        sessionReady = false
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

        let selectedTier = tier
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
            if let spaceError = MovieRecorder.preflightSpaceCheck(tier: selectedTier) {
                self.state = .failed(spaceError.localizedDescription)
                return
            }

            // ---- 步骤 3：建 writer 并写入元数据 ----
            self.state = .preparing("正在准备编码器…")
            let startedAt = Date()
            let outputURL = MovieRecorder.makeOutputURL(tier: selectedTier, date: startedAt)

            let context = MovieMetadata.RecordingContext(
                tier: selectedTier,
                width: width,
                height: height,
                frameRate: VideoSettingsBuilder.frameRate,
                colorPipeline: self.captureConfiguration?.isBayer == true
                    ? "bayer12-demosaic-rec709"
                    : "system-isp-sdr",
                audioDescription: AudioSettings.description,
                locationOutcome: locationOutcome,
                startedAt: startedAt,
                orientation: rotationLabel
            )
            let metadata = MovieMetadata.items(for: context)

            do {
                let recorder = try MovieRecorder(
                    outputURL: outputURL,
                    tier: selectedTier,
                    width: width,
                    height: height,
                    metadata: metadata,
                    withAudio: self.captureConfiguration?.audioEnabled ?? false,
                    appleLog2: false,
                    videoTransform: CGAffineTransform(rotationAngle: degrees * .pi / 180)
                )
                self.recorderBox.set(recorder)
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
            let outcome = await recorder.finish()
            self.history.insert(outcome, at: 0)
            self.state = .finished
            self.refreshWrittenBytes()
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
                            self.autoStopReason = "画面未能写入：\(recorder.appendFailureDescription ?? "编码器未接受该画面格式")"
                            self.stopRecording()
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
