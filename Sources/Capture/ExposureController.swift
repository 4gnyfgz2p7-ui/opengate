import Foundation
import AVFoundation
import Combine

/// 曝光控制。
///
/// **为什么需要软件闭环**：AVFoundation 只提供整组的曝光模式
/// （`locked` / `auto` / `continuousAutoExposure` / `custom`），
/// `custom` 下 duration 与 ISO 必须同时给定。而需求是「ISO 与快门两个维度各自
/// 自动或手动」，这种正交组合系统不支持。因此：
///
/// - ISO 自动 + 快门自动 → 直接用 `.continuousAutoExposure`
/// - ISO 手动 + 快门手动 → 直接用 `.custom`，两个值都固定
/// - ISO 手动 + 快门自动 → `.custom` 固定 ISO，按 `exposureTargetOffset` 闭环调 duration
/// - ISO 自动 + 快门手动 → `.custom` 固定 duration，按同一反馈调 ISO
///
/// 闭环用 `exposureTargetOffset`（单位 EV，正值表示过曝）作为唯一反馈量，
/// 不遍历像素统计亮度——后者每帧要扫一遍 Y 平面，代价高得多。
///
/// 快门"无级"：duration 是连续 CMTime，不吸附到 1/48、1/50 这类离散档，
/// 唯一约束是物理范围 [minExposureDuration, 1/24]——超过帧间隔会直接掉帧。
@MainActor
final class ExposureController: ObservableObject {

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

        /// 是否走系统原生自动曝光
        var usesNativeAuto: Bool {
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

        /// 界面按钮上的主标题。用摄影惯用词，不用 A/A、M/A 这类缩写——
        /// 缩写要把"哪个是哪个"记在脑子里，而按钮只有四个。
        var title: String {
            switch self {
            case .autoBoth: return "自动"
            case .manualISO: return "ISO 优先"
            case .manualShutter: return "快门优先"
            case .manualBoth: return "全手动"
            }
        }

        /// 是否显示 EV 滑块。全手动不给 EV——那时 ISO 与快门各自独立，
        /// 亮度由这两个值直接决定，再叠一层 EV 只会互相打架。
        var showsEVSlider: Bool {
            self != .manualBoth
        }

        var description: String {
            switch self {
            case .autoBoth: return "ISO 自动 · 快门自动"
            case .manualISO: return "ISO 手动 · 快门自动（改 ISO 时快门反比补偿）"
            case .manualShutter: return "ISO 自动 · 快门手动（改快门时 ISO 反比补偿）"
            case .manualBoth: return "ISO 手动 · 快门手动"
            }
        }
    }

    // MARK: - 用户设定

    @Published var mode: Mode = .autoBoth {
        didSet { if mode != oldValue { applyMode() } }
    }

    /// 手动 ISO。范围由设备格式决定。
    @Published var iso: Float = 100 {
        didSet { if mode.isoIsManual && iso != oldValue { applyManualISO() } }
    }

    /// 手动快门（秒）。无级，不吸附档位。
    @Published var shutterSeconds: Double = 1.0 / 50.0 {
        didSet { if mode.shutterIsManual && shutterSeconds != oldValue { applyManualShutter() } }
    }

    /// EV 补偿。正值提亮，负值压暗。
    /// 自动模式下走系统 target bias；手动模式下作为闭环的目标偏移。
    @Published var ev: Float = 0 {
        didSet { if ev != oldValue { applyEV() } }
    }

    // MARK: - 实时回读（低频，2 Hz）

    @Published private(set) var liveISO: Float = 0
    @Published private(set) var liveShutterSeconds: Double = 0
    @Published private(set) var liveOffsetEV: Float = 0
    @Published private(set) var isServoActive = false

    // MARK: - 可用范围

    private(set) var isoRange: ClosedRange<Float> = 34...3200
    private(set) var shutterRange: ClosedRange<Double> = (1.0 / 8000.0)...(1.0 / 24.0)

    // MARK: - 内部

