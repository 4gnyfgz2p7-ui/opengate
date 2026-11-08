import Foundation
import AVFoundation
import CoreVideo
import CoreMedia

/// 把 ProRes RAW 转成目标档位，解码交给系统，颜色走已验证的管线。
///
/// ## 为什么要有这一层
///
/// 采集时相机给的是 `btp2` 私有打包，自研解包反复对不上（偶/奇位比
/// 实测 0.762，官方解码 1.106）。而这条链路完全不碰 btp2：
///
///   采集 → btp2 直通给 ProRes RAW 写入器（系统内部解包，已验证正确）
///   停止 → VideoToolbox 解回 bp16（每 sensel 一个 16-bit 值）
///        → 已验证的 demosaic / 矩阵 / 白平衡 / 滚降
///        → 编码成目标档位
///
/// 代价是离线：必须先落一个 ProRes RAW 临时文件。换来的是颜色由 Apple
/// 自己的解码器保证，不再依赖任何位序猜测。
final class RawTranscoder {

    struct Outcome {
        var frames = 0
        var dropped = 0
        var audioBuffers = 0
        var elapsed: TimeInterval = 0
        /// 首帧自检（尺寸、相位、值域），写进诊断
        var probe = ""
        /// 实际用到的白平衡增益
        var gains = ""
        var outputURL: URL?
    }

    enum TranscoderError: LocalizedError {
        case converterUnavailable
        case recorderFailed(String)
        case conversionFailed(String)
        case noFrames
        case cancelled

        var errorDescription: String? {
            switch self {
            case .converterUnavailable: return "Metal 转换器不可用"
            case .recorderFailed(let detail): return "写入器创建失败：\(detail)"
            case .conversionFailed(let detail): return "像素转换失败：\(detail)"
            case .noFrames: return "没有解出任何帧"
            case .cancelled: return "已取消"
            }
        }
    }

    /// 相位查表：phase = (y&1)<<1 | (x&1)，值 0=R 1=G 2=B
    static func colorMap(pattern: Int32) -> [Int] {
        switch pattern {
        case 1: return [2, 1, 1, 0]   // BGGR
        case 2: return [1, 0, 2, 1]   // GRBG
        case 3: return [1, 2, 0, 1]   // GBRG
        default: return [0, 1, 1, 2]  // RGGB
        }
    }

