import Foundation
import AVFoundation
import CoreImage
import CoreVideo

/// 把已录好的 ProRes RAW 转成 HEVC + Apple Log 2。
///
/// 与 PC 端 `tools/opengate_log2.py` 同一条思路：解出画面 → 套 Apple Log 2
/// 曲线 → 编码 → 注入 colr(9/2/9) 与 logs 标识。
///
/// 差别只在解码那一层：PC 能拿到 16-bit Bayer（ffmpeg 熵解码），
/// iOS 的 ProRes RAW 解码器不给 Bayer，只给成品 YUV。所以这里是对
/// 系统解码结果套曲线，而不是从传感器线性值起算——这一点会在
/// `Report.sourceFormat` 里如实写出来。
final class Log2Transcoder {

    struct Report {
        var sourceFormat = "—"
        var bitDepth = 0
        var width = 0
        var height = 0
        var frames = 0
        var audioBuffers = 0
        var appliedCurve = false
        var tagDelta = 0
        var elapsed: TimeInterval = 0

        var summary: String {
            "\(width)×\(height) · \(sourceFormat) \(bitDepth)bit · \(frames) 帧"
                + (appliedCurve ? " · 已套 Log 2 曲线" : " · 直通")
                + (audioBuffers > 0 ? " · 音频 \(audioBuffers) 块" : " · 无音频")
                + " · 标记 +\(tagDelta)B"
        }
    }

