import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo
import CoreMedia
import UIKit

enum ProbeEngine {

    // MARK: - 主入口

    static func run(onStep: @escaping (String) -> Void) -> ProbeReport {
        var recorder = StepRecorder(onStep: onStep)
        let environment = environmentInfo()
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"

        recorder.log("开始探测：环境信息已采集")

        guard let device = DeviceProbe.mainDevice() else {
            recorder.log("未找到后置广角相机，终止")
            return ProbeReport(
                schemaVersion: 1,
                appVersion: appVersion,
                generatedAt: isoNow(),
                device: DeviceInfo(
                    machineIdentifier: machineIdentifier(),
                    systemName: UIDevice.current.systemName,
                    systemVersion: UIDevice.current.systemVersion,
                    deviceName: UIDevice.current.name,
                    cameraCount: 0,
                    formatCount: 0,
                    activeFormat: "无",
                    maxPhotoDimensions: nil
                ),
                environment: environment,
                formats: [],
                pixelFormatProbe: PixelFormatProbe(
                    configuredFormat: "无",
                    availablePixelFormats: [],
                    bayerFormats: [],
                    has10Bit420: false,
                    has8Bit420: false,
                    hasBGRA: false,
                    note: "设备不可用"
                ),
                encoderChecks: [],
                writerChecks: [],
                verdicts: [
                    Verdict(key: "device", level: .fail, message: "无法获取后置广角相机")
                ],
                steps: recorder.steps
            )
        }

        // 1. 设备与格式
        let formats = DeviceProbe.enumerate(device)
        let videoFormats = formats.filter { $0.isVideoCapable }
        recorder.log("枚举 \(formats.count) 个格式，其中视频格式 \(videoFormats.count) 个")

        let activeDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let deviceInfo = DeviceInfo(
            machineIdentifier: machineIdentifier(),
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            deviceName: UIDevice.current.name,
            cameraCount: 1,
            formatCount: formats.count,
            activeFormat: "\(activeDimensions.width)x\(activeDimensions.height)",
            maxPhotoDimensions: nil
        )

        if let openGate = videoFormats.first(where: { $0.isOpenGateCandidate }) {
            recorder.log("命中 4224x3024 视频格式：\(openGate.pixelFormat)，最高 \(openGate.maxFrameRate) fps")
        } else {
            recorder.log("未命中 4224x3024 视频格式")
        }

        // 2. 目标采集格式
        let targetFormat = DeviceProbe.targetFormat(in: device)
        var captureWidth: Int32 = 4224
        var captureHeight: Int32 = 3024
        if let targetFormat = targetFormat {
            let dimensions = CMVideoFormatDescriptionGetDimensions(targetFormat.formatDescription)
            captureWidth = dimensions.width
            captureHeight = dimensions.height
            recorder.log("目标采集格式：\(DeviceProbe.describe(targetFormat))")
        } else {
            recorder.log("未找到 4:3 视频格式，编码器测试按 4224x3024 进行")
        }

        // 3. 像素格式
        recorder.log("配置采集会话，读取可用像素格式")
        let pixelProbe = DeviceProbe.probePixelFormats(device: device, target: targetFormat)
        recorder.log("可用像素格式 \(pixelProbe.availablePixelFormats.count) 种：\(pixelProbe.availablePixelFormats.joined(separator: " "))")
        if !pixelProbe.bayerFormats.isEmpty {
            recorder.log("检测到 Bayer 格式：\(pixelProbe.bayerFormats.joined(separator: " "))")
        } else {
            recorder.log("未检测到 Bayer 格式")
        }

        // 4. 编码器
        var encoderChecks: [EncoderCheck] = []

        recorder.log("查询 HEVC 编码器在 4224x3024 的支持性")
        encoderChecks.append(
            EncoderProbe.check(
                label: "HEVC-4224x3024",
                codec: kCMVideoCodecType_HEVC,
                width: 4224,
                height: 3024,
                inputPixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                profileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel
            )
        )

        if captureWidth != 4224 || captureHeight != 3024 {
            recorder.log("查询 HEVC 编码器在实际采集尺寸 \(captureWidth)x\(captureHeight) 的支持性")
            encoderChecks.append(
                EncoderProbe.check(
                    label: "HEVC-\(captureWidth)x\(captureHeight)",
                    codec: kCMVideoCodecType_HEVC,
                    width: captureWidth,
                    height: captureHeight,
                    inputPixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                    profileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel
                )
            )
        }

        recorder.log("查询 HEVC 编码器在 4096x2160 的基线支持性")
        encoderChecks.append(
            EncoderProbe.check(
                label: "HEVC-4096x2160",
                codec: kCMVideoCodecType_HEVC,
                width: 4096,
                height: 2160,
                inputPixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                profileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel
            )
        )

        recorder.log("查询 ProRes 422 HQ 在 4224x3024 的支持性")
        encoderChecks.append(
            EncoderProbe.check(
                label: "ProResHQ-4224x3024",
                codec: kCMVideoCodecType_AppleProRes422HQ,
                width: 4224,
                height: 3024,
                inputPixelFormat: FourCC.code("x422"),
                profileLevel: nil
            )
        )

        recorder.log("查询 ProRes 422 LT 在 4224x3024 的支持性")
        encoderChecks.append(
            EncoderProbe.check(
                label: "ProResLT-4224x3024",
                codec: kCMVideoCodecType_AppleProRes422LT,
                width: 4224,
                height: 3024,
                inputPixelFormat: FourCC.code("x422"),
                profileLevel: nil
            )
        )

        for check in encoderChecks {
            let preserved = check.dimensionsPreserved.map { $0 ? "尺寸保持" : "尺寸被改" } ?? "无输出"
            recorder.log("\(check.label)：会话 \(check.sessionCreated ? "成功" : "失败")，\(preserved)")
        }

        // 5. Writer
        var writerChecks: [WriterCheck] = []

        recorder.log("验证 AVAssetWriter 输出设置")
        writerChecks.append(
            EncoderProbe.checkWriter(
                label: "ProRes422HQ-4224x3024",
                codec: .proRes422HQ,
                width: 4224,
                height: 3024
            )
        )
        writerChecks.append(
            EncoderProbe.checkWriter(
                label: "ProRes422LT-4224x3024",
                codec: .proRes422LT,
                width: 4224,
                height: 3024
            )
        )
        writerChecks.append(
            EncoderProbe.checkWriter(
                label: "HEVC-4224x3024",
                codec: .hevc,
                width: 4224,
                height: 3024
            )
        )

        for check in writerChecks {
            recorder.log("\(check.label)：canApply \(check.canApplySettings)，startWriting \(check.startWriting)")
        }

        // 6. Phase 2：真机实测（精确 24fps、btp2 真实帧结构、RAW 元数据、帧到达率）
        var frameRateCheck: FrameRateCheck?
        var liveCapture: LiveCaptureResult?

        if let targetFormat = targetFormat {
            recorder.log("Phase 2：锁定 24fps 并采集真实帧")
            let liveProbe = LiveCaptureProbe()
            let liveResult = liveProbe.run(device: device, format: targetFormat)
            frameRateCheck = liveResult.rate
            liveCapture = liveResult.capture

            if let rate = liveResult.rate {
                recorder.log("帧率回读：\(rate.setStatus)（\(rate.actualValue)/\(rate.actualTimescale)）")
            }
            recorder.log("采集结束：收到 \(liveResult.capture.framesReceived) 帧，实测 \(liveResult.capture.measuredFPS) fps")
            if let structure = liveResult.capture.structure {
                recorder.log("帧结构：\(structure.width)x\(structure.height) \(structure.pixelFormat) bytesPerRow=\(structure.bytesPerRow) 期望=\(structure.expectedBytesPerRowFor12Bit)")
            }
            if !liveResult.capture.sampleBufferAttachmentKeys.isEmpty {
                recorder.log("RAW 元数据键 \(liveResult.capture.sampleBufferAttachmentKeys.count) 个")
            }
        } else {
            recorder.log("Phase 2 跳过：没有可用的目标格式")
        }

        // 7. 结论
        let verdicts = buildVerdicts(
            formats: formats,
            pixelProbe: pixelProbe,
            encoderChecks: encoderChecks,
            writerChecks: writerChecks,
            frameRateCheck: frameRateCheck,
            liveCapture: liveCapture,
            captureWidth: captureWidth,
            captureHeight: captureHeight
        )

        recorder.log("探测完成，共 \(verdicts.count) 条结论")

        return ProbeReport(
            schemaVersion: 1,
            appVersion: appVersion,
            generatedAt: isoNow(),
            device: deviceInfo,
            environment: environment,
            formats: formats,
            pixelFormatProbe: pixelProbe,
            encoderChecks: encoderChecks,
            writerChecks: writerChecks,
            frameRateCheck: frameRateCheck,
            liveCapture: liveCapture,
            verdicts: verdicts,
            steps: recorder.steps
        )
    }

