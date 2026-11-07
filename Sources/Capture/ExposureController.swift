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
            case .autoBoth: return "A / A"
            case .manualISO: return "M / A"
            case .manualShutter: return "A / M"
            case .manualBoth: return "M / M"
            }
        }

        var description: String {
            switch self {
            case .autoBoth: return "ISO 自动 · 快门自动"
            case .manualISO: return "ISO 手动 · 快门自动（无级）"
            case .manualShutter: return "ISO 自动 · 快门手动"
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
        try? device.lockForConfiguration()
        let duration = clampDuration(shutterSeconds)
        let targetISO = clampISO(iso)
        device.setExposureModeCustom(duration: duration, iso: targetISO, completionHandler: nil)
        device.unlockForConfiguration()
    }

    private func applyManualShutter() {
        guard let device = device, mode.shutterIsManual, !mode.usesNativeAuto else { return }
        try? device.lockForConfiguration()
        let duration = clampDuration(shutterSeconds)
        let targetISO = clampISO(device.iso)
        device.setExposureModeCustom(duration: duration, iso: targetISO, completionHandler: nil)
        device.unlockForConfiguration()
    }

    private func applyEV() {
        guard let device = device else { return }
        let clamped = min(max(ev, minEV), maxEV)
        // 自动与手动/混合模式都要写 target bias：
        // 前者直接改变系统测光目标，后者改变闭环的收敛目标（offset → 0 即命中新目标）
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

        // 偏差过小就别动，避免在目标附近来回抖
        guard abs(offset) > 0.08 else { return }

        let step = min(max(-offset * servoDamping, -maxStepEV), maxStepEV)
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
