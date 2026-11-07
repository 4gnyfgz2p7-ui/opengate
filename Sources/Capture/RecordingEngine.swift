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

    /// 波形开关。关掉后连采样都不做，省电而不只是省绘制。
    @Published var waveformEnabled = true {
        didSet { waveform.setEnabled(waveformEnabled) }
    }

    private let recorderBox = RecorderBox()
    private var recordingStart: Date?
    private var tickTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var prepareTask: Task<Void, Never>?

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

        capture.onVideoSample = { [weak self] buffer in
            // 编码写入必须在采集队列上同步完成，不能异步延后
            box.get()?.appendVideo(buffer)

            // 波形采样同队列串行执行（约 1.3 万次读取），
            // 只有产出新图时才跳回主线程，避免每帧都触发一次线程切换。
            // 采样器要的是像素缓冲，需从 sample buffer 里取出图像平面。
            if let pixelBuffer = CMSampleBufferGetImageBuffer(buffer),
               let image = sampler.process(pixelBuffer) {
                Task { @MainActor in
                    self?.waveformImage = image
                }
            }
        }
        capture.onAudioSample = { buffer in
            box.get()?.appendAudio(buffer)
        }
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
                audioEnabled: true
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
            if let spaceError = MovieRecorder.preflightSpaceCheck(tier: selectedTier, plannedSeconds: 600) {
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
                colorPipeline: "system-isp-sdr",
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
                    }
                    self.refreshWrittenBytes()
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