    private weak var device: AVCaptureDevice?
    private var servoTask: Task<Void, Never>?
    private var readbackTask: Task<Void, Never>?

    /// 闭环步进阻尼。1.0 会在一次调整里对准，容易来回振荡；
    /// 0.45 大约 3–5 个周期收敛，肉眼看不到跳变。
    private let servoDamping: Float = 0.45

    /// 闭环频率（Hz）。5 Hz 足够跟上光线变化，又不会把
    /// `lockForConfiguration` 的调用堆起来。
    private let servoHz: Double = 5

    /// 单次调整的幅度上限（EV），防止光线突变时画面猛跳
    private let maxStepEV: Float = 0.6

    // MARK: - 绑定设备

    func attach(to device: AVCaptureDevice) {
        self.device = device
        let format = device.activeFormat

        let minISO = max(format.minISO, 1)
        let maxISO = max(format.maxISO, minISO)
        isoRange = minISO...maxISO

        // 最慢快门不能超过帧间隔，否则 24 fps 直接掉帧
        let frameInterval = 1.0 / Double(VideoSettingsBuilder.frameRate)
        let minShutter = max(CMTimeGetSeconds(format.minExposureDuration), 1.0 / 32000.0)
        let maxShutter = min(CMTimeGetSeconds(format.maxExposureDuration), frameInterval)
        if minShutter < maxShutter {
            shutterRange = minShutter...maxShutter
        } else {
            shutterRange = frameInterval...frameInterval
        }

        // 把当前设备值接管为用户设定值，避免一进来就跳
        iso = min(max(device.iso, isoRange.lowerBound), isoRange.upperBound)
        shutterSeconds = min(
            max(CMTimeGetSeconds(device.exposureDuration), shutterRange.lowerBound),
            shutterRange.upperBound
        )
        ev = min(max(device.exposureTargetBias, minEV), maxEV)

        applyMode()
        startReadback()
    }

