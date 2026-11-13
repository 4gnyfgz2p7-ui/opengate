import Foundation
import AVFoundation

/// 曝光写入的唯一通道。
///
/// 为什么必须单独一层：`lockForConfiguration()` 是**同步阻塞**的。
/// 在滑动条回调里直接调用它，主线程每次拖动都要等设备锁；
/// 自动闭环又以 48 Hz 抢同一把锁——两者叠在一起，手指按下去就是
/// 「没反应 / 松手才动一下 / 延迟半秒」。这和算法对不对无关，是线程模型问题。
///
/// 这里只做两件事：
/// 1. 所有 `lockForConfiguration` + 写入排到一条串行队列，主线程只投递不等待；
/// 2. 只保留**最新**目标值。一次拖动产生的几十次取值，队列空闲时也只落最后一次，
///    不会把设备写爆，也不会因为排队产生「追上手指」的延迟感。
final class ExposureWriter: @unchecked Sendable {

    enum Command {
        /// 固定 duration 与 ISO（手动 / 半手动 / 闭环步进都走这条）
        case custom(duration: Double, iso: Float)
        /// 交还系统连续自动曝光
        case auto(bias: Float?)
        /// 只改曝光补偿
        case bias(Float)
    }

    private let queue = DispatchQueue(label: "link.aitimes.opengate.exposure", qos: .userInitiated)
    private let stateLock = NSLock()

    private weak var device: AVCaptureDevice?
    private var pending: Command?
    private var draining = false
    private var errorText: String?

    /// 最近一次写入失败的原因。成功写入会清空。
    var lastError: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return errorText
    }

    func attach(_ device: AVCaptureDevice?) {
        stateLock.lock()
        self.device = device
        stateLock.unlock()
    }

    func submit(_ command: Command) {
        stateLock.lock()
        pending = command
        if draining {
            stateLock.unlock()
            return
        }
        draining = true
        stateLock.unlock()

        queue.async { [weak self] in self?.drain() }
    }

    /// 串行消费：每轮取走当前最新的一条，写完再看有没有新的。
    private func drain() {
        while true {
            stateLock.lock()
            let command = pending
            let device = self.device
            pending = nil
            if command == nil {
                draining = false
                stateLock.unlock()
                return
            }
            stateLock.unlock()

            guard let command, let device else { continue }
            apply(command, to: device)
        }
    }

    private func apply(_ command: Command, to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
        } catch {
            note("设备锁不可用：\(error.localizedDescription)")
            return
        }

        switch command {
        case let .custom(duration, iso):
            guard device.isExposureModeSupported(.custom) else {
                note("该格式不支持 custom 曝光")
                break
            }
            let time = CMTime(
                seconds: min(max(duration, 1.0 / 32000.0), 1.0),
                preferredTimescale: 1_000_000
            )
            device.setExposureModeCustom(
                duration: time,
                iso: min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO),
                completionHandler: nil
            )
            note(nil)

        case let .auto(bias):
            guard device.isExposureModeSupported(.continuousAutoExposure) else {
                note("该格式不支持连续自动曝光")
                break
            }
            device.exposureMode = .continuousAutoExposure
            if let bias {
                device.setExposureTargetBias(bias, completionHandler: nil)
            }
            note(nil)

        case let .bias(value):
            device.setExposureTargetBias(value, completionHandler: nil)
            note(nil)
        }

        device.unlockForConfiguration()
    }

    private func note(_ text: String?) {
        stateLock.lock()
        errorText = text
        stateLock.unlock()
    }
}
