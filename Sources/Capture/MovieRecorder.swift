import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// 负责把采集到的帧写成 .mov 文件。
///
/// 两个容易做错的硬点：
/// 1. **元数据必须早于 startWriting()**：moov 头在文件开头成文，
///    之后再改 `writer.metadata` 不会落盘，且不报错。
/// 2. **时间基必须是 24 的整数倍**：不能用 `CMSampleBuffer` 自带的设备时钟 PTS
///    直接写，否则容器里会出现 23.976 一类的时基与累积误差。
final class MovieRecorder {

    // MARK: - 结果

    struct Outcome {
        let url: URL
        let tier: QualityTier
        let duration: TimeInterval
        let fileSize: Int64
        let writtenVideoFrames: Int64
        let droppedVideoFrames: Int64
        let writtenAudioBuffers: Int64
        let discardedAudioBuffers: Int64
        let effectiveFrameRate: Double
        let averageWriteRateMBps: Double
        let finishedCleanly: Bool
        let note: String
    }

    enum RecorderError: LocalizedError {
        case writerCreationFailed(String)
        case videoInputRejected(String)
        case audioInputRejected
        case startWritingFailed(String)
        case insufficientSpace(requiredMB: Int64, availableMB: Int64)

        var errorDescription: String? {
            switch self {
            case .writerCreationFailed(let reason):
                return "无法创建写入器：\(reason)"
            case .videoInputRejected(let detail):
                return "写入器不接受该档的视频参数：\(detail)"
            case .audioInputRejected:
                return "写入器不接受 LPCM 音轨"
            case .startWritingFailed(let reason):
                return "启动写入失败：\(reason)"
            case .insufficientSpace(let required, let available):
                return "存储空间不足：预计需要 \(required) MB，可用 \(available) MB"
            }
        }
    }

    // MARK: - 属性

    private(set) var outputURL: URL
    private let tier: QualityTier
    private let width: Int
    private let height: Int

    private var writer: AVAssetWriter
    private var videoInput: AVAssetWriterInput
    /// ProRes RAW 的容器级元数据（相机标定、白平衡增益等），由系统给出。
    /// 必须与自定义元数据合并后一次写入，后写的会覆盖先写的。
    private var rawMovieMetadata: [AVMetadataItem] = []
    private var audioInput: AVAssetWriterInput?
    /// 直接追加 CVPixelBuffer 的标准通道。
    /// 早先是自己拼 CMSampleBuffer 再 append，格式描述与时间戳都由我们构造，
    /// 出问题时无从判断是编码器拒收还是构造错了；adaptor 是苹果的标准路径。
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    private let stateLock = NSLock()
    private var anchorPTS: CMTime?
    private var lastVideoFrameIndex: Int64 = -1
    private var writtenVideoFrames: Int64 = 0
    private var droppedVideoFrames: Int64 = 0
    private var writtenAudioBuffers: Int64 = 0
    private var discardedAudioBuffers: Int64 = 0
    private var lastPTS: CMTime = .zero
    private var finished = false
    private var startWallClock = Date()
    /// 第一条被编码器拒收的帧的原因。空文件问题全靠这条线索定位。
    private var firstAppendFailure: String?
    /// 实际生效的编码设置层级：0 为完整设置，数字越大表示降级越多
    private(set) var settingsLevel = 0

    /// ProRes 需要 4:2:2 输入，HEVC 只要 4:2:0
    var wantsChroma422: Bool { tier.isProRes }

    /// 原始 Bayer 直录：画面不做 demosaic，字节原样进容器
    var isRawBayer: Bool { tier.isRawBayer }