    enum TranscodeError: LocalizedError {
        case noVideoTrack
        case readerFailed(String)
        case writerFailed(String)
        case pixelBufferFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "文件里没有视频轨"
            case .readerFailed(let d): return "读取失败：\(d)"
            case .writerFailed(let d): return "写入失败：\(d)"
            case .pixelBufferFailed: return "像素缓冲创建失败"
            }
        }
    }

    // Apple Log 2 曲线常数（白皮书）
    private static let gamma: Float = 0.08550479
    private static let beta: Float = 0.00964052
    private static let delta: Float = 0.69336945
    private static let c: Float = 47.28711236
    private static let r0: Float = -0.05641088
    private static let rt: Float = 0.01

    /// 曲线内核。分段：R≥Rt 对数，R0≤R<Rt 抛物线，R<R0 归零。
    private static let curveKernelSource = """
    kernel vec4 log2curve(__sample s) {
        vec3 r = clamp(s.rgb, 0.0, 1.0);
        vec3 logPart = %GAMMA% * log2(r + %BETA%) + %DELTA%;
        vec3 diff = r - (%R0%);
        vec3 toe = %C% * diff * diff;
        vec3 outRGB = mix(toe, logPart, step(%RT%, r));
        outRGB = mix(vec3(0.0), outRGB, step(%R0%, r));
        return vec4(clamp(outRGB, 0.0, 1.0), s.a);
    }
    """

    @discardableResult
    static func run(rawURL: URL,
                    outputURL: URL,
                    applyCurve: Bool = true,
                    bitRate: Int = 45_000_000,
                    log: @escaping (String) -> Void = { _ in }) async throws -> Report {

        let t0 = Date()
        var report = Report()

        let asset = AVURLAsset(url: rawURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw TranscodeError.noVideoTrack
        }
        let size = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        report.width = Int(size.width)
        report.height = Int(size.height)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        // ---- 解码：优先 10-bit，退 8-bit ----
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw TranscodeError.readerFailed(error.localizedDescription)
        }

        let candidates: [OSType] = [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        var chosen: OSType?
        var videoOutput: AVAssetReaderTrackOutput?
        for code in candidates {
            let output = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: code]
            )
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                chosen = code
                videoOutput = output
                break
            }
        }
        guard let videoOutput, let chosen else {
            throw TranscodeError.readerFailed("解码器不接受任何输出格式")
        }
        report.sourceFormat = fourCC(chosen)
        report.bitDepth = (chosen == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ? 8 : 10

        // ---- 音频：原样搬运 ----
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                audioOutput = out
            }
        }

        guard reader.startReading() else {
            throw TranscodeError.readerFailed(reader.error?.localizedDescription ?? "无法开始读取")
        }

        // ---- 编码 ----
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw TranscodeError.writerFailed(error.localizedDescription)
        }

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: 24,
            AVVideoMaxKeyFrameIntervalKey: 240,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: "HEVC_Main10_AutoLevel",
        ]
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: report.width,
            AVVideoHeightKey: report.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ]
        videoSettings["AVVideoLogTransferFunctionKey"] = "AppleLog2"
        _ = compression

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else {
            throw TranscodeError.writerFailed("写入器拒绝 HEVC 参数")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else {
            throw TranscodeError.writerFailed(writer.error?.localizedDescription ?? "无法开始写入")
        }
        writer.startSession(atSourceTime: .zero)

        // ---- 曲线内核 ----
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var kernel: CIColorKernel?
        if applyCurve {
            let source = curveKernelSource
                .replacingOccurrences(of: "%GAMMA%", with: "\(gamma)")
                .replacingOccurrences(of: "%BETA%", with: "\(beta)")
                .replacingOccurrences(of: "%DELTA%", with: "\(delta)")
                .replacingOccurrences(of: "%C%", with: "\(c)")
                .replacingOccurrences(of: "%R0%", with: "\(r0)")
                .replacingOccurrences(of: "%RT%", with: "\(rt)")
            kernel = CIColorKernel(source: source)
            if kernel == nil {
                log("曲线内核编译失败，退回直通")
                report.appliedCurve = false
            } else {
                report.appliedCurve = true
            }
        }

        let outputFormat = chosen
        var attachments: [CFString: Any] = [:]
        let dstAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: outputFormat,
            kCVPixelBufferWidthKey: report.width,
            kCVPixelBufferHeightKey: report.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        func makeDestination() -> CVPixelBuffer? {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, report.width, report.height,
                                outputFormat, dstAttributes as CFDictionary, &buffer)
            return buffer
        }
        _ = attachments

        // ---- 视频循环 ----
        let videoQueue = DispatchQueue(label: "opengate.log2.video")
        let videoSemaphore = DispatchSemaphore(value: 0)
        var videoError: String?

        videoInput.requestMediaDataWhenReady(on: videoQueue) { [weak videoInput] in
            guard let videoInput else { return }
            while videoInput.isReadyForMoreMediaData {
                guard let sample = videoOutput.copyNextSampleBuffer() else {
                    videoInput.markAsFinished()
                    videoSemaphore.signal()
                    return
                }
                guard let src = CMSampleBufferGetImageBuffer(sample) else { continue }

                var toAppend: CVPixelBuffer = src
                if let kernel {
                    let ci = CIImage(cvPixelBuffer: src)
                    if let out = kernel.apply(extent: ci.extent, arguments: [ci]),
                       let dst = makeDestination() {
                        context.render(out, to: dst, bounds: ci.extent, colorSpace: nil)
                        toAppend = dst
                    }
                }

                var timed: CMSampleBuffer?
                var timing = CMSampleTimingInfo(
                    duration: CMSampleBufferGetDuration(sample),
                    presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
                    decodeTimeStamp: .invalid
                )
                CMSampleBufferCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: toAppend,
                    dataReady: true,
                    makeDataReadyCallback: nil,
                    refcon: nil,
                    formatDescription: CMSampleBufferGetFormatDescription(sample)!,
                    sampleTiming: &timing,
                    sampleBufferOut: &timed
                )
                if let timed {
                    if !videoInput.append(timed) {
                        videoError = writer.error?.localizedDescription ?? "append 被拒"
                        videoInput.markAsFinished()
                        videoSemaphore.signal()
                        return
                    }
                    report.frames += 1
                }
            }
        }

        // ---- 音频循环 ----
        var audioDone = true
        if let audioInput, let audioOutput {
            audioDone = false
            let queue = DispatchQueue(label: "opengate.log2.audio")
            let sem = DispatchSemaphore(value: 0)
            audioInput.requestMediaDataWhenReady(on: queue) { [weak audioInput] in
                guard let audioInput else { return }
                while audioInput.isReadyForMoreMediaData {
                    guard let sample = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        sem.signal()
                        return
                    }
                    if audioInput.append(sample) {
                        report.audioBuffers += 1
                    }
                }
            }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                sem.wait()
                c.resume()
            }
        }
        _ = audioDone

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            videoSemaphore.wait()
            c.resume()
        }

        if let videoError {
            writer.cancelWriting()
            throw TranscodeError.writerFailed(videoError)
        }

        await writer.finishWriting()
        if writer.status == .failed {
            throw TranscodeError.writerFailed(writer.error?.localizedDescription ?? "未知")
        }
        reader.cancelReading()

        // ---- 注入标记 ----
        let tag = try MovTag.inject(outputURL)
        report.tagDelta = tag.delta
        report.elapsed = Date().timeIntervalSince(t0)
        log("完成：\(report.summary)")
        return report
    }

    private static func fourCC(_ code: OSType) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                     UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return (String(bytes: bytes, encoding: .ascii) ?? "?").trimmingCharacters(in: .whitespaces)
    }
}
