import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import CoreMedia
import Darwin

/// 把已录好的 ProRes RAW 转成 HEVC + Apple Log 2。
///
/// 与 PC 端 `tools/opengate_log2.py` 同一条思路：解出画面 → 套 Apple Log 2
/// 曲线 → 编码 → 注入 colr(9/2/9) 与 logs 标识。
///
/// ## 为什么是同步单循环
///
/// 早先版本用 `requestMediaDataWhenReady` 分别驱动音视频，两个队列同时改
/// 同一个 `report` 变量，会踩 Swift 的独占访问检查；一旦加上自定义的
/// outputSettings 键，`AVAssetWriterInput` 还会直接抛 ObjC 异常把进程带走，
/// 表现为"选完文件就闪退"。这里改成单线程拉取：音视频在同一个循环里轮询，
/// 不用队列、不用信号量、不用 continuation，出错就是一条日志。
final class Log2Transcoder {

    struct Report {
        var sourceFormat = "—"
        var bitDepth = 0
        var width = 0
        var height = 0
        var frames = 0
        var audioBuffers = 0
        var appliedCurve = false
        var appliedLUT: String?
        var tagDelta = 0
        var elapsed: TimeInterval = 0

        var summary: String {
            "\(width)×\(height) · \(sourceFormat) \(bitDepth)bit · \(frames) 帧"
                + (appliedCurve ? " · 已套 Log 2 曲线" : " · 直通")
                + (appliedLUT.map { " · LUT \($0)" } ?? "")
                + (audioBuffers > 0 ? " · 音频 \(audioBuffers) 块" : " · 无音频")
                + " · 标记 +\(tagDelta)B"
        }
    }

