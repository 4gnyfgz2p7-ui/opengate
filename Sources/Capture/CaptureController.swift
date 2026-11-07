import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import UIKit

/// 采集会话的唯一持有者。
///
/// 四档共用这一份采集前端：格式、帧率、曝光、白平衡、防抖全部在这里锁死，
/// 切档时**不重建**这一层（避免一次黑屏和若干丢帧）。
final class CaptureController: NSObject {

    /// 采集通路
    enum Path: String, Codable {
        /// 系统 ISP 输出的 10-bit 全幅画面。当前阶段可跑通端到端的路径。
        case systemProcessed
        /// 传感器原始 Bayer（btp2），留给自建 Metal 管线。
        case bayerDirect

        var displayName: String {
            switch self {
            case .systemProcessed: return "系统 ISP · 10-bit"
            case .bayerDirect: return "Bayer 直出 · btp2"
            }
        }
    }

    /// 配置结果的快照，用于界面展示与报告
    struct Configuration {
        var path: Path = .systemProcessed
        var width: Int32 = 0
        var height: Int32 = 0
        var pixelFormat: String = "—"
        var frameDurationValue: Int64 = 0
        var frameDurationTimescale: Int32 = 0
        var isExact24: Bool = false
        var stabilizationMode: String = "—"
        var exposureLocked: Bool = false
        var whiteBalanceLocked: Bool = false
        var focusLocked: Bool = false
        var audioEnabled: Bool = false
        /// 采集回来的是传感器原始 Bayer，编码前必须自己 demosaic
        var isBayer: Bool = false
        /// 全幅是否被迫让位给系统 ISP（Bayer 转换器不可用时）
        var degradedToSystemISP: Bool = false
        var notes: [String] = []

        var resolutionText: String { "\(width)×\(height)" }

        var frameRateText: String {
            if isExact24 { return "1/24 精确 24.000" }
            guard frameDurationTimescale > 0, frameDurationValue > 0 else { return "—" }
            return "\(frameDurationValue)/\(frameDurationTimescale)"
        }

        /// 一行说清画面是怎么来的，界面常驻显示，避免"以为在录全幅"
        var pipelineText: String {
            if isBayer { return "Bayer 直出 · 自建管线" }
            if degradedToSystemISP { return "系统 ISP · 非全幅" }
            return "系统 ISP"
        }
    }

    // MARK: - 状态

    let session = AVCaptureSession()