    /// 在 bp16 平面上按相位取分位，得到场景白平衡。
    ///
    /// 用 0.40 次幂做**部分校正**：全量灰度世界会把暖白墙和木家具的暖调
    /// 一起抹成中性，这正是 0.5.32 之后一直偏青的原因。0.40 让 20% 的失衡
    /// 只修 8%，暖调留得住，真偏色仍压得下去。
    static func measureGains(
        _ buffer: CVPixelBuffer,
        pattern: Int32
    ) -> (red: Float, green: Float, blue: Float) {
        guard CVPixelBufferGetPixelFormatType(buffer) == BayerConverter.planar16Format else {
            return (1, 1, 1)
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (1, 1, 1) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowStride = CVPixelBufferGetBytesPerRow(buffer) / 2
        let row = base.assumingMemoryBound(to: UInt16.self)

        var samples = [[UInt16]](repeating: [], count: 4)
        let stepX = max(1, width / 512)
        let stepY = max(1, height / 512)
        for y in stride(from: 0, to: height, by: stepY) {
            let line = row.advanced(by: y * rowStride)
            for x in stride(from: 0, to: width, by: stepX) {
                let phase = ((y & 1) << 1) | (x & 1)
                samples[phase].append(line[x])
            }
        }

        let colors = colorMap(pattern: pattern)
        var levels = [Double](repeating: 0, count: 3)
        var counts = [Int](repeating: 0, count: 3)
        for phase in 0..<4 {
            guard !samples[phase].isEmpty else { continue }
            let sorted = samples[phase].sorted()
            let value = Double(sorted[sorted.count * 6 / 10])
            levels[colors[phase]] += value
            counts[colors[phase]] += 1
        }
        for index in 0..<3 where counts[index] > 0 {
            levels[index] /= Double(counts[index])
        }

        let red = levels[0]
        let green = levels[1]
        let blue = levels[2]
        guard green > 1, red > 1, blue > 1 else { return (1, 1, 1) }
        let gainRed = Float(pow(green / red, 0.40))
        let gainBlue = Float(pow(green / blue, 0.40))
        // 0.35–2.8 之外不是白平衡能解释的，别硬拉
        return (
            min(2.8, max(0.35, gainRed)),
            1,
            min(2.8, max(0.35, gainBlue))
        )
    }

    /// 把源音频轨按时间交错地喂进写入器。
    ///
    /// 非交错写法（先全视频再全音频）在 ProRes 422 HQ 上会把上 GB 数据
    /// 堆在内存里，所以这里按 pts 追平：每写一帧视频，把时间戳不晚于它的
    /// 音频缓冲都放进去。
    private final class AudioFeeder {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private var pending: CMSampleBuffer?
        private(set) var appended = 0

        init(asset: AVAsset, track: AVAssetTrack) throws {
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else {
                throw TranscoderError.recorderFailed("音频轨无法读取")
            }
            reader.add(output)
            guard reader.startReading() else {
                throw TranscoderError.recorderFailed("音频读取未启动")
            }
        }

        /// 把 pts <= boundary 的音频都送出去
        func drain(until boundary: CMTime, into recorder: MovieRecorder) {
            while true {
                if pending == nil {
                    pending = output.copyNextSampleBuffer()
                    if pending == nil { return }
                }
                guard let buffer = pending else { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                if pts > boundary { return }
                recorder.appendAudio(buffer)
                appended += 1
                pending = nil
            }
        }

        func finish(into recorder: MovieRecorder) {
            while let buffer = output.copyNextSampleBuffer() {
                recorder.appendAudio(buffer)
                appended += 1
            }
            reader.cancelReading()
        }
    }

    // MARK: - 为什么不用 AVAssetExportSession
    //
    // 它确实是"一句话完成解码+编码+封装"，但两个致命限制：
    //
    // 1. **码率不可控**。preset 是系统定的，给不了本项目要求的
    //    20–90 Mbps 区间；同一个 preset 在不同机型上还会给不同结果。
    // 2. **分辨率可能被改写**。preset 隐含了缩放策略，4224×3024 这种
    //    非标准尺寸不保证原样保留。
    //
    // 而这两项恰恰是这台机器的核心指标。所以改用下面这条路：解码交给
    // 系统（AVAssetReader 指定输出格式，内部就是 VideoToolbox），
    // 编码交给系统（AVAssetWriter，参数由我们给），**像素一个不碰**。
    // 颜色仍然是系统 RAW 处理的结果，只是包装层由我们控制。

    /// 同步转码。调用方应放在后台队列，不要在采集队列上跑。
    static func run(
        rawURL: URL,
        outputURL: URL,
        tier: QualityTier,
        metadata: [AVMetadataItem],
        selfCalibrate: Bool = true,
        progress: ((Double) -> Void)? = nil
    ) throws -> Outcome {

        let started = Date()
        TranscodeLog.reset()
        TranscodeLog.write("开始转码 \(tier.identifier) src=\(rawURL.lastPathComponent)")

        guard let converter = BayerConverter() else {
            throw TranscoderError.converterUnavailable
        }

        // ---- 顺便做一次自校准 ----
        //
        // 这次录制已经把同一帧的 btp2 原始字节存下来了，而手头这个 RAW 文件
        // 里是同一次曝光的官方解码结果。两者对照就能把真实位序算出来——
        // 这是唯一绕开「判据永远选错」的路，因为判据奖励的是人为相关性，
        // 而这里比的是标准答案。
        //
        // 成立后写进 UserDefaults，下次录制直接走自研解包，恢复实时。
        var calibrationNote = ""
        // 离线处理任意文件时**不能**跑自校准：dump 切片来自上一次录制，
        // 与手上这个文件不同源。拿不同源的两帧做对照，算出来的是垃圾，
        // 还会覆盖掉已经成立的正确位序。
        if selfCalibrate, BayerDump.loadSlices().count >= 2 {
            if let solution = BayerSelfCalibration.calibrate(rawURL: rawURL) {
                BayerSelfCalibration.saved = solution
                calibrationNote = " 自校准 " + solution.summary
            } else {
                calibrationNote = " 自校准未成立"
            }
            BayerDump.clear()
        }

        let asset = AVURLAsset(url: rawURL)
        let videoTrack = asset.tracks(withMediaType: .video).first
        let audioTrack = asset.tracks(withMediaType: .audio).first
        guard videoTrack != nil else {
            TranscodeLog.write("源文件没有视频轨：\(rawURL.lastPathComponent)")
            throw TranscoderError.noFrames
        }

        // ---- 先探一帧，确定系统到底给什么 ----
        //
        // 必须放在建 writer 之前。MovieRecorder 的 init 里会 startWriting()，
        // 文件当场生成；如果之后解码才失败，就会留下一个 0 字节的 .mov，
        // 让人以为录成了。
        // 先要 bp16：只有它能进 Bayer 管线（每 sensel 一个 16-bit 值，
        // 相位由 attachment 声明）。
        var bayerProbe: ProResRAWReader.Probe?
        do {
            let result = try ProResRAWReader.decode(url: rawURL, limit: 1) { _, _, _ in true }
            if result.probe?.pixelFormat == "bp16" {
                bayerProbe = result.probe
                TranscodeLog.write("解码：bp16 可用 \(result.probe?.summary ?? "")")
            } else {
                TranscodeLog.write("解码：请求 bp16 被降级为 \(result.probe?.pixelFormat ?? "—")")
            }
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            TranscodeLog.write("解码：bp16 不可用（\(reason)）")
        }

        // 拿不到 Bayer 就直通：系统内部已经走完 RAW 处理，输出是成品视频，
        // 颜色由 Apple 的管线决定，我们只换编码，不碰像素。
        var yuvSource: (format: OSType, name: String, probe: ProResRAWReader.Probe)?
        if bayerProbe == nil {
            guard let detected = ProResRAWReader.detectYUVFormat(url: rawURL) else {
                TranscodeLog.write("系统没有给出任何可用解码输出")
                throw TranscoderError.conversionFailed("系统解不出任何格式，文件可能损坏")
            }
            yuvSource = detected
        }

        guard let probeFrame = bayerProbe ?? yuvSource?.probe else {
            TranscodeLog.write("探测未返回帧信息")
            throw TranscoderError.noFrames
        }
        TranscodeLog.write("解码探测成功 \(probeFrame.summary)")

        let width = probeFrame.width
        let height = probeFrame.height
        guard width > 1, height > 1 else {
            TranscodeLog.write("探测尺寸异常 \(width)×\(height)")
            throw TranscoderError.noFrames
        }

        let totalSeconds = CMTimeGetSeconds(asset.duration)
        let fps = max(1.0, Double(videoTrack?.nominalFrameRate ?? 24))
        let expected = totalSeconds.isFinite ? max(1, Int(totalSeconds * fps)) : 1

        var recorder: MovieRecorder
        do {
            recorder = try MovieRecorder(
                outputURL: outputURL,
                tier: tier,
                width: width,
                height: height,
                metadata: metadata,
                withAudio: audioTrack != nil,
                // 源 RAW 的像素由系统解码器按 Apple Log 2 输出，转出来的
                // HEVC 必须带上同样的标记，否则 NLE 会拿 SDR 曲线去解释
                // 一段 Log 数据，画面直接发白。
                appleLog2: true,
                // 沿用源的显示矩阵：竖拍时录下来的是横置画面 + 旋转标记，
                // 转码不带上它，成片方向就反了。
                videoTransform: videoTrack?.preferredTransform ?? .identity,
                realTime: false
            )
        } catch {
            TranscodeLog.write("写入器创建失败：\(error.localizedDescription)")
            throw TranscoderError.recorderFailed(error.localizedDescription)
        }

        var feeder: AudioFeeder?
        if let audioTrack {
            feeder = try? AudioFeeder(asset: asset, track: audioTrack)
        }

        var outcome = Outcome()
        let count: Int
        let probe: ProResRAWReader.Probe?

        if bayerProbe != nil {
            // ---- 有 Bayer：走已验证的色彩管线 ----
            var parameters = BayerConverter.Parameters()
            parameters.planar16 = true
            parameters.blackLevel = 256       // bp16 与 ffmpeg 同构：黑 0x1000>>4
            parameters.whiteLevel = 4095

            let result = try ProResRAWReader.decode(url: rawURL, format: nil) { buffer, pts, index in
                if index == 1 {
                    // 相位：优先用系统在 attachment 里声明的
                    let declared = ProResRAWReader.declaredPattern(of: buffer)
                    parameters.pattern = declared ?? 0
                    let gains = measureGains(buffer, pattern: parameters.pattern)
                    parameters.redGain = gains.red
                    parameters.greenGain = gains.green
                    parameters.blueGain = gains.blue
                    outcome.gains = String(
                        format: "R=%.3f B=%.3f pat=%d%@",
                        gains.red, gains.blue, parameters.pattern,
                        declared == nil ? "（未声明，按 RGGB）" : ""
                    )
                }

                guard let bgra = converter.convert(buffer, parameters: parameters) else {
                    throw TranscoderError.conversionFailed(
                        converter.lastFailureStage ?? "未知"
                    )
                }
                if !recorder.appendImageBuffer(bgra, presentationTimeStamp: pts) {
                    outcome.dropped += 1
                }
                feeder?.drain(until: pts, into: recorder)

                if index % 12 == 0 {
                    progress?(min(0.99, Double(index) / Double(max(expected, 1))))
                }
                return true
            }
            count = result.count
            probe = result.probe
        } else {
            // ---- 没有 Bayer：直通，像素一个都不碰 ----
            //
            // 系统给什么就编什么。颜色是 Apple 自己的 RAW 处理结果，
            // 我们在这里做任何"再校正"都只会把它弄坏。
            guard let yuvSource else {
                throw TranscoderError.conversionFailed("没有可用的解码源")
            }
            outcome.gains = "直通 \(yuvSource.name)（系统 RAW 管线）"
            TranscodeLog.write("直通转码：\(yuvSource.name) \(probeFrame.width)×\(probeFrame.height)")

            let result = try ProResRAWReader.decodeYUV(url: rawURL, format: yuvSource.format) { buffer, pts, index in
                if !recorder.appendImageBuffer(buffer, presentationTimeStamp: pts) {
                    outcome.dropped += 1
                }
                feeder?.drain(until: pts, into: recorder)

                if index % 12 == 0 {
                    progress?(min(0.99, Double(index) / Double(max(expected, 1))))
                }
                return true
            }
            count = result.count
            probe = result.probe
        }

        TranscodeLog.write("全量解出 \(count) 帧，丢弃 \(outcome.dropped) 帧，增益 \(outcome.gains)")
        guard count > 0 else {
            TranscodeLog.write("全量解码得到 0 帧")
            throw TranscoderError.noFrames
        }
        feeder?.finish(into: recorder)

        // finish 前的等待交给信号量：MovieRecorder.finish 是 async 的
        let semaphore = DispatchSemaphore(value: 0)
        var finishedClean = false
        Task {
            let result = await recorder.finish()
            finishedClean = result.finishedCleanly
            semaphore.signal()
        }
        semaphore.wait()

        outcome.frames = count
        outcome.elapsed = Date().timeIntervalSince(started)
        outcome.probe = (probe?.summary ?? "—") + calibrationNote
        outcome.audioBuffers = feeder?.appended ?? 0
        outcome.outputURL = finishedClean ? outputURL : nil
        if !finishedClean {
            throw TranscoderError.recorderFailed(
                recorder.appendFailureDescription ?? "写入器未正常结束"
            )
        }
        TranscodeLog.write("转码完成 \(outcome.frames) 帧 / \(String(format: "%.1f", outcome.elapsed))s → \(outputURL.lastPathComponent) \(MovieRecorder.fileSize(at: outputURL)) 字节")
        progress?(1.0)
        return outcome
    }

    /// 转码需要多少临时空间：按 ProRes RAW 的实测码率估。
    /// 4224×3024@24 的 ProRes RAW 实测约 443 Mb/s，取 460 留余量。
    static func estimatedRawBytes(seconds: Double) -> Int64 {
        Int64(max(0, seconds) * 460_000_000 / 8)
    }
}
