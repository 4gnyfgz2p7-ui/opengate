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
        case videoInputRejected
        case audioInputRejected
        case startWritingFailed(String)
        case insufficientSpace(requiredMB: Int64, availableMB: Int64)

        var errorDescription: String? {
            switch self {
            case .writerCreationFailed(let reason):
                return "无法创建写入器：\(reason)"
            case .videoInputRejected:
                return "写入器不接受该档的视频参数"
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
    private var audioInput: AVAssetWriterInput?

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
        videoTransform: CGAffineTransform = .identity
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
        let videoSettings = VideoSettingsBuilder.videoSettings(
            tier: tier,
            width: width,
            height: height,
            appleLog2: appleLog2
        )

        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw RecorderError.videoInputRejected
        }

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        // 拍摄方向只作为显示矩阵写入容器，**不旋转像素**。
        // 4224×3024 是传感器原生画幅，旋转像素要么改变实际存储尺寸，
        // 要么引入一次全画幅重采样，与「全幅不裁切、不改几何」冲突。
        vInput.transform = videoTransform
        guard writer.canAdd(vInput) else {
            throw RecorderError.videoInputRejected
        }
        writer.add(vInput)
        videoInput = vInput

        // ---- 音频输入 ----
        if withAudio {
            let aSettings = AudioSettings.writerSettings
            if writer.canApply(outputSettings: aSettings, forMediaType: .audio) {
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
                aInput.expectsMediaDataInRealTime = true
                if writer.canAdd(aInput) {
                    writer.add(aInput)
                    audioInput = aInput
                }
            }
        }

        // ---- 元数据：必须在 startWriting 之前 ----
        writer.metadata = metadata

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

    /// 视频帧。时间戳按真实经过时间折算到 24 时基，既保证时基纯净，
    /// 又不累积偏差。
    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        stateLock.lock()
        let alreadyFinished = finished
        stateLock.unlock()
        guard !alreadyFinished, writer.status == .writing else { return }

        guard videoInput.isReadyForMoreMediaData else {
            stateLock.lock(); droppedVideoFrames += 1; stateLock.unlock()
            return
        }

        let realPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

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

        if isDuplicateGrid { return }

        let targetPTS = CMTime(value: index, timescale: Self.frameTimescale)

        guard let retimed = Self.retimed(
            sampleBuffer,
            presentationTimeStamp: targetPTS,
            duration: CMTime(value: 1, timescale: Self.frameTimescale)
        ) else {
            stateLock.lock(); droppedVideoFrames += 1; stateLock.unlock()
            return
        }

        if videoInput.append(retimed) {
            stateLock.lock()
            writtenVideoFrames += 1
            lastPTS = targetPTS
            stateLock.unlock()
        } else {
            stateLock.lock(); droppedVideoFrames += 1; stateLock.unlock()
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
        stateLock.unlock()

        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
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
