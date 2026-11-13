import Foundation
import AVFoundation
import Combine

/// 对焦控制。
///
/// **之前为什么对不上焦**：`CaptureController` 在锁配置时无条件写了
/// `device.focusMode = .locked`，注释写的是「锁在无限远附近」，但 `.locked`
/// 只是**冻结当时的镜头位置**，并不会移到无限远。上一次会话若停在近处，
/// 之后每一次启动都从那个近距离开始并立刻冻住，于是远处永远虚焦、
/// 转动机身也不会重新合焦。这一层把对焦交还给用户：
///
/// - `.continuous` → `continuousAutoFocus`，系统持续跟踪
/// - `.manual`     → `setFocusModeLocked(lensPosition:)`，由滑块直接给位置
///
/// **`lensPosition` 的方向**（Apple 文档原文）：范围 0.0–1.0，
/// **0.0 是镜头能对上的最近距离，1.0 是最远，且 1.0 并不等于无限远**，
/// 默认值 1.0。文档同时明确「同一个位置值不对应确定的物理距离，
/// 换设备也不可比」——所以界面上不给"多少米"这种假读数，
/// 只给位置值本身，左端标「近」、右端标「∞」。
@MainActor
final class FocusController: ObservableObject {

    // MARK: - 模式

    enum Mode: String, CaseIterable, Identifiable {
        case continuous
        case manual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .continuous: return "自动"
            case .manual: return "手动"
            }
        }

        var description: String {
            switch self {
            case .continuous: return "连续自动对焦"
            case .manual: return "手动锁定焦距"
            }
        }
    }

    // MARK: - 用户设定

    @Published var mode: Mode = .continuous {
        didSet { if mode != oldValue { applyMode() } }
    }

    /// 手动焦距位置。**0 = 最近，1 = 最远（≈∞）**，默认 1。
    ///
    /// 初值必须给 1：0 在这个 API 里是「贴到最近」，一进手动档
    /// 就会把镜头拉到底，看起来像"对焦坏了"。
    @Published var lensPosition: Float = 1 {
        didSet {
            if mode == .manual && lensPosition != oldValue { applyManual() }
        }
    }

    // MARK: - 回读

    @Published private(set) var liveLensPosition: Float = 1
    /// 设备是否支持按位置锁定焦距。不支持时手动档给不出效果。
    @Published private(set) var supportsManualFocus = false
    /// 最近一次写入失败的原因。界面与诊断都读它，不再静默失败。
    @Published private(set) var lastError: String?

    // MARK: - 内部

    private weak var device: AVCaptureDevice?
    private var readbackTask: Task<Void, Never>?

    // MARK: - 绑定

    func attach(to device: AVCaptureDevice) {
        self.device = device
        supportsManualFocus = device.isLockingFocusWithCustomLensPositionSupported

        // 接管当前设备的真实位置，等于「手动档一进来就是现在这个焦点」，
        // 不会因为滑块初值把镜头拽走
        if supportsManualFocus {
            lensPosition = min(max(device.lensPosition, 0), 1)
            liveLensPosition = lensPosition
        }

        // 全幅 Bayer 通路绕过了 ISP，而自动对焦依赖 ISP 的场景分析。
        // 系统若在这条通路上关掉 AF，就只剩手动可用——直接切过去，
        // 而不是留一个"选了自动、实际一动不动"的假状态。
        let canAutoFocus = device.isFocusModeSupported(.continuousAutoFocus)
            || device.isFocusModeSupported(.autoFocus)
        if !canAutoFocus && supportsManualFocus {
            mode = .manual
        }

        applyMode()
        startReadback()
    }

    func detach() {
        readbackTask?.cancel()
        readbackTask = nil
        if let device = device {
            try? device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        }
        device = nil
    }

    // MARK: - 应用

    private func applyMode() {
        guard let device = device else { return }

        switch mode {
        case .continuous:
            try? device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            device.unlockForConfiguration()

        case .manual:
            applyManual()
        }
    }

    private func applyManual() {
        guard let device = device else { return }

        let target = min(max(lensPosition, 0), 1)

        // 这里原来写的是 `try? device.lockForConfiguration()`：锁不住时错误被
        // 吞掉，函数照常往下走、读数照常更新，于是表现为「滑块在动、镜头不动」。
        // 必须把失败显式记下来。
        do {
            try device.lockForConfiguration()
        } catch {
            lastError = "对焦锁定失败：" + error.localizedDescription
            return
        }

        if device.isLockingFocusWithCustomLensPositionSupported {
            // 只有这个方法会真正把镜头移过去。attach 里已经确认过支持，
            // 但 attach 之后设备可能被换掉（切通路会重建会话），所以再判一次。
            device.setFocusModeLocked(lensPosition: target, completionHandler: nil)
            supportsManualFocus = true
        } else if device.isFocusModeSupported(.locked) {
            // 退路：冻结当前位置。此时手动档给不出位移。
            device.focusMode = .locked
            supportsManualFocus = false
            lastError = "该格式不支持按位置锁定焦距"
        }

        // 不把目标值写成「实测值」——镜头可能根本没动。
        // 真实位置由 startReadback 每 400ms 从设备读回。
        device.unlockForConfiguration()
        if supportsManualFocus { lastError = nil }
    }

    // MARK: - 回读

    private func startReadback() {
        readbackTask?.cancel()
        readbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self = self, !Task.isCancelled else { return }
                await MainActor.run {
                    guard let device = self.device else { return }
                    // 自动对焦期间 lensPosition 会随场景变化，这就是实时读数
                    self.liveLensPosition = device.lensPosition
                }
            }
        }
    }

    // MARK: - 展示

    /// 手动档滑块位置 = 焦距位置本身，左端「近」→ 右端「∞」。
    ///
    /// 不做映射：这个量本来就是镜头马达的归一化位置，中段如何分布由
    /// 镜头自己决定，再套一层曲线只会让手感脱离真实行程。
    var sliderPosition: Double {
        get { Double(lensPosition) }
        set { lensPosition = Float(min(max(newValue, 0), 1)) }
    }

    /// 位置读数。**不换算成米**——Apple 明确说位置值不对应确定的物理距离，
    /// 换设备也不可比，换算出来的数字会比不给更误导。
    func positionText(_ position: Float) -> String {
        if position >= 0.985 { return "∞" }
        if position <= 0.015 { return "最近" }
        return String(format: "%.2f", position)
    }

    /// 当前实际焦距的描述，界面常驻用
    var liveFocusSummary: String {
        switch mode {
        case .continuous:
            // 自动档给实时位置：数字在动就说明 AF 在工作，
            // 这是"到底有没有在自动对焦"最直接的证据
            return positionText(liveLensPosition)
        case .manual:
            return supportsManualFocus ? positionText(lensPosition) : "锁定"
        }
    }
}
