import Foundation
import AVFoundation

/// 设备写入器：**所有 `lockForConfiguration` 都在这条串行队列上做**。
/// 曝光、白平衡、对焦三个控制器共用它——它们锁的是同一个 `AVCaptureDevice`，
/// 分三条队列只会互相排队，合一条反而简单。
///
/// 为什么必须搬出主线程：`lockForConfiguration()` 是同步阻塞的，设备被采集
/// 管线占着时要排队等它放锁。以前拖动 ISO/快门滑块，每个拖动事件都在主线程
/// 上加一次锁；自动曝光闭环还以 48 Hz 再抢一次。两者互相排队，表现就是
/// 滑块拖了没反应、松手半天才跳一下，顺带把整个取景界面也拖慢。
///
/// 现在主线程只把「想要的值」丢进来，加锁、写入、闭环计算全在后台串行队列上
/// 做；同一时刻只有一个写入在跑，拖得再快也只写最新的那个值。
final class DeviceServo: @unchecked Sendable {

    /// 全进程共用一条队列：设备锁只有一把，分成多条只会互相等。
    static let queue = DispatchQueue(label: "link.aitimes.opengate.device",
                                     qos: .userInteractive)

    private var queue: DispatchQueue { Self.queue }

    private weak var device: AVCaptureDevice?
    private var frameInterval: Double = 1.0 / 24.0

    /// 闭环要驱动哪一维。
    enum DriveMode {
        case off            // 不驱动（全手动）
        case auto           // 全幅 Bayer 的整档自动：按画面亮度闭环
        case semiShutter    // ISO 手动 / 快门自动：只调快门
        case semiISO        // 快门手动 / ISO 自动：只调 ISO
    }

    private var drive: DriveMode = .off
    private var evBias: Float = 0
    private var biasSupported = false
    private var smoothed: Double?
    private var holdUntil: CFAbsoluteTime = 0
    private var lastStepAt: CFAbsoluteTime = 0

    // 采样合并：采集队列可能每帧都喂，队列忙时只保留最新的一个
    private var pendingSample: Double?
    private var draining = false

    // MARK: - 绑定

    func attach(_ device: AVCaptureDevice) {
        queue.async {
            self.device = device
            self.frameInterval = 1.0 / Double(VideoSettingsBuilder.frameRate)
            self.smoothed = nil
            self.holdUntil = 0
            self.lastStepAt = 0
        }
    }

    func detach() {
        queue.async {
            if let device = self.device, (try? device.lockForConfiguration()) != nil {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            }
            self.device = nil
            self.drive = .off
        }
    }

    /// 设定闭环驱动的维度。**自动档只在全幅 Bayer 下接管**，其它格式
    /// 交给系统连续 AE（这时传 .off）。
    func setDrive(_ mode: DriveMode, ev: Float, biasSupported: Bool) {
        queue.async {
            if self.drive != mode { self.smoothed = nil }
            self.drive = mode
            self.evBias = ev
            self.biasSupported = biasSupported
        }
    }

    /// 用户刚手动改过值：暂停闭环一小会儿，别刚拖完就被拉回去。
    func hold(_ seconds: Double) {
        queue.async { self.holdUntil = CFAbsoluteTimeGetCurrent() + seconds }
    }

    // MARK: - 通用写入

    /// 任意设备写入。调用方给「拿到锁之后要做什么」，加锁与执行都在后台。
    /// 白平衡、对焦这类一次性的设置走这里，不再各自在主线程上加锁。
    func perform(_ block: @escaping (AVCaptureDevice) -> Void) {
        queue.async {
            guard let device = self.device,
                  (try? device.lockForConfiguration()) != nil else { return }
            block(device)
            device.unlockForConfiguration()
        }
    }

    // MARK: - 曝光

    /// 一次性写 duration + ISO（可带 EV bias）。这是所有手动调节的唯一出口。
    func write(duration: CMTime, iso: Float, bias: Float?) {
        queue.async { self.writeNow(duration: duration, iso: iso, bias: bias) }
    }

    /// 已经在设备队列上时直接调用，不再二次派发。
    private func writeNow(duration: CMTime, iso: Float, bias: Float?) {
        guard let device = self.device,
              (try? device.lockForConfiguration()) != nil else { return }
        device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
        if let bias {
            device.setExposureTargetBias(bias, completionHandler: nil)
        }
        device.unlockForConfiguration()
    }