    var appendFailureDescription: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return firstAppendFailure
    }

    /// 录制中可轮询的失败状态。
    ///
    /// 「文件坏了但 App 不报错」反复出现，根源就在这里：失败只被写进收尾时
    /// 的 `Outcome.note`，而收尾界面从来不看那条 note。把状态暴露成属性，
    /// 让计时器每秒查一次，就能在故障发生的那一刻停下并把原因弹到画面上，
    /// 而不是等到录完才发现文件打不开。
    var liveFailure: String? {
        guard writer.status == .failed else { return nil }
        return writer.error?.localizedDescription ?? "写入器失败"
    }

    /// 磁盘上此刻的真实字节数。
    /// 录制进度不能再按「码率 × 秒数」估算：估算值在写入失败时照样往上走，
    /// 界面上显示几百 MB、实际文件只有几 MB，正是「显示录了但文件是 0KB」的来源。
    var currentFileSize: Int64 { Self.fileSize(at: outputURL) }

    var writerStatusText: String {
        switch writer.status {
        case .unknown: return "unknown"
        case .writing: return "writing"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return "?\(writer.status.rawValue)"
        }
    }

    private static let frameTimescale: CMTimeScale = 24

    // MARK: - 构造

    init(
        outputURL: URL,
        tier: QualityTier,
        width: Int,
        height: Int,
        metadata: [AVMetadataItem],
        withAudio: Bool,
        appleLog2: Bool,
        videoTransform: CGAffineTransform = .identity,
        rawSettings: [String: Any]? = nil,
        rawMetadata: [AVMetadataItem]? = nil,
        realTime: Bool = true
    ) throws {

        self.outputURL = outputURL
        self.tier = tier
        self.width = width
        self.height = height

        // 先删掉同名残留，AVAssetWriter 不会覆盖已存在文件
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: tier.fileType)
        } catch {
            throw RecorderError.writerCreationFailed(error.localizedDescription)
        }

        // ---- 视频输入 ----
        //
        // 逐级降级：首选设置被拒就换成更宽松的一套，直到能录。
        // 早先只试一套，一旦被拒整档都录不了；而降级后至少能出片，
        // 并把实际生效的层级写进结果，便于回头查是哪一侧不支持。
        var accepted: AVAssetWriterInput?
        var acceptedLevel = -1

        // ProRes RAW 不接受自拼参数，也不存在"降级到更宽松的一套"——
        // 系统给的 recommendedVideoSettings 就是唯一答案，换任何一套都会被拒。
        // 拿不到就直接失败，让调用方把原因报出来。
        if tier.isRawBayer {
            guard let settings = rawSettings else {
                throw RecorderError.videoInputRejected("系统没有给出 ProRes RAW 的编码设置")
            }
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
                throw RecorderError.videoInputRejected("canApply 拒绝系统给出的 RAW 设置")
            }
            let candidate = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            candidate.expectsMediaDataInRealTime = realTime
            candidate.transform = videoTransform
            guard writer.canAdd(candidate) else {
                throw RecorderError.videoInputRejected("canAdd 拒绝 RAW 视频轨，输出文件类型 \(tier.fileType.rawValue)")
            }
            writer.add(candidate)
            accepted = candidate
            acceptedLevel = 0
            // RAW 容器里必须写相机标定、白平衡增益等元数据，解码器靠它还原色彩。
            // 这一步来自 Apple 文档要求，缺了文件能写但打不开。
            // 这里只暂存，等 start() 里与自定义元数据合并后一次写入。
            rawMovieMetadata = rawMetadata ?? []
        }

        if accepted == nil {
            for level in 0...3 {
                guard let settings = VideoSettingsBuilder.fallbackSettings(
                    tier: tier,
                    width: width,
                    height: height,
                    appleLog2: appleLog2,
                    level: level
                ) else { continue }

                guard writer.canApply(outputSettings: settings, forMediaType: .video) else { continue }

                let candidate = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                candidate.expectsMediaDataInRealTime = realTime
                // 拍摄方向只作为显示矩阵写入容器，**不旋转像素**。
                // 4224×3024 是传感器原生画幅，旋转像素要么改变实际存储尺寸，
                // 要么引入一次全画幅重采样，与「全幅不裁切、不改几何」冲突。
                candidate.transform = videoTransform

                if writer.canAdd(candidate) {
                    writer.add(candidate)
                    accepted = candidate
                    acceptedLevel = level
                    break
                }
            }

        }
        guard let vInput = accepted else {
            throw RecorderError.videoInputRejected("四套参数全部被拒，\(width)×\(height) \(tier.displayName)")
        }
        videoInput = vInput
        settingsLevel = acceptedLevel

        // 所有档位都保持中立：不声明源格式。
        //
        // 早先 RAW 档在这里声明了 btp2 + 4224×3024，理由是"不声明会被当普通
        // 视频缓冲拒收"——那是猜的。实际上声明非 nil 会让 adaptor 去建一个
        // 该格式的 pixel buffer pool，而 `96VersatileBayerPacked12` 是相机
        // 专用格式，CoreVideo 未必能自行创建；池建不出来，append 就一路失败。
        //
        // nil 的含义是"接受任何符合 writer input 要求的 buffer，不做转换"，
        // 正是直通需要的。相机给的 buffer 本身就是 btp2，尺寸也对得上。
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: nil
        )

        // ---- 音频输入 ----
        if withAudio {
            let aSettings = AudioSettings.writerSettings
            if writer.canApply(outputSettings: aSettings, forMediaType: .audio) {
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
                aInput.expectsMediaDataInRealTime = realTime
                if writer.canAdd(aInput) {
                    writer.add(aInput)
                    audioInput = aInput
                }
            }
        }

        // ---- 元数据：必须在 startWriting 之前 ----
        // 顺序不能反：这一行会整体替换，先写 rawMovieMetadata 会被冲掉。
        writer.metadata = rawMovieMetadata + metadata

        // ---- 启动 ----
        guard writer.startWriting() else {
            let reason = writer.error?.localizedDescription ?? "未知原因"
            throw RecorderError.startWritingFailed(reason)
        }

        // 视频时间轴从 0 开始，音频按相对第一帧的偏移对齐
        writer.startSession(atSourceTime: .zero)
        startWallClock = Date()
    }

    // MARK: - 写入

    /// 系统 ISP 通路：从 sample buffer 里取图像缓冲，再走统一入口
    @discardableResult
    func appendVideo(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            stateLock.lock()
            if firstAppendFailure == nil { firstAppendFailure = "sample buffer 不含画面" }
            stateLock.unlock()
            return false
        }
        return appendImageBuffer(
            imageBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }

    /// 视频帧。时间戳按真实经过时间折算到 24 时基，既保证时基纯净，
    /// 又不累积偏差。
    @discardableResult
    func appendImageBuffer(_ imageBuffer: CVPixelBuffer, presentationTimeStamp realPTS: CMTime) -> Bool {
        stateLock.lock()
        let alreadyFinished = finished
        stateLock.unlock()
        guard !alreadyFinished, writer.status == .writing else {
            // 写入器自身失败（磁盘/编码器初始化）也要留现场，
            // 否则界面上只剩一句笼统的"未接受该画面格式"。
            if writer.status == .failed {
                stateLock.lock()
                if firstAppendFailure == nil {
                    firstAppendFailure = writer.error?.localizedDescription ?? "写入器状态失败"
                }
                stateLock.unlock()
            }
            return false
        }

        guard videoInput.isReadyForMoreMediaData else {
            stateLock.lock(); droppedVideoFrames += 1; stateLock.unlock()
            return false
        }

        stateLock.lock()
        if anchorPTS == nil {
            anchorPTS = realPTS
        }
        let anchor = anchorPTS ?? realPTS
        stateLock.unlock()

        let elapsed = CMTimeSubtract(realPTS, anchor)
        var index = Int64((CMTimeGetSeconds(elapsed) * Double(Self.frameTimescale)).rounded())
        if index < 0 { index = 0 }

        stateLock.lock()
        // 按 24 Hz 网格抽取：落在已写格点上的帧直接丢弃。
        //
        // 不能像早先那样"撞格就 +1 强行推进"——设备实际可能以 60 fps 供帧
        // （会话启动会把 activeVideoMinFrameDuration 改回默认），
        // 强行推进等于把 1 秒素材写成 2.5 秒慢动作，音轨也会整段错位。
        let isDuplicateGrid = index <= lastVideoFrameIndex
        if isDuplicateGrid {
            droppedVideoFrames += 1
        } else {
            lastVideoFrameIndex = index
        }
        stateLock.unlock()

        if isDuplicateGrid { return false }

        let targetPTS = CMTime(value: index, timescale: Self.frameTimescale)

        guard let adaptor = adaptor else {
            stateLock.lock()
            if firstAppendFailure == nil { firstAppendFailure = "视频适配器未建立" }
            stateLock.unlock()
            return false
        }

        if adaptor.append(imageBuffer, withPresentationTime: targetPTS) {
            stateLock.lock()
            writtenVideoFrames += 1
            lastPTS = targetPTS
            stateLock.unlock()
            return true
        } else {
            stateLock.lock()
            droppedVideoFrames += 1
            let firstFailure = firstAppendFailure == nil
            if firstFailure {
                // 只在第一次记，避免每条帧都拼字符串。
                // 这条文本是"文件 0 字节"唯一的现场证据，必须留给界面看。
                //
                // 带上源 buffer 的实际格式：RAW 档失败最常见的原因就是
                // adaptor 拿到的格式和 writer input 期望的不一致，
                // 只写"append 返回 false"等于什么都没说。
                let fmt = CVPixelBufferGetPixelFormatType(imageBuffer)
                let code = String(bytes: [
                    UInt8((fmt >> 24) & 0xFF), UInt8((fmt >> 16) & 0xFF),
                    UInt8((fmt >> 8) & 0xFF), UInt8(fmt & 0xFF),
                ], encoding: .ascii) ?? "????"
                let size = "\(CVPixelBufferGetWidth(imageBuffer))×\(CVPixelBufferGetHeight(imageBuffer))"
                let writerReason = writer.error?.localizedDescription
                    ?? "writer 状态 \(writer.status.rawValue)"
                firstAppendFailure = "帧被拒（源 \(code) \(size)）：\(writerReason)"
            }
            stateLock.unlock()
            return false
        }
    }

    /// 音频块。保持 48000 时基，只减去锚点偏移。
    /// 若某块早于锚点（第一帧音频常早于第一帧视频），直接丢弃并计数，
    /// 否则 AVAssetWriter 会以「sample before session start」拒绝整条轨道。
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let input = audioInput else { return }

        stateLock.lock()
        let alreadyFinished = finished
        let anchor = anchorPTS
        stateLock.unlock()

        guard !alreadyFinished, writer.status == .writing, let anchor = anchor else {
            stateLock.lock(); discardedAudioBuffers += 1; stateLock.unlock()
            return
        }

        guard input.isReadyForMoreMediaData else {
            stateLock.lock(); discardedAudioBuffers += 1; stateLock.unlock()
            return
        }

        let realPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let relative = CMTimeSubtract(realPTS, anchor)

        if CMTimeCompare(relative, .zero) < 0 {
            stateLock.lock(); discardedAudioBuffers += 1; stateLock.unlock()
            return
        }

        guard let shifted = Self.retimed(
            sampleBuffer,
            presentationTimeStamp: relative,
            duration: CMSampleBufferGetDuration(sampleBuffer)
        ) else {
            stateLock.lock(); discardedAudioBuffers += 1; stateLock.unlock()
            return
        }

        if input.append(shifted) {
            stateLock.lock(); writtenAudioBuffers += 1; stateLock.unlock()
        } else {
            stateLock.lock(); discardedAudioBuffers += 1; stateLock.unlock()
        }
    }

    // MARK: - 实时读数

    /// 录制过程中读取已写帧数，供界面显示
    var liveWrittenFrames: Int64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return writtenVideoFrames
    }

    /// 录制过程中读取丢帧数
    var liveDroppedFrames: Int64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return droppedVideoFrames
    }

    // MARK: - 收尾

    /// 结束写入并返回统计。调用后该实例不可复用。
    func finish() async -> Outcome {
        stateLock.lock()
        if finished {
            stateLock.unlock()
            return snapshot(note: "重复调用 finish()", clean: writer.status == .completed)
        }
        finished = true
        let anchor = anchorPTS
        let frames = writtenVideoFrames
        let dropped = droppedVideoFrames
        let audioBuffers = writtenAudioBuffers
        let discarded = discardedAudioBuffers
        let last = lastPTS
        let failure = firstAppendFailure
        stateLock.unlock()

        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        // 一帧都没写进去时不要留文件。
        // 之前这种情况下会留下一个 0 字节的 .mov——用户看到的就是「录完 0 KB」，
        // 既打不开也说不出原因。删掉它，把真正的原因交给界面显示。
        if frames == 0 {
            try? FileManager.default.removeItem(at: outputURL)
            return Outcome(
                url: outputURL,
                tier: tier,
                duration: 0,
                fileSize: 0,
                writtenVideoFrames: 0,
                droppedVideoFrames: dropped,
                writtenAudioBuffers: audioBuffers,
                discardedAudioBuffers: discarded,
                effectiveFrameRate: 0,
                averageWriteRateMBps: 0,
                finishedCleanly: false,
                note: "未写入任何帧：\(failure ?? "编码器没有接受画面")"
            )
        }

        var note = "正常"
        var clean = true

        if writer.status == .failed {
            note = writer.error?.localizedDescription ?? "写入失败"
            clean = false
        } else if writer.status != .completed {
            note = "写入器状态异常：\(writer.status.rawValue)"
            clean = false
        }

        // 时长按最后一帧的时间戳算，不用墙钟——两者会因掉帧而分叉
        let duration = anchor != nil ? CMTimeGetSeconds(last) : 0
        let effectiveFPS = duration > 0 ? Double(frames) / duration : 0
        let size = Self.fileSize(at: outputURL)
        let wall = Date().timeIntervalSince(startWallClock)
        let rate = wall > 0 ? Double(size) / wall / 1_000_000.0 : 0

        if dropped > 0 {
            note += "；丢帧 \(dropped)"
        }
        if discarded > 0 {
            note += "；丢弃音频块 \(discarded)"
        }

        return Outcome(
            url: outputURL,
            tier: tier,
            duration: duration,
            fileSize: size,
            writtenVideoFrames: frames,
            droppedVideoFrames: dropped,
            writtenAudioBuffers: audioBuffers,
            discardedAudioBuffers: discarded,
            effectiveFrameRate: (effectiveFPS * 1000).rounded() / 1000,
            averageWriteRateMBps: (rate * 10).rounded() / 10,
            finishedCleanly: clean,
            note: note
        )
    }

    /// 中断写入并删除半成品文件
    func cancel() {
        stateLock.lock()
        finished = true
        stateLock.unlock()

        if writer.status == .writing {
            writer.cancelWriting()
        }
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func snapshot(note: String, clean: Bool) -> Outcome {
        Outcome(
            url: outputURL,
            tier: tier,
            duration: 0,
            fileSize: Self.fileSize(at: outputURL),
            writtenVideoFrames: 0,
            droppedVideoFrames: 0,
            writtenAudioBuffers: 0,
            discardedAudioBuffers: 0,
            effectiveFrameRate: 0,
            averageWriteRateMBps: 0,
            finishedCleanly: clean,
            note: note
        )
    }

    // MARK: - 工具

    /// 替换 sample buffer 的显示时间戳与时长，保留原始媒体数据。
    private static func retimed(
        _ sampleBuffer: CMSampleBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime
    ) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &out
        )
        guard status == noErr else { return nil }
        return out
    }

    static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 可用空间（字节）。用 important usage 口径，与系统给 App 的配额一致。
    static func availableCapacity(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// 同上，但读不到时返回 nil 而不是 0。
    ///
    /// 这两个必须分开：0 既可能真的没空间，也可能是这个键没读到。
    /// 早先统一按 0 处理，于是「读不到」被当成「满了」——
    /// 开录检查放行、计时器立刻判定「空间将满」并收手，一帧都录不下去。
    static func availableBytes(at url: URL? = nil) -> Int64? {
        let target = url ?? recordingDirectory()
        let values = try? target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage, bytes > 0 else {
            return nil
        }
        return bytes
    }

    /// 剩余可录时长（秒）。按该档真实写入速率折算，读不到容量时返回 0。
    static func remainingSeconds(tier: QualityTier) -> Double {
        let available = Double(availableCapacity(at: recordingDirectory()))
        guard available > 0 else { return 0 }
        return available / (max(tier.estimatedMegabytesPerSecond, 1) * 1_000_000)
    }

    /// 开录前的空间检查。
    ///
    /// 只拒绝真正无法开始的情况：不足 90 秒的写入量。
    /// 早先按"计划录 10 分钟"预留，配合被放大的码率估算，
    /// 会把有 94 GB 空闲的设备直接挡在门外——那不是保护，是误伤。
    /// 录制过程中由 `RecordingEngine` 持续监控，空间见底时正常收尾。
    static func preflightSpaceCheck(tier: QualityTier) -> RecorderError? {
        let available = availableCapacity(at: recordingDirectory())
        guard available > 0 else { return nil }

        let mbps = max(tier.estimatedMegabytesPerSecond, 1)
        let minimumBytes = Int64(90 * mbps * 1_000_000)
        if available < minimumBytes {
            return .insufficientSpace(
                requiredMB: minimumBytes / 1_000_000,
                availableMB: available / 1_000_000
            )
        }
        return nil
    }

    // MARK: - 输出位置

    /// 录制文件目录：Documents/Recordings。
    /// Info.plist 已开 UIFileSharingEnabled，可从「文件」App 直接拷出。
    static func recordingDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func makeOutputURL(tier: QualityTier, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "A_\(formatter.string(from: date))_\(tier.identifier).\(tier.fileExtension)"
        return recordingDirectory().appendingPathComponent(name)
    }
}
