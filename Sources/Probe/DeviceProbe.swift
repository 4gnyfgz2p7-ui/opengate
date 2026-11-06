import Foundation
import AVFoundation
import CoreMedia
import UIKit
import Darwin

enum DeviceProbe {

    // MARK: - 设备

    static func mainDevice() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        if let back = discovery.devices.first(where: { $0.position == .back }) {
            return back
        }
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }

    // MARK: - 格式枚举

    static func enumerate(_ device: AVCaptureDevice) -> [FormatInfo] {
        var results: [FormatInfo] = []
        results.reserveCapacity(device.formats.count)

        for (index, format) in device.formats.enumerated() {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges

            let rangeInfos: [FrameRateRangeInfo] = ranges.map { range in
                FrameRateRangeInfo(
                    min: Double(range.minFrameRate),
                    max: Double(range.maxFrameRate),
                    minDurationSeconds: CMTimeGetSeconds(range.minFrameDuration),
                    maxDurationSeconds: CMTimeGetSeconds(range.maxFrameDuration)
                )
            }

            let maxRate = ranges.map { Double($0.maxFrameRate) }.max() ?? 0
            let minRate = ranges.map { Double($0.minFrameRate) }.min() ?? 0
            let supports24 = !ranges.isEmpty && minRate <= 24.0001 && maxRate >= 23.9999
            let isFourThree = dimensions.width > 0 && Int(dimensions.width) * 3 == Int(dimensions.height) * 4
            let megapixels = Double(dimensions.width) * Double(dimensions.height) / 1_000_000.0

            results.append(
                FormatInfo(
                    index: index,
                    width: dimensions.width,
                    height: dimensions.height,
                    pixelFormat: FourCC.string(subType),
                    isVideoCapable: !ranges.isEmpty,
                    is4x3: isFourThree,
                    isOpenGateCandidate: dimensions.width == 4224 && dimensions.height == 3024,
                    megapixels: (megapixels * 100).rounded() / 100,
                    ranges: rangeInfos,
                    supports24: supports24,
                    maxFrameRate: maxRate,
                    stabilizationOffSupported: format.isVideoStabilizationModeSupported(.off)
                )
            )
        }

        return results
    }

    // MARK: - 目标格式选择

    /// 优先取 4224×3024（Open Gate）的视频格式；没有则退到面积最大的 4:3 视频格式。
    static func targetFormat(in device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let videoFormats = device.formats.filter { !$0.videoSupportedFrameRateRanges.isEmpty }

        if let openGate = videoFormats.first(where: { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width == 4224 && dims.height == 3024
        }) {
            return openGate
        }

        let fourThree = videoFormats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width > 0 && Int(dims.width) * 3 == Int(dims.height) * 4
        }

        let sorted = fourThree.sorted { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(l.width) * Int(l.height) > Int(r.width) * Int(r.height)
        }

        return sorted.first
    }

    static func describe(_ format: AVCaptureDevice.Format) -> String {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        return "\(dims.width)x\(dims.height) \(FourCC.string(subType))"
    }

    // MARK: - 像素格式探测

    /// 配置一次采集会话，读取 `availableVideoPixelFormatTypes`。
    /// 这一项直接回答：Bayer 视频流对第三方 App 是否可得。
    static func probePixelFormats(
        device: AVCaptureDevice,
        target: AVCaptureDevice.Format?
    ) -> PixelFormatProbe {

        var configuredDescription = "未配置"
        var available: [OSType] = []
        var note = ""

        let session = AVCaptureSession()

        do {
            session.beginConfiguration()
            session.sessionPreset = .inputPriority

            if let target = target {
                try device.lockForConfiguration()
                if device.activeFormat != target {
                    device.activeFormat = target
                }
                device.unlockForConfiguration()
                configuredDescription = describe(device.activeFormat)
            } else {
                configuredDescription = describe(device.activeFormat)
            }

            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                note += "无法添加设备输入；"
            }

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            if session.canAddOutput(output) {
                session.addOutput(output)
                available = output.availableVideoPixelFormatTypes
            } else {
                note += "无法添加视频数据输出；"
            }

            session.commitConfiguration()

            if available.isEmpty {
                // 部分系统需在 commit 之后才填充该属性，再读一次。
                available = output.availableVideoPixelFormatTypes
            }
        } catch {
            note += "会话配置异常：\(error.localizedDescription)；"
            session.commitConfiguration()
        }

        let names = available.map { FourCC.string($0) }
        let bayer = available.filter { FourCC.isBayer($0) }.map { FourCC.string($0) }

        let has10Bit420 = available.contains(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            || available.contains(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        let has8Bit420 = available.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            || available.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let hasBGRA = available.contains(kCVPixelFormatType_32BGRA)

        if available.isEmpty {
            note += "可用像素格式为空，可能需要在 startRunning 之后读取。"
        }

        return PixelFormatProbe(
            configuredFormat: configuredDescription,
            availablePixelFormats: names,
            bayerFormats: bayer,
            has10Bit420: has10Bit420,
            has8Bit420: has8Bit420,
            hasBGRA: hasBGRA,
            note: note.isEmpty ? "正常" : note
        )
    }
}