    // MARK: - 结论生成

    private static func buildVerdicts(
        formats: [FormatInfo],
        pixelProbe: PixelFormatProbe,
        encoderChecks: [EncoderCheck],
        writerChecks: [WriterCheck],
        frameRateCheck: FrameRateCheck?,
        liveCapture: LiveCaptureResult?,
        captureWidth: Int32,
        captureHeight: Int32
    ) -> [Verdict] {

        var verdicts: [Verdict] = []
        let videoFormats = formats.filter { $0.isVideoCapable }

        // 全幅格式
        if let openGate = videoFormats.first(where: { $0.isOpenGateCandidate }) {
            verdicts.append(
                Verdict(
                    key: "opengate-format",
                    level: .pass,
                    message: "4224x3024 视频格式存在，最高 \(openGate.maxFrameRate) fps，支持 24fps：\(openGate.supports24 ? "是" : "否")"
                )
            )
        } else {
            let largest = videoFormats.filter { $0.is4x3 }.max { $0.megapixels < $1.megapixels }
            let description = largest.map { "\($0.width)x\($0.height)" } ?? "无 4:3 视频格式"
            verdicts.append(
                Verdict(
                    key: "opengate-format",
                    level: .fail,
                    message: "未找到 4224x3024 视频格式；当前最大 4:3 视频尺寸为 \(description)。全幅需求需重新评估"
                )
            )
        }

        // Bayer
        if !pixelProbe.bayerFormats.isEmpty {
            verdicts.append(
                Verdict(
                    key: "bayer-video",
                    level: .pass,
                    message: "AVCaptureVideoDataOutput 暴露 Bayer 格式：\(pixelProbe.bayerFormats.joined(separator: ", "))"
                )
            )
        } else {
            verdicts.append(
                Verdict(
                    key: "bayer-video",
                    level: .warn,
                    message: "未暴露 Bayer 视频像素格式。前端需改用 10-bit YUV 采集合成，或走 AVCapturePhotoOutput 逐帧 RAW"
                )
            )
        }

        // 采集位深：Bayer 路线的位深高于任何 YUV 格式，不能只查 YUV 四字符码
        let bayerBitDepth = pixelProbe.bayerFormats
            .compactMap { FourCC.bayerBitDepth(FourCC.code($0)) }
            .max()
        let hasHighBitDepth = pixelProbe.has10Bit420 || bayerBitDepth != nil
        let depthDescription: String = {
            var parts: [String] = []
            if let depth = bayerBitDepth {
                parts.append("Bayer \(depth)-bit")
            }
            if pixelProbe.has10Bit420 {
                parts.append("YUV 10-bit 4:2:0")
            }
            return parts.joined(separator: " + ")
        }()
        verdicts.append(
            Verdict(
                key: "bit-depth",
                level: hasHighBitDepth ? .pass : .fail,
                message: hasHighBitDepth
                    ? "输入位深充足：\(depthDescription)"
                    : "无 10-bit 以上采集格式，Apple Log 管线位深不足"
            )
        )

        // HEVC 天花板
        if let hevcOpenGate = encoderChecks.first(where: { $0.label == "HEVC-4224x3024" }) {
            if hevcOpenGate.sessionCreated, hevcOpenGate.dimensionsPreserved == true {
                verdicts.append(
                    Verdict(
                        key: "hevc-ceiling",
                        level: .pass,
                        message: "HEVC 编码器接受 4224x3024 且输出分辨率未被改变，档 2 / 档 3 成立"
                    )
                )
            } else if hevcOpenGate.sessionCreated, hevcOpenGate.dimensionsPreserved == false {
                let actual = "\(hevcOpenGate.encodedWidth ?? 0)x\(hevcOpenGate.encodedHeight ?? 0)"
                verdicts.append(
                    Verdict(
                        key: "hevc-ceiling",
                        level: .fail,
                        message: "HEVC 编码器把 4224x3024 静默改为 \(actual)，档 2 / 档 3 不可用"
                    )
                )
            } else {
                verdicts.append(
                    Verdict(
                        key: "hevc-ceiling",
                        level: .fail,
                        message: "HEVC 会话在 4224x3024 创建失败（状态码 \(hevcOpenGate.sessionCreateStatus)），档 2 / 档 3 不可用"
                    )
                )
            }
        }

        // HEVC 基线
        if let baseline = encoderChecks.first(where: { $0.label == "HEVC-4096x2160" }) {
            verdicts.append(
                Verdict(
                    key: "hevc-baseline",
                    level: baseline.sessionCreated ? .pass : .fail,
                    message: baseline.sessionCreated
                        ? "HEVC 在 4096x2160 基线正常，硬件编码器本身可用"
                        : "HEVC 在 4096x2160 也无法创建（状态码 \(baseline.sessionCreateStatus)），问题不在分辨率"
                )
            )
        }

        // ProRes
        for label in ["ProResHQ-4224x3024", "ProResLT-4224x3024"] {
            guard let prores = encoderChecks.first(where: { $0.label == label }) else { continue }
            let variant = label.contains("HQ") ? "HQ" : "LT"
            let writer = writerChecks.first(where: { $0.label.contains("ProRes") && $0.label.contains(variant) })
            let writerOK = writer?.canApplySettings ?? false
            verdicts.append(
                Verdict(
                    key: label,
                    level: prores.sessionCreated ? .pass : .fail,
                    message: prores.sessionCreated
                        ? "\(label) 会话创建成功，writer 接受设置：\(writerOK ? "是" : "否")"
                        : "\(label) 会话创建失败（状态码 \(prores.sessionCreateStatus)）"
                )
            )
        }

        // 精确 24fps
        if let best = videoFormats.filter({ $0.supports24 }).max(by: { $0.megapixels < $1.megapixels }) {
            verdicts.append(
                Verdict(
                    key: "fps-24",
                    level: .pass,
                    message: "\(best.width)x\(best.height) 格式支持 24fps，范围 \(best.ranges.map { "\($0.min)-\($0.max)" }.joined(separator: ", "))"
                )
            )
        } else {
            verdicts.append(
                Verdict(
                    key: "fps-24",
                    level: .fail,
                    message: "未找到支持 24fps 的 4:3 视频格式"
                )
            )
        }

        // 防抖可关
        let activeSupport = videoFormats.filter { $0.width == captureWidth && $0.height == captureHeight }
        let stabilizationOff: Bool? = activeSupport.isEmpty
            ? nil
            : activeSupport.allSatisfy { $0.stabilizationOffSupported }
        verdicts.append(
            Verdict(
                key: "stabilization-off",
                level: stabilizationOff == nil ? .unknown : (stabilizationOff! ? .pass : .warn),
                message: stabilizationOff == nil
                    ? "格式列表中无 \(captureWidth)x\(captureHeight) 视频格式，无法判定防抖开关"
                    : (stabilizationOff! ? "目标格式支持关闭视频防抖" : "目标格式可能不支持关闭防抖，需实测画面裁切")
            )
        )

        // Phase 2：精确 24fps 回读
        if let rate = frameRateCheck {
            if rate.isExact24 {
                verdicts.append(
                    Verdict(
                        key: "fps-24-exact",
                        level: .pass,
                        message: "回读帧时长 \(rate.actualValue)/\(rate.actualTimescale)，精确 24.000 fps"
                    )
                )
            } else if rate.isNTSC23976 {
                verdicts.append(
                    Verdict(
                        key: "fps-24-exact",
                        level: .fail,
                        message: "设备把 1/24 改成了 1001/24000（23.976），不是精确 24.000"
                    )
                )
            } else {
                verdicts.append(
                    Verdict(
                        key: "fps-24-exact",
                        level: .fail,
                        message: "请求 1/24，回读为 \(rate.actualValue)/\(rate.actualTimescale)（\(rate.actualSeconds) 秒）"
                    )
                )
            }
        }

        // Phase 2：btp2 真实帧结构与 RAW 元数据
        if let live = liveCapture {
            if let structure = live.structure {
                verdicts.append(
                    Verdict(
                        key: "bayer-frame-structure",
                        level: structure.matchesExpectedLayout ? .pass : .warn,
                        message: "\(structure.width)x\(structure.height) \(structure.pixelFormat)，bytesPerRow \(structure.bytesPerRow)，12-bit 期望 \(structure.expectedBytesPerRowFor12Bit)\(structure.matchesExpectedLayout ? "，布局吻合" : "，布局不符需重新解包")"
                    )
                )
            } else {
                verdicts.append(
                    Verdict(
                        key: "bayer-frame-structure",
                        level: .fail,
                        message: "未取到真实帧：\(live.note)"
                    )
                )
            }

            let metadataCount = live.sampleBufferAttachmentKeys.count + live.pixelBufferAttachmentKeys.count
            verdicts.append(
                Verdict(
                    key: "raw-metadata",
                    level: metadataCount > 0 ? .pass : .warn,
                    message: metadataCount > 0
                        ? "RAW 元数据可得：sampleBuffer \(live.sampleBufferAttachmentKeys.count) 项、pixelBuffer \(live.pixelBufferAttachmentKeys.count) 项"
                        : "未读到 RAW 元数据附件，黑白电平与 WB 需另寻来源"
                )
            )

            if live.framesReceived > 1 {
                let inRange = live.measuredFPS > 23.0 && live.measuredFPS < 25.0
                verdicts.append(
                    Verdict(
                        key: "capture-rate",
                        level: inRange ? .pass : .warn,
                        message: "实测 \(live.measuredFPS) fps，帧间隔 \(live.intervalMinMS)–\(live.intervalMaxMS) ms（均值 \(live.intervalAvgMS) ms）"
                    )
                )
            }
        }

        return verdicts
    }

    // MARK: - 环境

    static func environmentInfo() -> EnvironmentInfo {
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ])

        let available = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        let total = Int64(values?.volumeTotalCapacity ?? 0)

        return EnvironmentInfo(
            thermalState: thermal,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            availableDiskBytes: available,
            totalDiskBytes: total,
            physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            processorCount: ProcessInfo.processInfo.processorCount
        )
    }
}