    private(set) var videoDevice: AVCaptureDevice?
    private(set) var videoOutput = AVCaptureVideoDataOutput()
    private(set) var audioOutput = AVCaptureAudioDataOutput()
    private(set) var configuration = Configuration()

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    private let videoQueue = DispatchQueue(label: "acamera.capture.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "acamera.capture.audio", qos: .userInitiated)

    /// 每一帧视频（已带原始 PTS）
    var onVideoSample: ((CMSampleBuffer) -> Void)?
    /// 每一声频块
    var onAudioSample: ((CMSampleBuffer) -> Void)?

    /// 采集层回调的帧计数，供引擎算丢帧
    private(set) var deliveredVideoFrames: Int64 = 0

    // MARK: - 配置

    /// 建立会话。可重复调用，内部会先拆掉旧配置。
    ///
    /// - Parameters:
    ///   - path: 采集通路
    ///   - audioEnabled: 是否接入麦克风
    ///   - lockWhiteBalance: 是否在配置阶段锁定白平衡。
    ///     默认 false——白平衡由 `WhiteBalanceController` 全权接管，
    ///     支持自动 / 锁定 / 手动色温三种模式，这里若再锁一次会覆盖用户设定。
    ///     曝光同理，由 `ExposureController` 接管。
    @discardableResult
    func configure(
        path: Path,
        audioEnabled: Bool,
        lockWhiteBalance: Bool = false,
        canProcessBayer: Bool = true
    ) -> Configuration {

        var result = Configuration()
        result.path = path

        // 可重入：降级换格式时会再调一次，旧输入输出必须先拆干净，
        // 否则 canAddInput 会被拒（会话已经有一份同样的输入）。
        removeExistingIO()

        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        // ---- 视频输入 ----
        guard let device = Self.backWideCamera() else {
            result.notes.append("找不到后置广角相机")
            session.commitConfiguration()
            configuration = result
            return result
        }

        guard let format = Self.openGateFormat(in: device) else {
            result.notes.append("找不到可用视频格式")
            session.commitConfiguration()
            configuration = result
            return result
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                result.notes.append("会话拒绝视频输入")
                session.commitConfiguration()
                configuration = result
                return result
            }
            session.addInput(input)
            videoInput = input
            videoDevice = device
        } catch {
            result.notes.append("创建视频输入失败：\(error.localizedDescription)")
            session.commitConfiguration()
            configuration = result
            return result
        }

        // ---- 设备参数：格式、帧率、白平衡、对焦 ----
        applyDeviceSettings(
            device: device,
            format: format,
            lockWhiteBalance: lockWhiteBalance,
            result: &result
        )

        // ---- 视频输出 ----
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true

        guard session.canAddOutput(output) else {
            result.notes.append("会话拒绝视频输出")
            session.commitConfiguration()
            configuration = result
            return result
        }
        session.addOutput(output)
        videoOutput = output

        output.setSampleBufferDelegate(self, queue: videoQueue)

        session.commitConfiguration()

        // 像素格式必须**显式**指定：这个全幅格式在输出上只暴露 btp2，
        // 什么都不设等于向系统要一个它给不出的 420v——结果是零帧到达，
        // 预览层照样出画（它自己直连格式），于是表现为
        // "取景正常、波形空、录制文件 0 字节"。
        var chosen = Self.choosePixelFormat(from: output.availableVideoPixelFormatTypes, path: path)

        if let code = chosen, FourCC.isBayer(code), !canProcessBayer {
            result.notes.append("Bayer 转换器不可用，改用系统 ISP 格式")
            if let adopted = adoptProcessedFormat(device: device, output: output, result: &result) {
                chosen = adopted
                result.degradedToSystemISP = true
            }
        }

        if let chosen = chosen {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: chosen]
            result.pixelFormat = FourCC.string(chosen)
            result.isBayer = FourCC.isBayer(chosen)
            if result.isBayer {
                result.path = .bayerDirect
            }
        } else {
            result.notes.append("该格式没有可用像素格式")
            result.pixelFormat = "无"
        }

