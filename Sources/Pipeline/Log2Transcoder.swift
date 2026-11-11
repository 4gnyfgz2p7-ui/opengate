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
    /// 白点目标。1.0 的 Log 值（1200% 白）在 LUT 里对应 1662 nits，
    /// 而 100% 白只到 143 nits。素材里没有 1200% 高光时，LUT 的上半段
    /// 永远走不到，画面就被顶在 143 nits 上。这里按目标白点反推增益，
    /// 让 100% 白落在指定的亮度上，LUT 的可用段随之被打开。
    private static let curveKernelSource = """
    kernel vec4 log2curve(__sample s) {
        // 不做逐通道截断。之前 clamp(0,1) 让 R/G 先撞顶、B 不撞，
        // 高光就变成一块饱和黄。这里只挡负数，上限交给 LUT 的域。
        vec3 x = max(s.rgb, 0.0) * %GAIN%;
        vec3 logPart = %GAMMA% * log2(x + %BETA%) + %DELTA%;
        vec3 diff = x - (%R0%);
        vec3 toe = %C% * diff * diff;
        vec3 v = mix(toe, logPart, step(%RT%, x));
        v = mix(vec3(0.0), v, step(%R0%, x));

        // 高光去饱和：越接近白点越向中性收，模拟相机的肩部。
        // 判定用增益前的线性值，避免增益把整幅都算成高光。
        float L0 = max(max(s.r, s.g), s.b);
        float t = clamp((L0 - %KNEE%) / %WIDTH%, 0.0, 1.0);
        float k = t * t * (3.0 - 2.0 * t) * %DESAT%;
        float Lv = max(max(v.r, v.g), v.b);
        v = mix(v, vec3(Lv), k);

        return vec4(clamp(v, 0.0, 1.0), s.a);
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
                // outputSettings 都是 nil，样本从 reader 原样搬到 writer。
                log("音频原样搬运（不解码 · 不重采样 · 不改位深）")
            }
        }

        guard reader.startReading() else {
            throw TranscodeError.readerFailed(reader.error?.localizedDescription ?? "无法开始读取")
        }

        // ---- 2.5 LUT：先建滤镜 ----
        // 编码器的 colorProperties 要按"有没有 LUT"切换，所以必须提前建。
        // LUT 的输入是 Log 值，输出是 PQ 编码的 P3 值，编码器得按 P3 + PQ 写。
        let lutFilter: CIFilter?
        if let lut {
            if let made = lut.makeFilter() {
                lutFilter = made
                report.appliedLUT = "\(lut.title) \(lut.size)³"
                log("LUT 就绪：\(lut.title) · \(lut.size)³")
            } else {
                lutFilter = nil
                log("LUT 滤镜创建失败，本片按 Log 直出")
            }
        } else {
            lutFilter = nil
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
        // 无 LUT：BT.2020 原色 + BT.709 传递函数（Log 素材，标记按 9/2/9 注入）
        // 有 LUT：P3-D65 + PQ（LUT 输出就是 PQ 值，标记按 12/16/9 注入）
        let colorProperties: [String: Any]
        if lutFilter != nil {
            colorProperties = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        } else {
            colorProperties = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
        log("编码色彩：\(lutFilter != nil ? "P3-D65 + PQ" : "BT.2020 + BT.709")")

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
            AVVideoColorPropertiesKey: colorProperties,
            AVVideoCompressionPropertiesKey: compression,
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else {
            throw TranscodeError.writerFailed("写入器拒绝 HEVC 参数")
        }
        writer.add(videoInput)

        // 自建 BGRA 缓冲池：格式写死，不依赖编码器偏好。
        //
        // 上一版直接用 adaptor.pixelBufferPool，成片色度全部落在 0.500
        // （中性灰），说明那块缓冲不是可控的三通道格式 —— CI 渲染进去的
        // 颜色在写帧时被抹掉了。这里显式指定 32BGRA，CI 写进去就是确定的
        // R/G/B。每帧 CVPixelBufferCreate 同样不行：4224×3024 每块 51 MB，
        // 113 帧后把 VideoToolbox 拖垮（-11819）。
        var poolOut: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
            [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: report.width,
                kCVPixelBufferHeightKey as String: report.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ] as CFDictionary,
            &poolOut
        )
        if poolStatus != kCVReturnSuccess || poolOut == nil {
            log("缓冲池创建失败，退回逐帧分配")
        }

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
        // 渲染色彩空间必须与成片要写的色彩空间一致：
        //   开 LUT → 输出是 Display P3 的 PQ 值 → 渲染到 P3
        //   关 LUT → 输出是 Apple Wide Gamut（按 BT.2020 近似）的 Log 值 → 渲染到 BT.2020
        //
        // 之前两条路径都写 sRGB。数值在窄色域里被解释一次，编码器再按宽色域
        // 写标记，播放器按宽色域解码，饱和度就被放大 —— 高对比边缘本来就带
        // 镜头色差，被这一层放大后直接推成 B=0 的纯色块。
        let outputColorSpace: CGColorSpace = {
            if lutFilter != nil {
                return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
            }
            return CGColorSpace(name: CGColorSpace.itur_2020) ?? CGColorSpaceCreateDeviceRGB()
        }()
        log("渲染色彩：\(lutFilter != nil ? "Display P3" : "BT.2020")")
        var kernel: CIColorKernel?
        // 100% 白在 LUT 里落在 142.6 nits。按目标白点反推线性增益，
        // 让 100% 白正好落在用户选的亮度上。上限 12 倍是为了不让
        // 严重欠曝的素材被拉成噪点一片。
        //
        // 只有走 LUT（PQ 输出）时才加增益：关 LUT 的成片是 Apple Log 2
        // 素材，Log 值必须保持标准，加了增益就是谎报。
        // 完全按 LUT 映射：不再对输入做任何整体提亮。
        //
        // 之前按白点目标反推增益（最高 12 倍），暗部被一起抬起来，
        // 观感就是「暗部偏亮、对比度不够」。LUT 自己已经把 Log 映射到
        // 0–2000 nits，多余的那层增益只会把黑位推离 0。
        let gain: Float = 1.0
        let knee: Float = 0.75
        let kneeWidth: Float = 0.25
        // 过曝往白走，这是相机的肩部行为。逐通道硬截会让 R/G 先撞顶、
        // B 落在后面，于是溢出的区域变成饱和黄 —— 那不是场景的颜色。
        let desat: Float = lutFilter == nil ? 0.0 : 0.95
        if applyCurve {
            let source = curveKernelSource
                .replacingOccurrences(of: "%GAMMA%", with: "\(gamma)f")
                .replacingOccurrences(of: "%BETA%", with: "\(beta)f")
                .replacingOccurrences(of: "%DELTA%", with: "\(delta)f")
                .replacingOccurrences(of: "%C%", with: "\(c)f")
                .replacingOccurrences(of: "%R0%", with: "\(r0)f")
                .replacingOccurrences(of: "%RT%", with: "\(rt)f")
                .replacingOccurrences(of: "%GAIN%", with: String(format: "%.5ff", gain))
                .replacingOccurrences(of: "%KNEE%", with: String(format: "%.4ff", knee))
                .replacingOccurrences(of: "%WIDTH%", with: String(format: "%.4ff", kneeWidth))
                .replacingOccurrences(of: "%DESAT%", with: String(format: "%.4ff", desat))
            kernel = CIColorKernel(source: source)
            if kernel == nil {
                log("曲线内核编译失败，本片按直通输出")
            } else {
                log("曲线内核就绪 · LUT 1:1 映射 · 去饱和 \(Int(knee * 100))% 起")
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

        // 池是否可用。首帧若渲染成灰度，说明这块池缓冲不接受三通道写入，
        // 立刻永久切回逐帧分配 —— 宁可变慢，也不能再出一版灰片。
        var usePool = (poolOut != nil)

        func makeDestination() -> CVPixelBuffer? {
            // 先用自建 BGRA 池；池暂时空（编码器还没释放）时退回临时分配，
            // 宁可多占一块也不让这一帧丢掉。
            if usePool, let pool = poolOut {
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

                    // 像素自检：首帧与每 48 帧抽一次中心区。三通道相等就是
                    // 灰度，说明颜色在渲染这一步就没了，不必等看成片才发现。
                    if report.frames == 0 || report.frames % 48 == 0 {
                        log("像素自检 #\(report.frames) · \(fourCC(CVPixelBufferGetPixelFormatType(dst))) · \(sampleRGB(dst))")
                    }

                    // 首帧灰度就当场纠正：弃用池缓冲，改用逐帧分配重渲染这一帧。
                    // 这一层是保险 —— 万一池的行为与预期不符，也不会把整条片子
                    // 渲染成灰度。
                    var frameBuffer = dst
                    if report.frames == 0, spreadOf(dst) < 0.005 {
                        usePool = false
                        log("首帧渲染成灰度，已弃用池缓冲，改逐帧分配重渲染")
                        if let fresh = makeDestination() {
                            render(src: src, to: fresh, kernel: kernel, lutFilter: lutFilter,
                                   context: ciContext, colorSpace: outputColorSpace, frameRect: frameRect)
                            frameBuffer = fresh
                            log("重渲染自检 · \(sampleRGB(fresh))")
                        }
                    }

                    // 写帧走 0.5.51 实拍验证过的那条路：重建 sample buffer。
                    // adaptor.append 直接塞 CVPixelBuffer 实测会把色度抹成
                    // 中性值（U/V 全部 ≈0.500），画面只剩亮度。
                    guard let rebuilt = rebuildSample(from: frameBuffer, like: sample) else { return .failed }
                    return videoInput.append(rebuilt) ? .ok : .failed
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
            // 两条路径的标记分开：
            // 关 LUT → colr 9/2/9 + logs(apple-wide-gamut)，是 Log 素材
            // 开 LUT → colr 12/16/9（P3-D65 + PQ），不写 logs，不是 Log 了
            let tag = report.appliedLUT == nil
                ? try MovTag.inject(outputURL)
                : try MovTag.inject(outputURL, primaries: 12, transfer: 16, matrix: 9, logID: "")
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
    /// 用渲染好的像素缓冲重建 sample buffer，时间戳沿用源样本。
    /// 这是 0.5.51 实拍验证过颜色正确的写入路径。
    private static func rebuildSample(from buffer: CVPixelBuffer,
                                      like source: CMSampleBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(source),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source),
            decodeTimeStamp: .invalid
        )
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &out
        )
        guard status == noErr, let out else { return nil }
        return out
    }

    /// 抽中心区 64×64，报告三通道均值与色差。
    /// 色差是 R/G/B 两两差的最大值：接近 0 就是灰度图。
    private static func sampleRGB(_ buffer: CVPixelBuffer) -> String {
        let stats = rgbStats(buffer)
        guard stats.count > 0 else { return stats.text.isEmpty ? "无采样" : stats.text }
        return String(format: "R %.3f G %.3f B %.3f · 色差 %.3f · 亮度跨度 %.3f",
                      stats.sumR / stats.count, stats.sumG / stats.count,
                      stats.sumB / stats.count, stats.spread, stats.lumaRange)
    }

    /// 中心区的最大通道差：接近 0 就是灰度。
    private static func spreadOf(_ buffer: CVPixelBuffer) -> Double {
        rgbStats(buffer).spread
    }

    private struct RGBStats {
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, count = 0.0, spread = 0.0
        var minLuma = 1.0, maxLuma = 0.0
        var text = ""
        /// 中心区的亮度跨度。整幅被压缩时这个数字会明显偏小。
        var lumaRange: Double { max(0, maxLuma - minLuma) }
    }

    private static func rgbStats(_ buffer: CVPixelBuffer) -> RGBStats {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var stats = RGBStats()
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            stats.text = "无法读取"
            return stats
        }

        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let px = base.assumingMemoryBound(to: UInt8.self)
        let step = max(1, min(w, h) / 64)

        var y = h / 4
        while y < h * 3 / 4 {
            var x = w / 4
            while x < w * 3 / 4 {
                let p = y * bpr + x * 4
                let b = Double(px[p]) / 255
                let g = Double(px[p + 1]) / 255
                let r = Double(px[p + 2]) / 255
                stats.sumR += r; stats.sumG += g; stats.sumB += b; stats.count += 1
                stats.spread = max(stats.spread, max(abs(r - g), max(abs(g - b), abs(r - b))))
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                stats.minLuma = min(stats.minLuma, luma)
                stats.maxLuma = max(stats.maxLuma, luma)
                x += step
            }
            y += step
        }
        return stats
    }

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

    /// PQ 码值（0–1）换算成绝对亮度 nits。SMPTE ST 2084。
    private static func pqToNits(_ n: Float) -> Double {
        let m1 = 0.1593017578125
        let m2 = 78.84375
        let c1 = 0.8359375
        let c2 = 18.8515625
        let c3 = 18.6875
        let p = pow(Double(max(min(n, 1), 0)), 1.0 / m2)
        let num = max(p - c1, 0)
        let den = c2 - c3 * p
        guard den > 1e-9 else { return 10000 }
        return 10000 * pow(num / den, 1.0 / m1)
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
