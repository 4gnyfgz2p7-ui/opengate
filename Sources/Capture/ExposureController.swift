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
        didSet { if !suppressWrites && mode.isoIsManual && iso != oldValue { applyManualISO() } }
    }

    /// 手动快门（秒）。无级，不吸附档位。
    @Published var shutterSeconds: Double = 1.0 / 50.0 {
        didSet { if !suppressWrites && mode.shutterIsManual && shutterSeconds != oldValue { applyManualShutter() } }
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

    // MARK: - 可用范围

    private(set) var isoRange: ClosedRange<Float> = 34...3200
    private(set) var shutterRange: ClosedRange<Double> = (1.0 / 8000.0)...(1.0 / 24.0)

    // MARK: - 内部

    private weak var device: AVCaptureDevice?
    private var readbackTask: Task<Void, Never>?

    /// 设备写入器。所有 `lockForConfiguration` 都交给它，在主线程之外执行。
    private var servo: DeviceServo?
    /// 程序自己改这两个发布值时不要触发写入（只有用户拖动才该写）。
    private var suppressWrites = false
    /// 当前采集是不是全幅 Bayer（btp2）。这一档系统 AE 不干活，
    /// 自动曝光得由软件闭环接管；其它档交给系统连续 AE。
    private var isBayerFormat = false

    // MARK: - 绑定设备

    func attach(to device: AVCaptureDevice, isBayer: Bool, servo: DeviceServo) {
        self.device = device
        self.isBayerFormat = isBayer
        self.servo = servo
        servo.attach(device)
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
        // 系统 bias 只在系统自己的 AE 干活时才有意义。btp2 这类格式给的
        // 范围是 0…0，往这里夹一下就把用户设的 EV 抹成 0 了——EV 滑块
        // 就是这么"看起来永远停在中间"的。不支持时保留用户原来的值。
        if supportsExposureBias {
            ev = min(max(device.exposureTargetBias, device.minExposureTargetBias),
                     device.maxExposureTargetBias)
        }

        applyMode()
        startReadback()
    }

    func detach() {
        readbackTask?.cancel(); readbackTask = nil
        // 交还系统控制，避免离开界面后曝光冻在最后一帧
        servo?.detach()
        servo = nil
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
    /// 不支持时改由闭环吞下这个偏移，见 `DeviceServo` 的半自动驱动。
    private var supportsExposureBias: Bool {
        guard let device = device else { return false }
        return device.maxExposureTargetBias > device.minExposureTargetBias + 0.001
    }

    private func applyMode() {
        guard let device = device, let servo else { return }
        let bias = clampBias(ev, on: device)

        if mode.usesNativeAuto {
            // 全幅 Bayer 档：系统 AE 被静默忽略，交给软件闭环；
            // 其它档：交系统连续 AE，闭环不参与。
            if !isBayerFormat { servo.setContinuous(bias: bias) }
            syncDrive()
            return
        }

        // 手动/混合模式：先把两维落到设备，再由闭环负责"自动"的那一维
        //
        // 切进手动档时**以设备此刻的真实值为准**去填滑块。
        // 否则 `iso` 还停在上一次手调的 100，而闭环已经把现场推到 1600，
        // 一按「全手动」画面就被拉暗一大截——看着就像曝光跳了一下。
        suppressWrites = true
        if mode.isoIsManual, device.iso > 0 {
            iso = min(max(device.iso, isoRange.lowerBound), isoRange.upperBound)
        }
        if mode.shutterIsManual {
            let live = CMTimeGetSeconds(device.exposureDuration)
            if live > 0 {
                shutterSeconds = min(max(live, shutterRange.lowerBound), shutterRange.upperBound)
            }
        }
        suppressWrites = false

        let duration = mode.shutterIsManual ? clampDuration(shutterSeconds) : device.exposureDuration
        let targetISO = mode.isoIsManual ? clampISO(iso) : device.iso
        servo.write(duration: duration, iso: targetISO, bias: bias)
        syncDrive()
    }

    /// 把「闭环该驱动哪一维」同步给设备队列。
    ///
    /// 半自动两档以前跑在主线程上的 5 Hz Task 里，每步还要抢设备锁，
    /// 表现就是"拖完滑块要等两三秒才动"。现在闭环整个搬进设备队列，
    /// 主线程只负责告诉它驱动哪一维。
    private func syncDrive() {
        guard let servo else { return }
        let biasOK = supportsExposureBias
        switch mode {
        case .autoBoth:
            servo.setDrive(isBayerFormat ? .auto : .off, ev: ev, biasSupported: biasOK)
        case .manualISO:
            servo.setDrive(.semiShutter, ev: ev, biasSupported: biasOK)
        case .manualShutter:
            servo.setDrive(.semiISO, ev: ev, biasSupported: biasOK)
        case .manualBoth:
            servo.setDrive(.off, ev: ev, biasSupported: biasOK)
        }
    }

    private func applyManualISO() {
        guard let device = device, mode.isoIsManual, !mode.usesNativeAuto else { return }

        let newISO = clampISO(iso)
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

        servo?.hold(1.2)
        servo?.write(duration: duration, iso: newISO, bias: nil)
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

        servo?.hold(1.2)
        servo?.write(duration: duration, iso: targetISO, bias: nil)
    }

    private func applyEV() {
        guard let device = device else { return }

        // 闭环目标变化一定要通知到——EV 是闭环的目标偏移，不管系统给不给
        // `exposureTargetBias`。早先这里在不支持 bias 时直接 return，
        // 顺带把 syncDrive 也跳过了，闭环永远拿不到新的 EV，滑块完全失灵。
        syncDrive()

        // 系统 bias 只在系统自己的 AE 干活时才有意义：全幅档的曝光由闭环
        // 独占，写 bias 既无效又可能和闭环打架。支持时也只用于非全幅档。
        guard !isBayerFormat, supportsExposureBias else { return }
        servo?.writeBias(clampBias(min(max(ev, minEV), maxEV), on: device))
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
