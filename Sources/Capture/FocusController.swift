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
/// `lensPosition` 的单位是**屈光度倒数**（1/米），不是 0–1 的百分比：
/// 0 表示无限远，1.0 表示 1 米，越接近 1 越近。设备能走多远由
/// `isLockingFocusWithCustomLensPositionSupported` 决定，不支持时
/// 只能退回 `.locked`（冻结当前位置），此时手动条不呈现。
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

    /// 手动焦距位置。0 = 无限远，1 ≈ 最近对焦距离。
    @Published var lensPosition: Float = 0 {
        didSet {
            if mode == .manual && lensPosition != oldValue { applyManual() }
        }
    }

    // MARK: - 回读

    @Published private(set) var liveLensPosition: Float = 0
    /// 设备是否支持按位置锁定焦距。不支持时手动档给不出效果。
    @Published private(set) var supportsManualFocus = false

    // MARK: - 内部

    private weak var device: AVCaptureDevice?
    private var readbackTask: Task<Void, Never>?

    // MARK: - 绑定

    func attach(to device: AVCaptureDevice) {
        self.device = device
        supportsManualFocus = device.isLockingFocusWithCustomLensPositionSupported

        // 接管当前设备的真实位置，等于「手动档一进来就是现在这个焦点」，
        // 不会因为滑块初值是 0 而突然拉到无限远
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
        try? device.lockForConfiguration()

        if device.isLockingFocusWithCustomLensPositionSupported {
            // 只有这个方法会真正把镜头移过去。attach 里已经确认过支持，
            // 但 attach 之后设备可能被换掉（切通路会重建会话），所以再判一次。
            device.setFocusModeLocked(lensPosition: target, completionHandler: nil)
            supportsManualFocus = true
        } else if device.isFocusModeSupported(.locked) {
            // 退路：冻结当前位置。此时滑块不呈现，所以不存在"拖了没反应"。
            device.focusMode = .locked
            supportsManualFocus = false
        }

        device.unlockForConfiguration()
        liveLensPosition = target
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

    /// 手动档滑块位置 = 焦距本身（0…1 直接对应 ∞…近）。
    ///
    /// 不做对数映射：lensPosition 已经是屈光度，天然是"近处变化快、远处变化慢"
    /// 的物理刻度，再套一层对数会把中远景挤成一团。
    var sliderPosition: Double {
        get { Double(lensPosition) }
        set { lensPosition = Float(min(max(newValue, 0), 1)) }
    }

    /// 把屈光度换算成人能读的距离文本。
    ///
    /// `lensPosition` 的定义是 1/米，所以距离 = 1 / position，位置 0 即无限远。
    func distanceText(_ position: Float) -> String {
        guard position > 0.001 else { return "∞" }
        let meters = 1.0 / Double(position)
        if meters >= 10 {
            return String(format: "%.0f m", meters)
        }
        if meters >= 1 {
            return String(format: "%.1f m", meters)
        }
        return String(format: "%.0f cm", meters * 100)
    }

    /// 当前实际焦距的描述，界面常驻用
    var liveFocusSummary: String {
        switch mode {
        case .continuous:
            return "自动"
        case .manual:
            return supportsManualFocus ? distanceText(lensPosition) : "锁定"
        }
    }
}