    func writeBias(_ bias: Float) {
        queue.async {
            guard let device = self.device,
                  (try? device.lockForConfiguration()) != nil else { return }
            device.setExposureTargetBias(bias, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setContinuous(bias: Float) {
        queue.async {
            guard let device = self.device,
                  (try? device.lockForConfiguration()) != nil else { return }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.setExposureTargetBias(bias, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    // MARK: - 自动闭环

    /// 采集队列每帧喂一个亮度样本。内部按 48 Hz 限流，并合并积压的采样。
    func feed(_ sample: Double) {
        queue.async {
            self.pendingSample = sample
            guard !self.draining else { return }
            self.draining = true
            while let value = self.pendingSample {
                self.pendingSample = nil
                self.step(value)
            }
            self.draining = false
        }
    }

    private func step(_ sample: Double) {
        guard let device = device, drive != .off else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now >= holdUntil, now - lastStepAt >= 1.0 / 48.0 else { return }
        lastStepAt = now

        switch drive {
        case .off:
            return

        case .auto:
            let filtered = (smoothed ?? sample) * 0.75 + sample * 0.25
            smoothed = filtered

            let error = 0.42 - filtered
            guard abs(error) > 0.006 else { return }

            // 0.14 ≈ 中灰处 1 EV 对应的观感亮度变化（实测拟合）
            let capped = min(max((error / 0.14) * 0.5, -0.025), 0.025)
            advance(capped, on: device)

        case .semiShutter, .semiISO:
            // 半自动：系统测光给的 EV 偏差最准，直接拿来用。
            // 它无效（btp2 里可能恒为 0）就退回画面均值——两条都不动才停手。
            let offset = device.exposureTargetOffset
            let ev: Double
            if offset.isFinite, abs(offset) > 0.02 {
                let target: Float = biasSupported ? 0 : evBias
                ev = Double(-(offset - target))
            } else {
                let filtered = (smoothed ?? sample) * 0.75 + sample * 0.25
                smoothed = filtered
                let error = 0.42 - filtered
                guard abs(error) > 0.01 else { return }
                ev = error / 0.14
            }
            guard abs(ev) > 0.02 else { return }
            let capped = min(max(ev * 0.5, -0.05), 0.05)
            if drive == .semiShutter {
                adjustDurationOnly(capped, device)
            } else {
                adjustISOOnly(capped, device)
            }
        }
    }

    /// ISO 锁定，只推快门。快门是连续量，半步都不会跳。
    private func adjustDurationOnly(_ ev: Double, _ device: AVCaptureDevice) {
        let format = device.activeFormat
        let minDuration = max(CMTimeGetSeconds(format.minExposureDuration), 1.0 / 32000.0)
        let maxDuration = min(CMTimeGetSeconds(format.maxExposureDuration), frameInterval)
        let current = CMTimeGetSeconds(device.exposureDuration)
        guard current > 0 else { return }
        let desired = min(max(current * pow(2.0, ev), minDuration), maxDuration)
        guard abs(desired - current) / current > 1e-5 else { return }
        writeNow(duration: CMTime(seconds: desired, preferredTimescale: 1_000_000),
                 iso: device.iso,
                 bias: nil)
    }

    /// 快门锁定，只推 ISO。ISO 是量化的，攒够 1/12 档才写。
    private func adjustISOOnly(_ ev: Double, _ device: AVCaptureDevice) {
        let format = device.activeFormat
        let current = device.iso
        guard current > 0 else { return }
        let desired = min(max(current * Float(pow(2.0, ev)), format.minISO), format.maxISO)
        guard abs(log2(Double(desired) / Double(current))) >= 1.0 / 12.0 else { return }
        writeNow(duration: device.exposureDuration, iso: desired, bias: nil)
    }

    /// 推进一步曝光：**优先动快门，ISO 只在快门撞界时才动**。
    ///
    /// btp2 的 ISO 是量化的，按 3% 推会被吞掉、攒够一档才生效——那正是
    /// 「一格一格切」的来源。快门是连续 CMTime，写多少就是多少。
    private func advance(_ ev: Double, on device: AVCaptureDevice) {
        let format = device.activeFormat
        let minDuration = max(CMTimeGetSeconds(format.minExposureDuration), 1.0 / 32000.0)
        let maxDuration = min(CMTimeGetSeconds(format.maxExposureDuration), frameInterval)

        let currentDuration = CMTimeGetSeconds(device.exposureDuration)
        let currentISO = device.iso
        guard currentDuration > 0, currentISO > 0 else { return }

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
            let scaled = min(max(currentISO * Float(pow(2.0, overflowEV)),
                                 format.minISO), format.maxISO)
            // 不到 1/12 档的 ISO 变化写下去不会生效，等它攒够再写
            if abs(log2(Double(scaled) / Double(currentISO))) >= 1.0 / 12.0 {
                targetISO = scaled
            }
        }

        let durationMoved = abs(desiredDuration - currentDuration) / currentDuration > 1e-5
        let isoMoved = abs(targetISO - currentISO) / max(currentISO, 1) > 1e-3
        guard durationMoved || isoMoved else { return }

        guard (try? device.lockForConfiguration()) != nil else { return }
        device.setExposureModeCustom(
            duration: CMTime(seconds: desiredDuration, preferredTimescale: 1_000_000),
            iso: targetISO,
            completionHandler: nil
        )
        device.unlockForConfiguration()
    }
}
