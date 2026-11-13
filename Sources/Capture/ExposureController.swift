import Foundation
import AVFoundation
import Combine

/// 曝光自动方案。放在文件级而不是嵌在类里：
/// 嵌在 `@MainActor` 类里的静态成员容易继承隔离，
/// 而它的默认值要在属性初始化器里求值。
enum ExposureEngine: String, CaseIterable, Identifiable {
    case builtIn
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtIn: return "自建闭环"
        case .system: return "系统 AE"
        }
    }

    var detail: String {
        switch self {
        case .builtIn: return "逐帧测光，快门优先；btp2 上确定可用"
        case .system: return "交给 continuousAutoExposure；若画面不动说明该格式不支持"
        }
    }

    private static let storageKey = "opengate.exposureEngine"

    static var saved: ExposureEngine {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let value = ExposureEngine(rawValue: raw) else { return .builtIn }
        return value
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}

/// 曝光控制。
///
/// **两种自动方案**，可在设置里切换：
/// - `.system`：`continuousAutoExposure`，把测光交给系统，只用 `exposureTargetBias` 调 EV。
///   代价是 btp2（全幅 RAW）这类绕过 ISP 的格式可能写了不生效，
///   而 `exposureMode` 仍会读回 `.continuousAutoExposure`——所以「是否真的在跑」
///   只能看画面，看标志位会被骗。
/// - `.builtIn`：软件闭环，由 `RecordingEngine` 逐帧测光后喂 `applyExposureStep`。
///   btp2 上能确定在干活，这也是当前默认。
///
/// **手动写入必须即时生效**，所以所有设备写入都走 `ExposureWriter`
/// （串行队列 + 只保留最新值）。主线程不再出现 `lockForConfiguration`：
/// 那正是「拖滑动条没反应、延迟半秒」的根因。
///
/// 半手动（ISO 手动 / 快门自动，或反过来）仍然是软件闭环：
/// 固定的那一维不动，闭环只动「自动」的那一维。
@MainActor
final class ExposureController: ObservableObject {

    // MARK: - 自动方案

    typealias Engine = ExposureEngine

    // MARK: - 模式

    enum Mode: String, CaseIterable, Identifiable {
        case autoBoth
        case manualISO
        case manualShutter
        case manualBoth

        var id: String { rawValue }

        var isoIsManual: Bool {
            self == .manualISO || self == .manualBoth
        }

        var shutterIsManual: Bool {
            self == .manualShutter || self == .manualBoth
        }

        /// 是否走系统原生自动曝光**
        var wantsAutoBoth: Bool {
            self == .autoBoth
        }

        /// 是否需要软件闭环
        var needsServo: Bool {
            self == .manualISO || self == .manualShutter
        }

        var shortLabel: String {
            switch self {
            case .autoBoth: return "AUTO"
            case .manualISO: return "ISO"
            case .manualShutter: return "快门"
            case .manualBoth: return "手动"
            }
        }

        var title: String {
            switch self {
            case .autoBoth: return "自动"
            case .manualISO: return "ISO 优先"
            case .manualShutter: return "快门优先"
            case .manualBoth: return "全手动"
            }
        }

        var description: String {
            switch self {
            case .autoBoth: return "ISO 自动 · 快门自动"
            case .manualISO: return "ISO 手动 · 快门自动"
            case .manualShutter: return "ISO 自动 · 快门手动"
            case .manualBoth: return "ISO 手动 · 快门手动"
            }
        }
    }

    // MARK: - 用户设定

    @Published var engine: Engine = .saved {
        didSet {
            guard engine != oldValue else { return }
            engine.save()
            applyMode()
        }
    }

    @Published var mode: Mode = .autoBoth {
        didSet { if mode != oldValue { applyMode() } }
    }

    /// 手动 ISO。范围由设备格式决定。
    @Published var iso: Float = 100 {
        didSet {
            guard !isSyncing, mode.isoIsManual, iso != oldValue else { return }
            applyManualISO()
        }
    }

    /// 手动快门（秒）。无级，不吸附档位。
    @Published var shutterSeconds: Double = 1.0 / 50.0 {
        didSet {
            guard !isSyncing, mode.shutterIsManual, shutterSeconds != oldValue else { return }
            applyManualShutter()
        }
    }