    enum TranscodeError: LocalizedError {
        case noVideoTrack
        case tooShort
        case readerFailed(String)
        case writerFailed(String)
        case tagFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "文件里没有视频轨，或不是可解码的 MOV"
            case .tooShort: return "文件还没下载完成（iCloud 占位）或已损坏"
            case .readerFailed(let d): return "读取失败：\(d)"
            case .writerFailed(let d): return "写入失败：\(d)"
            case .tagFailed(let d): return "写色彩标记失败：\(d)"
            }
        }
    }

    private enum FrameOutcome { case ok, ended, failed }

    // Apple Log 2 曲线常数（白皮书）
    private static let gamma: Float = 0.08550479
    private static let beta: Float = 0.00964052
    private static let delta: Float = 0.69336945
    private static let c: Float = 47.28711236
    private static let r0: Float = -0.05641088
    private static let rt: Float = 0.01

    /// 曲线内核。分段：R≥Rt 对数，R0≤R<Rt 抛物线，R<R0 归零。
    ///
    /// 常数一律带 `f` 后缀 —— 不带的话 OpenCL 会按 double 解析，
    /// 部分 GPU 上直接编译失败，内核返回 nil，曲线被静默跳过。
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

    /// 同步执行。调用方负责放到后台队列，别在主线程调。
    @discardableResult
    static func run(rawURL: URL,
                    outputURL: URL,
                    applyCurve: Bool = true,
                    lut: CubeLUT? = nil,
                    bitRate: Int = 45_000_000,
                    log: (String) -> Void = { _ in }) throws -> Report {

        let t0 = Date()
        var report = Report()

        // ---- 0. 输入体检：iCloud 占位文件在这里就拦下 ----
        let attrs = try? FileManager.default.attributesOfItem(atPath: rawURL.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        log("输入 \(rawURL.lastPathComponent) · \(fileSize / 1_000_000) MB")
        guard fileSize > 4096 else { throw TranscodeError.tooShort }

        let asset = AVURLAsset(url: rawURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ])
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw TranscodeError.noVideoTrack
        }
        let size = videoTrack.naturalSize
        let transform = videoTrack.preferredTransform
        guard size.width >= 2, size.height >= 2 else { throw TranscodeError.noVideoTrack }
        report.width = Int(size.width.rounded())
        report.height = Int(size.height.rounded())
        log("视频轨 \(report.width)×\(report.height) · \(String(format: "%.3f", videoTrack.nominalFrameRate)) fps")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        // ---- 1. 解码 ----
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw TranscodeError.readerFailed(error.localizedDescription)
        }

        // 10-bit 优先。ProRes RAW 解出来通常是 x420；这一代 VT 若只给
        // 8-bit，会落到 p420，报告里如实写出来。
        let candidates: [OSType] = [
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        var chosen: OSType?
        var videoOutput: AVAssetReaderTrackOutput?
        for code in candidates {
            let out = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: code]
            )
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                chosen = code
                videoOutput = out
                break
            }
        }
        guard let videoOutput, let chosen else {
            throw TranscodeError.readerFailed("解码器不接受任何输出格式")
        }
        report.sourceFormat = fourCC(chosen)
        report.bitDepth = (chosen == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ? 8 : 10
        log("解码格式 \(report.sourceFormat) \(report.bitDepth)bit")

        // ---- 2. 音频：原样搬运，不做采样率/位深转换 ----
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                audioOutput = out
                // 音频全程不解码、不重采样、不改位深：读端和写端的
                // outputSettings 都是 nil，样本原样从这里搬到那里。
                if let fmt = audioTrack.formatDescriptions.first as? CMFormatDescription {
                    let code = fourCC(CMFormatDescriptionGetMediaSubType(fmt))
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
                        log("音频原样搬运 · \(code) · \(Int(asbd.mSampleRate)) Hz · \(asbd.mChannelsPerFrame) ch · \(asbd.mBitsPerChannel) bit")
                    } else {
                        log("音频原样搬运 · \(code)")
                    }
                }
            }
        }

        guard reader.startReading() else {
            throw TranscodeError.readerFailed(reader.error?.localizedDescription ?? "无法开始读取")
        }

        // ---- 3. 编码 ----
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw TranscodeError.writerFailed(error.localizedDescription)
        }

        // 这里的键必须都是 AVFoundation 认识的。录制端用的
        // AVVideoLogTransferFunctionKey 确实存在，但转码这边不需要它：
        // Log 身份最后靠 MovTag 注入的 colr + logs 表达，比让 writer
        // 自己写更可控，也不依赖 SDK 版本。
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: 24,
            AVVideoMaxKeyFrameIntervalKey: 240,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: "HEVC_Main10_AutoLevel",
        ]
        let videoSettings: [String: Any] = [
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

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else {
            throw TranscodeError.writerFailed("写入器拒绝 HEVC 参数")
        }
        writer.add(videoInput)

        // 用 adaptor 的缓冲池复用像素缓冲。之前每帧 CVPixelBufferCreate
        // 新建 51 MB IOSurface，113 帧后池子见底、VideoToolbox 被回收。
        // 池化的缓冲在 ARC 释放后会被回收再分配，不会一路涨上去。
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: report.width,
                kCVPixelBufferHeightKey as String: report.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
        )

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            // nil = 不做转码，源是什么格式就写什么格式。
            // 指定 LPCM 16bit 会把 24bit 源降位，且参数不匹配时 append 会被拒。
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
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

        // ---- 4. 曲线 ----
        // workingColorSpace 设 NSNull：不做色彩管理，kernel 拿到什么值就是
        // 什么值，输出也原样落地。否则 CI 会在输入输出两端各做一次 gamma，
        // 套完曲线再被编码一遍，出来的不是 Log。
        // cacheIntermediates 必须关。CoreImage 会把 4224×3024 的中间纹理
        // 缓存起来，几百帧下来把 IOSurface 吃光，VideoToolbox 会话被系统
        // 回收，append 返回 -11819（AVErrorMediaServicesWereReset）。
        let ciContext = CIContext(options: [
            .workingColorSpace: NSNull(),
            .cacheIntermediates: false,
        ])
        let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var kernel: CIColorKernel?
        if applyCurve {
            let source = curveKernelSource
                .replacingOccurrences(of: "%GAMMA%", with: "\(gamma)f")
                .replacingOccurrences(of: "%BETA%", with: "\(beta)f")
                .replacingOccurrences(of: "%DELTA%", with: "\(delta)f")
                .replacingOccurrences(of: "%C%", with: "\(c)f")
                .replacingOccurrences(of: "%R0%", with: "\(r0)f")
                .replacingOccurrences(of: "%RT%", with: "\(rt)f")
            kernel = CIColorKernel(source: source)
            if kernel == nil {
                log("曲线内核编译失败，本片按直通输出")
            } else {
                log("曲线内核就绪（Apple Log 2 · 白皮书常数）")
            }
        }
        var lutFilter: CIFilter?
        if let lut {
            lutFilter = lut.makeFilter()
            if lutFilter == nil {
                log("LUT 滤镜创建失败（\(lut.title)），本片不套 LUT")
            } else {
                report.appliedLUT = "\(lut.title) \(lut.size)³"
                log("LUT 就绪：\(lut.title) · \(lut.size)³")
            }
        }
        report.appliedCurve = (kernel != nil)

        // 渲染目标用 BGRA8：CoreImage 的原生格式，任何机器上都不会失败。
        // 直接渲染到 10-bit YUV 在部分设备上会静默失败或抛异常，不冒这个险。
        let dstAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: report.width,
            kCVPixelBufferHeightKey as String: report.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]

        // 画面矩形。CoreImage 的逐点滤镜（CIColorCube 就是）输出 extent 是
        // 无限矩形，拿它当 render 的 bounds，输出缓冲会留空，编码器随即拒帧。
        // 全程只用这个固定矩形。
        let frameRect = CGRect(x: 0, y: 0, width: report.width, height: report.height)

        func makeDestination() -> CVPixelBuffer? {
            // 先试缓冲池；池暂时空（编码器还没释放）时退回临时分配，
            // 宁可多占一块也不让这一帧丢掉。
            if let pool = adaptor.pixelBufferPool {
                var pooled: CVPixelBuffer?
                if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pooled) == kCVReturnSuccess,
                   let pooled {
                    return pooled
                }
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, report.width, report.height,
                                             kCVPixelFormatType_32BGRA,
                                             dstAttributes as CFDictionary, &buffer)
            guard status == kCVReturnSuccess else { return nil }
            return buffer
        }

        // ---- 5. 单循环拉取 ----
        // AVAssetReader 要求各轨按它给的顺序消费，分两个队列各自 copy 会互相
        // 阻塞甚至死锁；一个循环里轮流取才是对的。
        var videoDone = false
        var audioDone = (audioOutput == nil)
        var failed: String?
        var lastTick = Date()
        var lastPTS = CMTime.zero
        var frameDuration = CMTime(value: 1, timescale: 24)
        var lastSeenFrames = 0
        var lastProgress = Date()

        while true {
            if writer.status == .failed || writer.status == .cancelled { break }
            if videoDone && audioDone { break }
            if reader.status == .failed || reader.status == .cancelled { break }

            var didWork = false

            if !videoDone, videoInput.isReadyForMoreMediaData {
                // 每帧一个 autoreleasepool。CoreImage 的中间图、渲染用的
                // IOSurface 都要在下一帧开始前真正释放；靠 ARC 等它自己回收，
                // 一百多帧后就把 VideoToolbox 会话拖垮（-11819）。
                let outcome: FrameOutcome = autoreleasepool {
                    guard let sample = videoOutput.copyNextSampleBuffer() else { return .ended }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let dur = CMSampleBufferGetDuration(sample)
                    lastPTS = pts
                    if dur.isValid, dur > .zero { frameDuration = dur }

                    // 没开曲线也没开 LUT：原样串流，连 CoreImage 都不进
                    guard kernel != nil || lutFilter != nil else {
                        return videoInput.append(sample) ? .ok : .failed
                    }
                    guard let src = CMSampleBufferGetImageBuffer(sample),
                          let dst = makeDestination() else { return .failed }

                    render(src: src, to: dst, kernel: kernel, lutFilter: lutFilter,
                           context: ciContext, colorSpace: outputColorSpace, frameRect: frameRect)
                    return adaptor.append(dst, withPresentationTime: pts) ? .ok : .failed
                }

                switch outcome {
                case .ok:
                    didWork = true
                    report.frames += 1
                case .ended:
                    videoDone = true
                    videoInput.markAsFinished()
                    log("视频读完 · \(report.frames) 帧")
                case .failed:
                    failed = describe(writer, frame: report.frames, input: videoInput)
                    videoDone = true
                    videoInput.markAsFinished()
                }
            }

            if !audioDone, let audioInput, let audioOutput, audioInput.isReadyForMoreMediaData {
                if let sample = audioOutput.copyNextSampleBuffer() {
                    didWork = true
                    if audioInput.append(sample) {
                        report.audioBuffers += 1
                    }
                } else {
                    audioDone = true
                    audioInput.markAsFinished()
                    log("音频读完 · \(report.audioBuffers) 块")
                }
            }

            if !didWork {
                usleep(2_000)
            }

            if report.frames != lastSeenFrames {
                lastSeenFrames = report.frames
                lastProgress = Date()
            }
            if Date().timeIntervalSince(lastTick) > 10 {
                lastTick = Date()
                log("进度 \(report.frames) 帧 · \(Int(Date().timeIntervalSince(t0))) 秒 · 内存 \(Int(footprintMB()))MB")
                // 120 秒没有新帧就认定卡死：解码器可能挂在一个坏样本上，
                // 再等下去只会让用户以为 App 假死。
                if Date().timeIntervalSince(lastProgress) > 120 {
                    failed = "超过 120 秒没有新帧，已停止（解码器可能卡在这个 RAW 变体上）"
                    break
                }
            }
        }

        if let failed {
            writer.cancelWriting()
            reader.cancelReading()
            throw TranscodeError.writerFailed(failed)
        }
        if reader.status == .failed {
            let detail = reader.error?.localizedDescription ?? "未知"
            writer.cancelWriting()
            throw TranscodeError.readerFailed(detail)
        }
        guard report.frames > 0 else {
            writer.cancelWriting()
            throw TranscodeError.readerFailed("一帧都没解出来（解码器可能不支持这个 RAW 变体）")
        }

        writer.endSession(atSourceTime: lastPTS + frameDuration)
        // finishWriting 只有异步版本，用信号量等它落盘。
        // 这里已经在后台线程，阻塞没有副作用。
        let flushed = DispatchSemaphore(value: 0)
        writer.finishWriting { flushed.signal() }
        if flushed.wait(timeout: .now() + 30) == .timedOut {
            throw TranscodeError.writerFailed("封盘超时（30 秒）")
        }
        if writer.status == .failed {
            throw TranscodeError.writerFailed(writer.error?.localizedDescription ?? "封盘失败")
        }
        reader.cancelReading()
        log("已封盘 · \(outputURL.lastPathComponent)")

        // ---- 6. 注入色彩标记 ----
        do {
            // 烧过 LUT 的画面已是显示参考，不能再标 Log：
            // 标成 BT.709 三件套，并且不写 logs atom。
            let tag = report.appliedLUT == nil
                ? try MovTag.inject(outputURL)
                : try MovTag.inject(outputURL, primaries: 1, transfer: 1, matrix: 1, logID: "")
            report.tagDelta = tag.delta
            log("标记 colr \(tag.primaries)/\(tag.transfer)/\(tag.matrix) · logs · +\(tag.delta)B · 修正 \(tag.chunksShifted) 个 chunk")
        } catch {
            // 标记失败不影响画面，文件本身可用，只记录
            log("标记注入失败：\(error.localizedDescription)")
            report.tagDelta = 0
        }

        report.elapsed = Date().timeIntervalSince(t0)
        log("完成：\(report.summary)")
        return report
    }

    /// 把一帧解出的画面套上曲线，返回可交给编码器的样本。
    /// 不套曲线或渲染失败时原样返回，绝不因为增强失败而丢帧。
    /// 把一帧画到给定的 BGRA 缓冲上：解出的画面 → Log 2 曲线 → LUT。
    /// 两者串在一条 CoreImage 图上，最终只渲染一次。
    ///
    /// 渲染边界必须用固定的 frameRect。CIColorCube 这类逐点滤镜的
    /// `outputImage.extent` 是 `CGRect.infinite`，拿它当 bounds 会输出空帧，
    /// 编码器随即以 -11819 拒收。
    private static func render(src: CVImageBuffer,
                               to dst: CVPixelBuffer,
                               kernel: CIColorKernel?,
                               lutFilter: CIFilter?,
                               context: CIContext,
                               colorSpace: CGColorSpace,
                               frameRect: CGRect) {
        var image = CIImage(cvPixelBuffer: src)
        if let kernel, let curved = kernel.apply(extent: frameRect, arguments: [image]) {
            image = curved
        }
        if let lutFilter {
            lutFilter.setValue(image, forKey: kCIInputImageKey)
            if let filtered = lutFilter.outputImage {
                image = filtered.cropped(to: frameRect)
            }
        }
        context.render(image, to: dst, bounds: frameRect, colorSpace: colorSpace)
    }

    /// 当前进程的物理内存占用（MB）。
    /// 转码是几百帧的长跑，这个数字一路涨就说明有东西没释放，
    /// 比事后猜「是不是内存不够」直接得多。
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// 把编码器拒帧时的现场拼成一行人话：状态、错误域与码、底层错误、
    /// 以及这一帧的像素格式和尺寸。只有 domain 和 code 才能定位。
    private static func describe(_ writer: AVAssetWriter, frame: Int,
                                 input: AVAssetWriterInput) -> String {
        var parts = ["编码器拒帧（第 \(frame) 帧）"]
        parts.append("writer=\(writer.status.rawValue)")
        if let error = writer.error {
            let ns = error as NSError
            parts.append("\(ns.domain) \(ns.code)：\(ns.localizedDescription)")
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                parts.append("底层 \(underlying.domain) \(underlying.code)：\(underlying.localizedDescription)")
            }
        } else {
            parts.append("writer.error 为空")
        }
        parts.append("memory=\(Int(footprintMB()))MB")
        parts.append("input=\(input.isReadyForMoreMediaData ? "ready" : "busy")")
        return parts.joined(separator: " · ")
    }

    private static func fourCC(_ code: OSType) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                     UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return (String(bytes: bytes, encoding: .ascii) ?? "?").trimmingCharacters(in: .whitespaces)
    }
}
