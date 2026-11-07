import Foundation
import AVFoundation
import Combine

/// 白平衡控制。
///
/// 三种模式对应系统的三种能力：
/// - `auto` → `.continuousAutoWhiteBalance`，全程跟随
/// - `locked` → `.locked`，锁在按下瞬间的增益
/// - `manual` → 温度/色调换算成 RGB 增益后 `setWhiteBalanceModeLocked(with:)`
///
/// 手动模式下温度与色调是**连续值**，不吸附到 3200K / 5600K 这类预设档。
@MainActor
final class WhiteBalanceController: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case auto
        case locked
        case manual

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "自动"
            case .locked: return "锁定"
            case .manual: return "手动"
            }
        }
    }

    // MARK: - 用户设定

    @Published var mode: Mode = .auto {
        didSet { if mode != oldValue { applyMode() } }
    }

    /// 色温（K）。范围按常见拍摄场景取，不是设备硬范围。
    @Published var temperature: Float = 5200 {
        didSet {
            if mode == .manual, temperature != oldValue { applyManual() }
        }
    }

    /// 色调（绿-品红偏移）
    @Published var tint: Float = 0 {
        didSet {
            if mode == .manual, tint != oldValue { applyManual() }
        }
    }

    // MARK: - 回读

    @Published private(set) var liveTemperature: Float = 0
    @Published private(set) var liveTint: Float = 0

    // MARK: - 范围

    static let temperatureRange: ClosedRange<Float> = 2500...9500
    static let tintRange: ClosedRange<Float> = -100...100

    // MARK: - 内部

    private weak var device: AVCaptureDevice?
    private var readbackTask: Task<Void, Never>?

    // MARK: - 绑定

    func attach(to device: AVCaptureDevice) {
        self.device = device

        // 接管时把设备当前估算值读进滑块，避免一进来就跳色
        let current = device.getTemperatureAndTintValues(for: device.deviceWhiteBalanceGains)
        if current.temperature.isFinite, current.temperature > 0 {
            temperature = min(max(current.temperature, Self.temperatureRange.lowerBound), Self.temperatureRange.upperBound)
        }
        tint = min(max(current.tint, Self.tintRange.lowerBound), Self.tintRange.upperBound)

        applyMode()
        startReadback()
    }

    func detach() {
        readbackTask?.cancel()
        readbackTask = nil
        if let device = device {
            try? device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        }
        device = nil
    }

    // MARK: - 应用

    private func applyMode() {
        guard let device = device else { return }
        try? device.lockForConfiguration()
        switch mode {
        case .auto:
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        case .locked:
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
        case .manual:
            writeManualGains(device)
        }
        device.unlockForConfiguration()
    }

    private func applyManual() {
        guard let device = device, mode == .manual else { return }
        try? device.lockForConfiguration()
        writeManualGains(device)
        device.unlockForConfiguration()
    }

    /// 调用前必须已 lockForConfiguration
    private func writeManualGains(_ device: AVCaptureDevice) {
        let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
            temperature: min(max(temperature, Self.temperatureRange.lowerBound), Self.temperatureRange.upperBound),
            tint: min(max(tint, Self.tintRange.lowerBound), Self.tintRange.upperBound)
        )
        var gains = device.getWhiteBalanceGains(for: values)

        // 增益必须落在 [1, maxWhiteBalanceGain]，超出会被系统直接拒绝
        let upper = device.maxWhiteBalanceGain
        gains.redGain = min(max(gains.redGain, 1), upper)
        gains.greenGain = min(max(gains.greenGain, 1), upper)
        gains.blueGain = min(max(gains.blueGain, 1), upper)

        // 白平衡的手动写入 API 叫 Locked 而不是 Custom——与曝光不同。
        // 它同时把 whiteBalanceMode 置为 .locked 并应用给定增益。
        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
    }

    // MARK: - 回读

    private func startReadback() {
        readbackTask?.cancel()
        readbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard let self = self, !Task.isCancelled else { return }
                await MainActor.run {
                    guard let device = self.device else { return }
                    let values = device.getTemperatureAndTintValues(for: device.deviceWhiteBalanceGains)
                    if values.temperature.isFinite {
                        self.liveTemperature = values.temperature
                    }
                    if values.tint.isFinite {
                        self.liveTint = values.tint
                    }
                }
            }
        }
    }

    // MARK: - 展示

    var liveSummary: String {
        String(format: "%.0fK · tint %+.0f", liveTemperature, liveTint)
    }

    var modeCaption: String {
        switch mode {
        case .auto: return "跟随环境"
        case .locked: return "锁定当前"
        case .manual: return "手动指定"
        }
    }
}