    /// EV 补偿。正值提亮，负值压暗。
    @Published var ev: Float = 0 {
        didSet {
            guard !isSyncing, ev != oldValue else { return }
            applyEV()
        }
    }

    // MARK: - 实时回读

    @Published private(set) var liveISO: Float = 0
    @Published private(set) var liveShutterSeconds: Double = 0
    @Published private(set) var liveOffsetEV: Float = 0
    @Published private(set) var isServoActive = false

    // MARK: - 可用范围

    private(set) var isoRange: ClosedRange<Float> = 34...3200
    private(set) var shutterRange: ClosedRange<Double> = (1.0 / 8000.0)...(1.0 / 24.0)

    // MARK: - 内部

    private weak var device: AVCaptureDevice?
    private let writer = ExposureWriter()
    private var servoTask: Task<Void, Never>?
    private var readbackTask: Task<Void, Never>?

    /// attach / 模式切换时同步用户值，别把它当成用户操作再写一遍
    private var isSyncing = false

    /// 最后一次投递给写入器的 custom 值。
    /// 闭环下一步以它为基准，而不是回读设备——回读滞后一帧，
    /// 按旧值再乘一次就会「一暗一亮」地翻倍（0.5.67 的教训）。
    private var lastWritten: (duration: Double, iso: Float)?

    /// 用户刚动过手动滑块时短暂让闭环停手，
    /// 免得手指还在拖、闭环已经把它反向补偿回去。
    private var servoHoldUntil = Date.distantPast

    private let servoDamping: Float = 0.45
    private let servoHz: Double = 5
    private let maxStepEV: Float = 0.6
    /// 手动写入后闭环暂停的时长（秒）
    private let servoHoldSeconds: Double = 0.6

    // MARK: - 绑定设备

    func attach(to device: AVCaptureDevice) {
        self.device = device
        writer.attach(device)

        let format = device.activeFormat
        let minISO = max(format.minISO, 1)
        let maxISO = max(format.maxISO, minISO)
        isoRange = minISO...maxISO

        let frameInterval = 1.0 / Double(VideoSettingsBuilder.frameRate)
        let minShutter = max(CMTimeGetSeconds(format.minExposureDuration), 1.0 / 32000.0)
        let maxShutter = min(CMTimeGetSeconds(format.maxExposureDuration), frameInterval)
        if minShutter < maxShutter {
            shutterRange = minShutter...maxShutter
        } else {
            shutterRange = frameInterval...frameInterval
        }

        syncUserValuesFromDevice(includeEV: true)
        lastWritten = (
            CMTimeGetSeconds(device.exposureDuration),
            device.iso
        )
        applyMode()
        startReadback()
    }