    func detach() {
        servoTask?.cancel(); servoTask = nil
        readbackTask?.cancel(); readbackTask = nil
        isServoActive = false
        // 交还系统控制，避免离开界面后曝光冻在最后一帧
        if let device = device {
            try? device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
        device = nil
    }

    // MARK: - 应用

    private var minEV: Float { device?.minExposureTargetBias ?? -8 }
    private var maxEV: Float { device?.maxExposureTargetBias ?? 8 }

    /// 这条格式下系统到底给不给曝光补偿。
    ///
    /// btp2 这类绕过 ISP 的全幅格式里，`maxExposureTargetBias` 可能等于
    /// `minExposureTargetBias`（都为 0）。那种情况下 `setExposureTargetBias`
    /// 不报错也不生效——这正是「EV 滑块拖了没反应」的成因。
    /// 不支持时改由闭环吞下这个偏移，见 `servoStep`。
    private var supportsExposureBias: Bool {
        guard let device = device else { return false }
        return device.maxExposureTargetBias > device.minExposureTargetBias + 0.001
    }

    private func applyMode() {
        guard let device = device else { return }

        if mode.usesNativeAuto {
            servoTask?.cancel(); servoTask = nil
            isServoActive = false
            try? device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            // iOS 没有 isExposureTargetBiasSupported，支持范围由 min/maxExposureTargetBias 给出
            device.setExposureTargetBias(clampBias(ev, on: device), completionHandler: nil)
            device.unlockForConfiguration()
            return
        }

        // 手动/混合模式：先落到 custom，再按当前设定写一次
        try? device.lockForConfiguration()
        if device.isExposureModeSupported(.custom) {
            let duration = clampDuration(self.shutterSeconds)
            let targetISO = clampISO(mode.isoIsManual ? self.iso : device.iso)
            // custom 模式必须同时给 duration 与 ISO，
            // "自动"的那一维先取当前实时值，随后由闭环接管
            device.setExposureModeCustom(duration: duration, iso: targetISO, completionHandler: nil)
            device.setExposureTargetBias(clampBias(ev, on: device), completionHandler: nil)
        }
        device.unlockForConfiguration()

        updateServo()
    }

    private func applyManualISO() {
        guard let device = device, mode.isoIsManual, !mode.usesNativeAuto else { return }

        let newISO = clampISO(iso)
        try? device.lockForConfiguration()

        var duration = clampDuration(shutterSeconds)

        // ISO 优先（快门自动）下，改 ISO 不应改变画面亮度：
        // 曝光量 ∝ ISO × 快门，所以快门按反比补偿，两者一起写回设备。
        // 全手动模式不补偿——那时改 ISO 就是要提亮或压暗。
        if mode == .manualISO {
            let currentISO = max(device.iso, 1)
            let currentShutter = CMTimeGetSeconds(device.exposureDuration)
            if currentShutter > 0, newISO > 0 {
                duration = clampDuration(currentShutter * Double(currentISO / newISO))
                shutterSeconds = CMTimeGetSeconds(duration)
            }
        }

        device.setExposureModeCustom(duration: duration, iso: newISO, completionHandler: nil)
        device.unlockForConfiguration()
    }

    private func applyManualShutter() {
        guard let device = device, mode.shutterIsManual, !mode.usesNativeAuto else { return }

        let duration = clampDuration(shutterSeconds)
        var targetISO = clampISO(device.iso)

        // 快门优先（ISO 自动）下同理：改快门时 ISO 反比补偿，亮度不变。
        if mode == .manualShutter {
            let currentISO = device.iso
            let currentShutter = CMTimeGetSeconds(device.exposureDuration)
            let newShutter = CMTimeGetSeconds(duration)
            if currentShutter > 0, newShutter > 0 {
                targetISO = clampISO(Float(Double(currentISO) * currentShutter / newShutter))
                iso = targetISO
            }
        }

        try? device.lockForConfiguration()
        device.setExposureModeCustom(duration: duration, iso: targetISO, completionHandler: nil)
        device.unlockForConfiguration()
    }

    /// 系统 AE 不可用时的兜底：按比例缩放 ISO，快门保持当前值。
    ///
    /// 只改 ISO 是有意的——24fps 下快门最慢只能到 1/24，一旦顶到那里，
    /// 再想提亮就只能靠 ISO。两维一起动会让调子变得不可预测。
    /// 按 EV 增量推进一步曝光。**优先动快门，ISO 只在快门撞界时才动。**
    ///
    /// 这是"曝光一下一下跳"的根因所在。btp2（全幅 RAW）这条格式下，
    /// 传感器增益（ISO）实际可设的值是量化的——按 3% 的量去推，
    /// 写下去会被直接吞掉，等误差攒够一整档才突然生效，肉眼就是
    /// 一格一格地切。快门没有这个问题：`exposureDuration` 是连续
    /// CMTime，写多少就是多少，3% 的变化就是 3%。
    ///
    /// 所以闭环的顺序反过来：先用快门走完差额；快门到 1/24 或 1/8000
    /// 顶住了，才把剩下的差额交给 ISO。ISO 一次至少走 1/12 档，
    /// 免得反复写一个不会生效的值。
    ///
    /// - Parameter ev: 正的变亮，负的变暗。单位 EV。
    func applyExposureStep(ev: Double) {
        guard let device = device, ev.isFinite, abs(ev) > 0.0004 else { return }

        let format = device.activeFormat
        let frameInterval = 1.0 / Double(VideoSettingsBuilder.frameRate)
        let minDuration = max(CMTimeGetSeconds(format.minExposureDuration), 1.0 / 32000.0)
        let maxDuration = min(CMTimeGetSeconds(format.maxExposureDuration), frameInterval)

        let currentDuration = CMTimeGetSeconds(device.exposureDuration)
        let currentISO = device.iso
        guard currentDuration > 0, currentISO > 0 else { return }

        // 曝光量 ∝ duration。先按 duration 算，超出边界的那部分留给 ISO。
        var desiredDuration = currentDuration * pow(2.0, ev)
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

        do {
            try device.lockForConfiguration()
        } catch {
            return
        }
        device.setExposureModeCustom(
            duration: CMTime(seconds: desiredDuration, preferredTimescale: 1_000_000),
            iso: targetISO,
            completionHandler: nil
        )
        device.unlockForConfiguration()
    }

    private func applyEV() {
        guard let device = device else { return }
        let clamped = min(max(ev, minEV), maxEV)

        // 支持就用系统 bias（它对自动与半自动都直接生效）。
        // 不支持时什么都不写——`servoStep` 会把 ev 当作闭环目标，
        // 从 ISO/快门那一维补出来。
        guard supportsExposureBias else { return }

        try? device.lockForConfiguration()
        device.setExposureTargetBias(clampBias(clamped, on: device), completionHandler: nil)
        device.unlockForConfiguration()
    }

    // MARK: - 软件闭环

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

    /// 单步闭环：按曝光偏差改变"自动"的那一维。
    private func servoStep() {
        guard let device = device, mode.needsServo else { return }

        let offset = device.exposureTargetOffset
        guard offset.isFinite else { return }

        // 闭环目标：支持系统 bias 时目标是 0（bias 已经表达过 EV），
        // 不支持时目标就是 EV 本身 —— 系统不给补偿，就由这一维补出来。
        // 这是 EV 滑块在 btp2 格式下能生效的关键。
        let targetOffset: Float = supportsExposureBias ? 0 : ev
        let error = offset - targetOffset

        // 偏差过小就别动，避免在目标附近来回抖
        guard abs(error) > 0.08 else { return }

        let step = min(max(-error * servoDamping, -maxStepEV), maxStepEV)
        let factor = powf(2.0, step)

        try? device.lockForConfiguration()

        if mode == .manualISO {
            // ISO 固定，调快门
            let current = CMTimeGetSeconds(device.exposureDuration)
            let desired = current * Double(factor)
            let clamped = clampDuration(desired)
            if abs(CMTimeGetSeconds(clamped) - current) > 1e-6 {
                device.setExposureModeCustom(
                    duration: clamped,
                    iso: clampISO(iso),
                    completionHandler: nil
                )
                liveShutterSeconds = CMTimeGetSeconds(clamped)
            }
        } else if mode == .manualShutter {
            // 快门固定，调 ISO
            let current = device.iso
            let desired = current * factor
            let clamped = clampISO(desired)
            if abs(clamped - current) > 0.5 {
                device.setExposureModeCustom(
                    duration: clampDuration(shutterSeconds),
                    iso: clamped,
                    completionHandler: nil
                )
                liveISO = clamped
            }
        }

        device.unlockForConfiguration()
    }

    // MARK: - 回读

    private func startReadback() {
        readbackTask?.cancel()
        readbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self = self, !Task.isCancelled else { return }
                await MainActor.run {
                    guard let device = self.device else { return }
                    self.liveISO = device.iso
                    self.liveShutterSeconds = CMTimeGetSeconds(device.exposureDuration)
                    self.liveOffsetEV = device.exposureTargetOffset
                }
            }
        }
    }

    // MARK: - 钳制

    func clampISO(_ value: Float) -> Float {
        min(max(value, isoRange.lowerBound), isoRange.upperBound)
    }

    /// EV 的物理上限由设备的 target bias 范围给出。
    /// 超出范围时 `setExposureTargetBias` 不是报错而是被静默忽略，
    /// 所以必须先自己夹住。
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

    /// 快门显示成 1/x 形式，超过 0.3 秒则显示秒
    /// 场景曝光值（EV100），由**实际生效**的 ISO / 快门 / 光圈反算。
    ///
    /// 不做经验估计：EV100 = log2(N² / t) − log2(ISO / 100)，
    /// 只依赖设备回读的真实参数，因此全手动时也有确定的值。
    /// 早先界面上的 "+0.9 EV" 其实是 `exposureTargetOffset`，
    /// 那是相对测光目标的偏差，不是曝光值，所以看着永远不准。
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