        // 防抖必须关：任何防抖都会裁切画幅，与"全幅不裁切"直接冲突
        if let connection = output.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
                result.stabilizationMode = "off"
            } else {
                result.stabilizationMode = "不支持关闭"
                result.notes.append("该连接不支持关闭防抖")
            }
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
        }

        // ---- 音频 ----
        if audioEnabled {
            session.beginConfiguration()
            if attachAudio(result: &result) {
                result.audioEnabled = true
            }
            session.commitConfiguration()
        }

        // commit 会把设备帧时长改回默认值（实测变回 60 fps），
        // 必须在 commit 之后重新钉一次，否则记录到的实际帧率与标称不符。
        enforceFrameRate(device: device)

        // 帧率回读要在 commit 之后，此时 activeFormat 已生效
        let duration = device.activeVideoMinFrameDuration
        result.width = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription).width
        result.height = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription).height
        result.frameDurationValue = duration.value
        result.frameDurationTimescale = duration.timescale
        result.isExact24 = (duration.value == 1 && duration.timescale == 24)

        configuration = result
        return result
    }

    /// 拆掉现有输入输出，让 `configure` 可以重跑
    private func removeExistingIO() {
        guard !session.inputs.isEmpty || !session.outputs.isEmpty else { return }
        if session.isRunning { session.stopRunning() }

        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()

        videoInput = nil
        audioInput = nil
        videoDevice = nil
    }

    /// 换一个能吐 YUV 的格式。
    ///
    /// 只在前一条通路不可用时才走这里（例如 Bayer 转换器没起来）。
    /// 逐个子尝试是必要的：能否出 YUV 只有 commit 之后读
    /// `availableVideoPixelFormatTypes` 才知道，没有静态查询接口。
    private func adoptProcessedFormat(
        device: AVCaptureDevice,
        output: AVCaptureVideoDataOutput,
        result: inout Configuration
    ) -> OSType? {
        let current = device.activeFormat
        let candidates = device.formats
            .filter { $0 !== current && !$0.videoSupportedFrameRateRanges.isEmpty }
            .sorted { lhs, rhs in
                let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                return Int(l.width) * Int(l.height) > Int(r.width) * Int(r.height)
            }
            .prefix(8)

        for candidate in candidates {
            var scratch = result
            session.beginConfiguration()
            applyDeviceSettings(
                device: device,
                format: candidate,
                lockWhiteBalance: false,
                result: &scratch
            )
            session.commitConfiguration()

            if let code = Self.firstProcessedFormat(from: output.availableVideoPixelFormatTypes) {
                let dims = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription)
                result.notes.append("降级尺寸 \(dims.width)×\(dims.height)")
                return code
            }
        }
        return nil
    }

    private func applyDeviceSettings(
        device: AVCaptureDevice,
        format: AVCaptureDevice.Format,
        lockWhiteBalance: Bool,
        result: inout Configuration
    ) {
        do {
            try device.lockForConfiguration()

            if device.activeFormat != format {
                device.activeFormat = format
            }

            // 精确 24.000：分子分母都用整数，不取 1001/24000
            let target = CMTime(value: 1, timescale: CMTimeScale(VideoSettingsBuilder.frameRate))
            let range = format.videoSupportedFrameRateRanges.first
            let supportsTarget = range.map {
                Double($0.minFrameRate) <= 24.0001 && Double($0.maxFrameRate) >= 23.9999
            } ?? false

            if supportsTarget {
                device.activeVideoMinFrameDuration = target
                device.activeVideoMaxFrameDuration = target
                let applied = device.activeVideoMinFrameDuration
                result.isExact24 = (applied.value == 1 && applied.timescale == 24)
                if !result.isExact24 {
                    result.notes.append("帧率被系统改为 \(applied.value)/\(applied.timescale)")
                }
            } else {
                result.notes.append("该格式帧率范围不含 24，无法锁定")
            }

            // 曝光交给 ExposureController：这里只确保初始处于自动，
            // 避免上一次会话残留的 custom 值把画面冻住。
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            result.exposureLocked = false

            if lockWhiteBalance {
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                    result.whiteBalanceLocked = true
                } else {
                    result.notes.append("不支持锁定白平衡")
                }
            }

            // 对焦交给 FocusController，这里只负责回到自动。
            //
            // 早先这里写的是 `focusMode = .locked`，注释声称「锁在无限远附近」，
            // 但 `.locked` 只是**冻结当时的镜头位置**，并不会移到无限远。
            // 上一次会话停在近处时，之后每次启动都从那个近距离开始并立刻冻住，
            // 于是远处永远虚焦、转动机身也不重新合焦——这就是「无法对焦」。
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            result.focusLocked = false

            device.unlockForConfiguration()
        } catch {
            result.notes.append("设备锁定失败：\(error.localizedDescription)")
        }
    }

    private func attachAudio(result: inout Configuration) -> Bool {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            result.notes.append("找不到麦克风")
            return false
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                result.notes.append("会话拒绝音频输入")
                return false
            }
            session.addInput(input)
            audioInput = input
        } catch {
            result.notes.append("创建音频输入失败：\(error.localizedDescription)")
            return false
        }

        let output = AVCaptureAudioDataOutput()
        // 注意：AVCaptureAudioDataOutput.audioSettings 在 iOS 上不可用（macOS 专属），
        // 音频交付格式由设备的音频连接决定。要 48 kHz / 16-bit LPCM 落盘，
        // 由 AVAssetWriterInput 的 outputSettings 完成格式转换——见 AudioSettings.writerSettings。
        guard session.canAddOutput(output) else {
            result.notes.append("会话拒绝音频输出")
            return false
        }
        session.addOutput(output)
        audioOutput = output
        output.setSampleBufferDelegate(self, queue: audioQueue)
        return true
    }

    // MARK: - 运行

    func start() {
        guard !session.isRunning else { return }
        session.startRunning()

        // startRunning 也可能重置帧时长，跑起来之后再钉一次
        if let device = videoDevice {
            enforceFrameRate(device: device)
        }
    }

    /// 把设备帧时长钉到 1/24，并返回是否成功。
    ///
    /// 会话的 commit 与 startRunning 都会把 `activeVideoMinFrameDuration`
    /// 还原成格式默认值（实测回到 60 fps）。探针数据已证实：
    /// 只在配置前设置一次，回读虽是 1/24，实际到达的帧仍是 60 fps。
    @discardableResult
    private func enforceFrameRate(device: AVCaptureDevice) -> Bool {
        let target = CMTime(value: 1, timescale: CMTimeScale(VideoSettingsBuilder.frameRate))
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            Double($0.minFrameRate) <= 24.001 && Double($0.maxFrameRate) >= 23.999
        }
        guard supported else { return false }

        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = target
            device.activeVideoMaxFrameDuration = target
            device.unlockForConfiguration()
            return true
        } catch {
            return false
        }
    }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    var isRunning: Bool { session.isRunning }

    // MARK: - 设备与格式选择

    static func backWideCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        return discovery.devices.first
    }

    /// 优先 4224×3024（Open Gate）；否则退到面积最大的视频格式。
    ///
    /// 注意：任务书把 4224×3024 称作"4:3"，实际比例是 1.397:1。
    /// 真正的 4:3 全传感器是 4032×3024。这里按**像素面积**取最大，
    /// 不按 4:3 筛选——否则会把最重要的 4224×3024 排除掉。
    static func openGateFormat(in device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let videoFormats = device.formats.filter { !$0.videoSupportedFrameRateRanges.isEmpty }

        if let exact = videoFormats.first(where: {
            let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dims.width == 4224 && dims.height == 3024
        }) {
            return exact
        }

        return videoFormats.max { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(l.width) * Int(l.height) < Int(r.width) * Int(r.height)
        }
    }

    /// 按通路挑像素格式。
    ///
    /// systemProcessed 优先 10-bit 全幅 YUV；退到 8-bit；再退 BGRA。
    /// bayerDirect 只接受 Bayer 四字符码。
    ///
    /// 一条都不能漏：选不出格式时**绝不能**把 `videoSettings` 留空——
    /// 留空等于向系统要默认的 420v，而全幅格式给不出，结果是零帧。
    static func choosePixelFormat(from available: [OSType], path: Path) -> OSType? {
        guard !available.isEmpty else { return nil }

        switch path {
        case .systemProcessed:
            if let processed = firstProcessedFormat(from: available) { return processed }
            // 系统 ISP 一步都走不通：退回 Bayer，交给自建管线
            return available.first { FourCC.isBayer($0) }

        case .bayerDirect:
            return available.first { FourCC.isBayer($0) } ?? firstProcessedFormat(from: available)
        }
    }

    /// 能直接喂编码器的格式（10-bit → 8-bit → BGRA）
    static func firstProcessedFormat(from available: [OSType]) -> OSType? {
        let preferred: [OSType] = [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA,
        ]
        return preferred.first { available.contains($0) }
    }
}

// MARK: - 输出代理

extension CaptureController: AVCaptureVideoDataOutputSampleBufferDelegate,
                            AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === videoOutput {
            deliveredVideoFrames += 1
            onVideoSample?(sampleBuffer)
        } else if output === audioOutput {
            onAudioSample?(sampleBuffer)
        }
    }
}