    func detach() {
        servoTask?.cancel(); servoTask = nil
        readbackTask?.cancel(); readbackTask = nil
        isServoActive = false

        // 交还系统控制，避免离开界面后曝光冻在最后一帧。
        // 这里可以同步做：detach 只在关机/换会话时发生一次，不在拖动路径上。
        if let device = device {
            try? device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
        writer.attach(nil)
        device = nil
        lastWritten = nil
    }

    // MARK: - 能力

    var supportsExposureBias: Bool {
        guard let device = device else { return false }
        return device.maxExposureTargetBias > device.minExposureTargetBias + 0.001
    }

    var supportsContinuousAuto: Bool {
        device?.isExposureModeSupported(.continuousAutoExposure) ?? false
    }

    /// 当前真正想要的自动方案：只有「两维都自动」才谈得上系统 AE
    var usesNativeAuto: Bool {
        mode.wantsAutoBoth && engine == .system
    }

    var writerError: String? { writer.lastError }

    var biasRangeText: String {
        guard let device = device else { return "—" }
        return String(format: "%.1f … %.1f EV", device.minExposureTargetBias, device.maxExposureTargetBias)
    }

    /// 设备当前实际处于哪种曝光模式。判断「系统 AE 到底有没有接管」只能看它。
    var systemExposureModeText: String {
        guard let device = device else { return "—" }
        switch device.exposureMode {
        case .locked: return "locked"
        case .autoExpose: return "auto"
        case .continuousAutoExposure: return "continuous"
        case .custom: return "custom"
        @unknown default: return "?"
        }
    }

    // MARK: - 应用

    private var minEV: Float { device?.minExposureTargetBias ?? -8 }
    private var maxEV: Float { device?.maxExposureTargetBias ?? 8 }

    private func applyMode() {
        guard let device = device else { return }

        // 从「自动」切进手动时，先把设备当前值接过来，
        // 否则会拿一个很久以前的快门去写，画面直接跳一下。
        // **不接 EV**：btp2 的 bias 范围是 0…0，接过来会把用户设的 EV 抹成 0。
        syncUserValuesFromDevice(includeEV: false)
        lastWritten = (CMTimeGetSeconds(device.exposureDuration), device.iso)

        if usesNativeAuto {
            stopServo()
            writer.submit(.auto(bias: supportsExposureBias ? clampBias(ev, on: device) : nil))
            return
        }

        if mode.wantsAutoBoth {
            // 自建闭环接管：先落到 custom，值取当前设备值，随后由逐帧闭环推动
            stopServo()
            writer.submit(.custom(duration: CMTimeGetSeconds(device.exposureDuration), iso: device.iso))
            return
        }

        // 半手动 / 全手动
        stopServo()
        submitCurrentManualValues()
        if supportsExposureBias {
            writer.submit(.bias(clampBias(ev, on: device)))
        }
        updateServo()
    }

    /// 把手动的那几维写下去。自动的那一维取设备当前值，保持不动。
    private func submitCurrentManualValues() {
        guard let device = device else { return }
        let duration = mode.shutterIsManual
            ? CMTimeGetSeconds(clampDuration(shutterSeconds))
            : CMTimeGetSeconds(clampDuration(CMTimeGetSeconds(device.exposureDuration)))
        let isoValue = mode.isoIsManual ? clampISO(iso) : max(device.iso, isoRange.lowerBound)
        submitCustom(duration: duration, iso: isoValue)
    }

    private func submitCustom(duration: Double, iso: Float) {
        lastWritten = (duration, iso)
        writer.submit(.custom(duration: duration, iso: iso))
    }

    private func applyManualISO() {
        guard let device = device, mode.isoIsManual, !usesNativeAuto else { return }
        let newISO = clampISO(iso)

        // 快门保持原样：半手动时那是闭环刚调到的位置，全手动时是用户设定的值。
        // 这里**不做**交叉补偿——补偿交给闭环，它只动「自动」那一维；
        // 在这条路径上再写一次快门，等于用户拖一次、设备被写两次。
        let duration = mode == .manualBoth
            ? CMTimeGetSeconds(clampDuration(shutterSeconds))
            : CMTimeGetSeconds(clampDuration(CMTimeGetSeconds(device.exposureDuration)))

        submitCustom(duration: duration, iso: newISO)

        // 立即回显，不等 2 Hz 回读：手指在拖的时候，读数必须跟着走。
        liveISO = newISO
        if mode == .manualISO, abs(duration - shutterSeconds) > 1e-6 {
            isSyncing = true
            shutterSeconds = duration
            isSyncing = false
            liveShutterSeconds = duration
        }
        holdServo()
    }

    private func applyManualShutter() {
        guard let device = device, mode.shutterIsManual, !usesNativeAuto else { return }
        let duration = clampDuration(shutterSeconds)
        let isoValue = mode == .manualBoth
            ? clampISO(iso)
            : max(device.iso, isoRange.lowerBound)

        submitCustom(duration: CMTimeGetSeconds(duration), iso: isoValue)

        liveShutterSeconds = CMTimeGetSeconds(duration)
        if mode == .manualShutter {
            isSyncing = true
            iso = isoValue
            isSyncing = false
            liveISO = isoValue
        }
        holdServo()
    }

    private func applyEV() {
        guard let device = device else { return }
        guard supportsExposureBias else { return }
        writer.submit(.bias(clampBias(ev, on: device)))
    }

    /// 逐帧闭环的一步。engine == .builtIn 时由 `RecordingEngine` 调用。
    ///
    /// 以 `lastWritten` 为基准而不是设备回读：写入是异步生效的，
    /// 每步都按回读值再乘一次，就会在「旧值 × 2^ev」和「新值 × 2^ev」
    /// 之间来回，走成极限环（0.5.67 实测 3.2 EV 的闪烁就是这么来的）。
    func applyExposureStep(ev stepEV: Double) {
        // 兜底：只有「两维自动 + 自建闭环」才允许这条路径写设备
        guard mode == .autoBoth, engine == .builtIn else { return }
        guard let device = device, stepEV.isFinite, abs(stepEV) > 0.0004 else { return }

        let format = device.activeFormat
        let frameInterval = 1.0 / Double(VideoSettingsBuilder.frameRate)
        let minDuration = max(CMTimeGetSeconds(format.minExposureDuration), 1.0 / 32000.0)
        let maxDuration = min(CMTimeGetSeconds(format.maxExposureDuration), frameInterval)

        let base = lastWritten ?? (CMTimeGetSeconds(device.exposureDuration), device.iso)
        let currentDuration = base.duration
        let currentISO = base.iso
        guard currentDuration > 0, currentISO > 0 else { return }

        var desiredDuration = currentDuration * pow(2.0, stepEV)
        var overflowEV = 0.0
        if desiredDuration > maxDuration {
            overflowEV = log2(desiredDuration / maxDuration)
            desiredDuration = maxDuration
        } else if desiredDuration < minDuration {
            overflowEV = log2(desiredDuration / minDuration)
            desiredDuration = minDuration
        }

        var targetISO = currentISO
        if abs(overflowEV) > 0.0004 {
            let scaled = clampISO(currentISO * Float(pow(2.0, overflowEV)))
            // 不到 1/12 档的 ISO 变化写下去不会生效，等它攒够再写。
            if abs(log2(Double(scaled) / Double(currentISO))) >= 1.0 / 12.0 {
                targetISO = scaled
            }
        }

        let durationMoved = abs(desiredDuration - currentDuration) / currentDuration > 1e-5
        let isoMoved = abs(targetISO - currentISO) / max(currentISO, 1) > 1e-3
        guard durationMoved || isoMoved else { return }

        submitCustom(duration: desiredDuration, iso: targetISO)
    }

    // MARK: - 软件闭环（半手动）

    private func updateServo() {
        servoTask?.cancel()
        guard mode.needsServo, device != nil else {
            isServoActive = false
            return
        }
        isServoActive = true

        servoTask = Task { [weak self] in
            let interval = UInt64((1.0 / (self?.servoHz ?? 5)) * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard let self = self, !Task.isCancelled else { return }
                await MainActor.run { self.servoStep() }
            }
        }
    }

    private func stopServo() {
        servoTask?.cancel()
        servoTask = nil
        isServoActive = false
    }

    private func holdServo() {
        servoHoldUntil = Date().addingTimeInterval(servoHoldSeconds)
    }

    private func servoStep() {
        guard let device = device, mode.needsServo else { return }
        guard Date() >= servoHoldUntil else { return }

        let offset = device.exposureTargetOffset
        guard offset.isFinite else { return }

        let targetOffset: Float = supportsExposureBias ? 0 : ev
        let error = offset - targetOffset
        guard abs(error) > 0.08 else { return }

        let step = min(max(-error * servoDamping, -maxStepEV), maxStepEV)
        let base = lastWritten ?? (CMTimeGetSeconds(device.exposureDuration), device.iso)
        guard base.duration > 0, base.iso > 0 else { return }

        if mode == .manualISO {
            let desired = base.duration * pow(2.0, Double(step))
            let clamped = clampDuration(desired)
            let seconds = CMTimeGetSeconds(clamped)
            guard abs(seconds - base.duration) > 1e-6 else { return }
            submitCustom(duration: seconds, iso: clampISO(iso))
        } else if mode == .manualShutter {
            let desired = base.iso * powf(2.0, step)
            let clamped = clampISO(desired)
            guard abs(clamped - base.iso) > 0.5 else { return }
            submitCustom(duration: CMTimeGetSeconds(clampDuration(shutterSeconds)), iso: clamped)
        }
    }

    // MARK: - 回读

    /// 低频回读只用于显示。拖动过程中的读数由写入方即时回显，不等这里。
    private func startReadback() {
        readbackTask?.cancel()
        readbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self = self, !Task.isCancelled else { return }
                await MainActor.run {
                    guard let device = self.device else { return }
                    // 用户正在拖的时候不要用滞后回读覆盖即时值
                    if self.mode.isoIsManual, Date() < self.servoHoldUntil { return }
                    if self.mode.shutterIsManual, Date() < self.servoHoldUntil { return }
                    let deviceISO = device.iso
                    let deviceDuration = CMTimeGetSeconds(device.exposureDuration)
                    self.liveISO = deviceISO
                    self.liveShutterSeconds = deviceDuration
                    self.liveOffsetEV = device.exposureTargetOffset

                    // 基准纠偏：写入被设备夹掉时（不支持的 ISO 档、超范围快门），
                    // `lastWritten` 会和实际值越差越远，闭环就会按错误起点一直推。
                    // 差超过 0.3 EV 才拉回，避免正常的「写入尚未生效」被误判。
                    if let written = self.lastWritten,
                       Date() >= self.servoHoldUntil,
                       written.duration > 0, written.iso > 0, deviceISO > 0, deviceDuration > 0 {
                        let isoGap = abs(log2(Double(deviceISO) / Double(written.iso)))
                        let durationGap = abs(log2(deviceDuration / written.duration))
                        if isoGap > 0.3 || durationGap > 0.3 {
                            self.lastWritten = (deviceDuration, deviceISO)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 同步

    /// 把设备的当前值接成用户设定值。`isSyncing` 期间不触发写入。
    private func syncUserValuesFromDevice(includeEV: Bool) {
        guard let device = device else { return }
        isSyncing = true
        iso = min(max(device.iso, isoRange.lowerBound), isoRange.upperBound)
        shutterSeconds = min(
            max(CMTimeGetSeconds(device.exposureDuration), shutterRange.lowerBound),
            shutterRange.upperBound
        )
        if includeEV {
            ev = min(max(device.exposureTargetBias, minEV), maxEV)
        }
        isSyncing = false
    }

    // MARK: - 钳制

    func clampISO(_ value: Float) -> Float {
        min(max(value, isoRange.lowerBound), isoRange.upperBound)
    }

    private func clampBias(_ value: Float, on device: AVCaptureDevice) -> Float {
        min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias)
    }

    func clampDuration(_ seconds: Double) -> CMTime {
        let clamped = min(max(seconds, shutterRange.lowerBound), shutterRange.upperBound)
        return CMTime(seconds: clamped, preferredTimescale: 1_000_000)
    }

    // MARK: - 展示

    var liveExposureSummary: String {
        let shutter = formatShutter(liveShutterSeconds)
        return String(format: "ISO %.0f · %@ · %.2f EV", liveISO, shutter, liveOffsetEV)
    }

    /// 场景曝光值（EV100），由实际生效的 ISO / 快门 / 光圈反算。
    var estimatedEV100: Double? {
        guard let device = device else { return nil }
        let aperture = Double(device.lensAperture)
        let iso = Double(liveISO > 0 ? liveISO : self.iso)
        let shutter = liveShutterSeconds > 0 ? liveShutterSeconds : shutterSeconds
        guard aperture > 0, iso > 0, shutter > 0 else { return nil }
        return log2(aperture * aperture / shutter) - log2(iso / 100.0)
    }

    func formatShutter(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "—" }
        if seconds >= 0.3 {
            return String(format: "%.2f s", seconds)
        }
        return String(format: "1/%.0f", 1.0 / seconds)
    }

    /// 滑块位置（0…1）与快门秒数的对数映射，让手感接近等比例变化
    var shutterSliderPosition: Double {
        get { logNormalize(shutterSeconds, low: shutterRange.lowerBound, high: shutterRange.upperBound) }
        set { shutterSeconds = logDenormalize(newValue, low: shutterRange.lowerBound, high: shutterRange.upperBound) }
    }

    var isoSliderPosition: Double {
        get { logNormalize(Double(iso), low: Double(isoRange.lowerBound), high: Double(isoRange.upperBound)) }
        set { iso = Float(logDenormalize(newValue, low: Double(isoRange.lowerBound), high: Double(isoRange.upperBound))) }
    }

    private func logNormalize(_ value: Double, low: Double, high: Double) -> Double {
        guard low > 0, high > low else { return 0 }
        let clamped = min(max(value, low), high)
        return log(clamped / low) / log(high / low)
    }

    private func logDenormalize(_ position: Double, low: Double, high: Double) -> Double {
        guard low > 0, high > low else { return low }
        let t = min(max(position, 0), 1)
        return low * pow(high / low, t)
    }
}
