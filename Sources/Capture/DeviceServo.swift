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

    // MARK: - 闭环状态
    //
    // **这两个值是闭环自己记的，不从设备回读。**
    //
    // `setExposureModeCustom` 是异步生效的：写下去之后 `device.exposureDuration`
    // / `device.iso` 要等下一帧才更新，中间读到的是上一次的值。拿它当下一步的
    // 基准，等于每一步都在「旧值 × 2^ev」和「新值 × 2^ev」之间来回，误差被翻了
    // 一倍；实拍就是这么走出「一亮一暗、差三档」的极限环的（0.5.67 的素材逐帧
    // 量出暗帧/亮帧相差约 3.2 EV，周期 5 帧）。
    //
    // 现在写入值即状态：写什么记什么，闭环是干净的积分器。
    // 只有两种情况才重新对齐设备——绑定新设备时，以及「连着写了十几步画面
    // 一动不动」（说明设备把值夹掉了，我们的模型偏了）。
    private var exposureDuration: Double = 0
    private var exposureISO: Float = 0
    private var stateValid = false

    private var smoothed: Double?
    private var holdUntil: CFAbsoluteTime = 0
    private var lastWriteAt: CFAbsoluteTime = 0

    /// 同向连续写了几步、写之前画面读数是多少。用来发现「写了没反应」。
    private var sameDirectionSteps = 0
    private var referenceAtWrite = 0.0

    /// ISO 是量化量，写不到 1/12 档就不生效。攒着的零头记在这里，
    /// 否则快门顶到界之后只剩小误差（0.03–0.08 EV），永远攒不够一档，
    /// 画面就卡在偏暗那里不动了。
    private var isoCarryEV: Double = 0

    /// 闭环最近一步的读数，给诊断串用。
    /// 加锁而不走设备队列：诊断是在界面上按需取的，不能等设备锁。
    private let mirrorLock = NSLock()
    private var mirrorText = "sv—"

    // 采样合并：采集队列可能每帧都喂，队列忙时只保留最新的一个
    private var pendingSample: Double?
    private var draining = false

    // MARK: - 绑定

    func attach(_ device: AVCaptureDevice) {
        queue.async {
            self.device = device
            self.frameInterval = 1.0 / Double(VideoSettingsBuilder.frameRate)
            self.reseed(device)
            self.smoothed = nil
            self.holdUntil = 0
            self.lastWriteAt = 0
            self.sameDirectionSteps = 0
        }
    }

    func detach() {
        // 只交还曝光，**不清掉 device**。
        //
        // 三个控制器共用这一个写入器，拆会话时引擎会依次调
        // `exposure.detach()` / `whiteBalance.detach()` / `focus.detach()`。
        // 这里要是把 device 置空，后面两个的白平衡/对焦复位就全被吞掉，
        // 下次开会话还停在上一段的手动增益上。
        queue.async {
            if let device = self.device, (try? device.lockForConfiguration()) != nil {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            }
            self.drive = .off
            self.stateValid = false
        }
    }

    /// 从设备读一次真实值作为闭环起点。只在绑定设备和「写了没反应」时调用。
    private func reseed(_ device: AVCaptureDevice) {
        let duration = CMTimeGetSeconds(device.exposureDuration)
        let iso = device.iso
        if duration.isFinite, duration > 0 { exposureDuration = duration }
        if iso.isFinite, iso > 0 { exposureISO = iso }
        stateValid = duration.isFinite && duration > 0 && iso.isFinite && iso > 0
        isoCarryEV = 0
    }

    /// 设定闭环驱动的维度。**自动档只在全幅 Bayer 下接管**，其它格式
    /// 交给系统连续 AE（这时传 .off）。
    func setDrive(_ mode: DriveMode, ev: Float, biasSupported: Bool) {
        queue.async {
            if self.drive != mode { self.smoothed = nil; self.sameDirectionSteps = 0 }
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

        // 手写下去的绝对值也要进闭环状态，否则闭环下一步会从旧值算起，
        // 把用户刚设的值又拉回去。
        let seconds = CMTimeGetSeconds(duration)
        if seconds.isFinite, seconds > 0 { exposureDuration = seconds }
        if iso.isFinite, iso > 0 { exposureISO = iso }
        stateValid = true
        sameDirectionSteps = 0
        isoCarryEV = 0
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
            self.stateValid = false
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

    /// 单步闭环。
    ///
    /// **误差在对数域算，步长按比例给。** 曝光是乘法关系，只有在对数域里
    /// 「误差 → 步长」才是线性的；以前用线性亮度差除以一个经验常数 0.14，
    /// 亮部和暗部的等效增益差好几倍，暗处推不动、亮处一冲就过头。
    ///
    /// 步长上限分两档：离目标很远（>1.5 EV）时允许大跨步，1 秒出头就能从
    /// 全错拉回来；靠近目标时收到 0.15 EV 以内，肉眼看不到台阶。
    private func step(_ sample: Double) {
        guard let device = device, drive != .off else { return }
        guard sample.isFinite, sample > 0.0005 else { return }
        if !stateValid { reseed(device) ; guard stateValid else { return } }

        let now = CFAbsoluteTimeGetCurrent()
        guard now >= holdUntil, now - lastWriteAt >= 1.0 / 48.0 else { return }

        // 一阶低通：48 Hz 采样下单帧噪点必须滤掉，否则 ISO 会跟着噪点呼吸。
        // α=0.3 比以前的 0.25 稍快，配合下面的比例步长，收敛更利落。
        let filtered = (smoothed ?? sample) * 0.7 + sample * 0.3
        smoothed = filtered

        // 目标亮度。0.42 是「场景平均 18% 灰」在 sqrt 空间的位置：
        // 测光读数是 sqrt(线性码值)，所以 0.42² ≈ 0.176 满幅。
        //
        // EV 偏移直接乘在目标上——这样 EV 滑块在任何驱动维度下都有效，
        // 不再依赖系统给不给 `exposureTargetBias`（btp2 上系统那一套是空的，
        // 早先 `applyEV` 遇到不支持就直接 return，滑块因此完全失灵）。
        // sqrt 空间里 1 EV = ×√2，所以指数是 ev/2。
        let aim = 0.42 * pow(2.0, Double(evBias) * 0.5)
        let errorEV = 2.0 * log2(aim / filtered)

        // 死区：误差小于 0.03 EV（3%）就彻底停手，**连一个字节都不写**。
        // 这是「不再自己抖自己」的一半功劳——早先每帧都在把同一个值重写一遍，
        // 每次写入都会激起设备侧的增益重算，画面跟着一起呼吸。
        guard abs(errorEV) > 0.03 else {
            sameDirectionSteps = 0
            note(aim: aim, measured: filtered, error: errorEV, wrote: false)
            return
        }

        let cap = abs(errorEV) > 1.5 ? 0.5 : 0.15
        let stepEV = min(max(errorEV * 0.45, -cap), cap)
        lastWriteAt = now

        // 同向连写十几步画面却纹丝不动 → 我们对设备的估计偏了（值被夹掉），
        // 重新对齐一次再继续。
        if abs(errorEV) > 0.5 {
            if sameDirectionSteps == 0 { referenceAtWrite = filtered }
            sameDirectionSteps += 1
            if sameDirectionSteps >= 12, abs(filtered - referenceAtWrite) < 0.01 {
                reseed(device)
                smoothed = nil
                sameDirectionSteps = 0
                note(aim: aim, measured: filtered, error: errorEV, wrote: false)
                return
            }
        } else {
            sameDirectionSteps = 0
        }

        let wrote = apply(stepEV, device)
        note(aim: aim, measured: filtered, error: errorEV, wrote: wrote)
    }

    private func note(aim: Double, measured: Double, error: Double, wrote: Bool) {
        mirrorLock.lock()
        mirrorText = String(format: "aim%.3f·m%.3f·e%+.2f·d1/%.0f·i%.0f·b%d%@",
                            aim, measured, error,
                            exposureDuration > 0 ? 1 / exposureDuration : 0,
                            exposureISO, biasSupported ? 1 : 0,
                            wrote ? "" : "·停")
        mirrorLock.unlock()
    }

    /// 闭环最近一步的目标 / 实测 / 误差 / 写入的快门与 ISO。
    /// 出问题时直接看这一行，不用再猜闭环在干什么。
    var loopState: String {
        mirrorLock.lock()
        defer { mirrorLock.unlock() }
        return mirrorText
    }

    /// 把一步 EV 落到设备上。差值先给快门（连续量，怎么写怎么是），
    /// 快门撞到上下界之后剩下的才交给 ISO（量化量，写小了会被吞掉）。
    /// 返回这一次有没有真的写下去。
    @discardableResult
    private func apply(_ ev: Double, _ device: AVCaptureDevice) -> Bool {
        let format = device.activeFormat
        let minISO = max(format.minISO, 1)
        let maxISO = max(format.maxISO, minISO)
        let minDuration = max(CMTimeGetSeconds(format.minExposureDuration), 1.0 / 32000.0)
        // 快门最长只能到一个帧间隔。上限优先用设备**实际**的帧时长：
        // 会话启动会把帧时长改回默认，这时按 1/24 写下去是越界的，
        // 越界的 `setExposureModeCustom` 不会报错、只是不生效——
        // 闭环以为改了、画面没动，正是「明明在自动却曝不起来」的一类成因。
        let deviceFrame = CMTimeGetSeconds(device.activeVideoMinFrameDuration)
        let frameCap = (deviceFrame.isFinite && deviceFrame > 0.0001) ? deviceFrame : frameInterval
        let maxDuration = max(min(CMTimeGetSeconds(format.maxExposureDuration), frameCap),
                              minDuration * 1.0001)

        var targetDuration = exposureDuration
        var targetISO = exposureISO

        switch drive {
        case .off:
            return false

        case .auto:
            var desired = exposureDuration * pow(2.0, ev)
            var overflow = 0.0
            if desired > maxDuration {
                overflow = log2(desired / maxDuration)
                desired = maxDuration
            } else if desired < minDuration {
                overflow = log2(desired / minDuration)
                desired = minDuration
            }
            targetDuration = desired
            if abs(overflow) > 1e-4 {
                // ISO 是量化的：不到 1/12 档写下去不生效。零头攒起来，
                // 换方向就清零——反着攒出来的和没有意义。
                if overflow * isoCarryEV < 0 { isoCarryEV = 0 }
                isoCarryEV = min(max(isoCarryEV + overflow, -1.0), 1.0)
                if abs(isoCarryEV) >= 1.0 / 12.0 {
                    let scaled = min(max(exposureISO * Float(pow(2.0, isoCarryEV)), minISO), maxISO)
                    targetISO = scaled
                    isoCarryEV = 0
                }
            } else {
                isoCarryEV = 0
            }

        case .semiShutter:
            targetDuration = min(max(exposureDuration * pow(2.0, ev), minDuration), maxDuration)

        case .semiISO:
            targetISO = min(max(exposureISO * Float(pow(2.0, ev)), minISO), maxISO)
        }

        let durationMoved = abs(targetDuration - exposureDuration) / max(exposureDuration, 1e-9) > 1e-4
        let isoMoved = abs(Double(targetISO) - Double(exposureISO)) / max(Double(exposureISO), 1) > 1e-4
        guard durationMoved || isoMoved else { return false }

        guard (try? device.lockForConfiguration()) != nil else { return false }
        device.setExposureModeCustom(
            duration: CMTime(seconds: targetDuration, preferredTimescale: 1_000_000),
            iso: targetISO,
            completionHandler: nil
        )
        device.unlockForConfiguration()

        exposureDuration = targetDuration
        exposureISO = targetISO
        return true
    }
}
