import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Phase 2：真机实测。
/// Phase 1 只证明了「编码器接受某个尺寸」和「格式列表里有某项」，
/// 这一层要证明「真的能采到 24.000 fps 的 btp2 帧」「RAW 元数据真的在」。
final class LiveCaptureProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)

    private var timestamps: [Double] = []
    private var firstStructure: FrameStructure?
    private var sampleAttachmentKeys: [String] = []
    private var pixelAttachmentKeys: [String] = []
    private var formatExtensionKeys: [String] = []
    private var finished = false

    private let targetFrames = 30
    private let requestedPixelFormat = FourCC.code("btp2")

    // MARK: - 帧回调

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(pts)

        lock.lock()
        if finished {
            lock.unlock()
            return
        }

        if seconds.isFinite {
            timestamps.append(seconds)
        }

        if firstStructure == nil, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            firstStructure = Self.structure(of: imageBuffer)

            if let dictionary = CMCopyDictionaryOfAttachments(
                allocator: kCFAllocatorDefault,
                target: sampleBuffer,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            ) as? [String: Any] {
                sampleAttachmentKeys = dictionary.keys.sorted()
            }

            // kCVAttachmentMode_ShouldPropagate 在 iOS SDK 中不可见；
            // CVImageBuffer 符合 CMAttachmentBearer，复用 CM 接口读同一份附件。
            if let dictionary = CMCopyDictionaryOfAttachments(
                allocator: kCFAllocatorDefault,
                target: imageBuffer,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            ) as? [String: Any] {
                pixelAttachmentKeys = dictionary.keys.sorted()
            }

            if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
               let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any] {
                formatExtensionKeys = extensions.keys.sorted()
            }
        }

        let count = timestamps.count
        if count >= targetFrames && !finished {
            finished = true
            lock.unlock()
            semaphore.signal()
            return
        }
        lock.unlock()
    }

    private static func structure(of imageBuffer: CVImageBuffer) -> FrameStructure {
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(imageBuffer)
        let dataSize = CVPixelBufferGetDataSize(imageBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        let expected = Int((Double(width) * 12.0 / 8.0).rounded())

        return FrameStructure(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            planeCount: planeCount,
            pixelFormat: FourCC.string(pixelFormat),
            dataSizeBytes: dataSize,
            expectedBytesPerRowFor12Bit: expected,
            matchesExpectedLayout: bytesPerRow == expected,
            bayerBitDepth: FourCC.bayerBitDepth(pixelFormat)
        )
    }

    // MARK: - 主流程

    func run(
        device: AVCaptureDevice,
        format: AVCaptureDevice.Format
    ) -> (rate: FrameRateCheck?, capture: LiveCaptureResult) {

        // ---- 步骤 1：锁定精确 24.000 fps 并回读真实值 ----
        var rateCheck: FrameRateCheck?
        var setNote = ""
        var rateApplied = false

        do {
            try device.lockForConfiguration()

            let requested = CMTime(value: 1, timescale: 24)
            if device.activeFormat != format {
                device.activeFormat = format
            }

            // 赋一个不受支持的帧时长会抛 ObjC 异常——Swift 捕获不到，进程直接终止。
            // 所以先确认该格式的帧率区间真的含 24，再写。
            let supports24 = device.activeFormat.videoSupportedFrameRateRanges.contains {
                Double($0.minFrameRate) <= 24.001 && Double($0.maxFrameRate) >= 23.999
            }
            if supports24 {
                device.activeVideoMinFrameDuration = requested
                device.activeVideoMaxFrameDuration = requested
                rateApplied = true
            } else {
                setNote = "该格式帧率区间不含 24，未写入帧率"
            }

            let actual = device.activeVideoMinFrameDuration
            device.unlockForConfiguration()

            let range = device.activeFormat.videoSupportedFrameRateRanges.first
            let isExact = (actual.value == 1 && actual.timescale == 24)
            let isNTSC = (actual.value == 1001 && actual.timescale == 24000)

            rateCheck = FrameRateCheck(
                requestedSeconds: CMTimeGetSeconds(requested),
                actualValue: actual.value,
                actualTimescale: actual.timescale,
                actualSeconds: CMTimeGetSeconds(actual),
                isExact24: isExact,
                isNTSC23976: isNTSC,
                setStatus: isExact ? "精确 1/24" : (isNTSC ? "被改成 1001/24000（23.976）" : "实际 \(actual.value)/\(actual.timescale)"),
                rangeMin: range.map { Double($0.minFrameRate) } ?? 0,
                rangeMax: range.map { Double($0.maxFrameRate) } ?? 0,
                rangeMinDurationSeconds: range.map { CMTimeGetSeconds($0.minFrameDuration) } ?? 0
            )
            setNote = rateApplied ? "帧率锁定完成" : setNote
        } catch {
            setNote = "帧率锁定失败：\(error.localizedDescription)"
        }

        // ---- 步骤 2：配置 btp2 采集并收帧 ----
        let session = AVCaptureSession()
        var sessionStarted = false
        var note = setNote

        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return (rateCheck, emptyResult(note: note + "；无法创建设备输入"))
        }
        session.addInput(input)

        do {
            try device.lockForConfiguration()
            if device.activeFormat != format {
                device.activeFormat = format
            }
            device.unlockForConfiguration()
        } catch {
            note += "；设置 activeFormat 失败"
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "opengate.live.probe"))

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return (rateCheck, emptyResult(note: note + "；会话不接受视频输出"))
        }
        session.addOutput(output)

        // 顺序很关键：availableVideoPixelFormatTypes 只有在输出挂到会话（且已有输入）
        // 之后才有内容。直接给 videoSettings 赋一个不受支持的四字符码，
        // AVFoundation 会抛 ObjC 异常，Swift 捕获不到，进程直接终止。
        let available = output.availableVideoPixelFormatTypes
        let fallback = available.first ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if available.contains(requestedPixelFormat) {
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: requestedPixelFormat
            ]
        } else {
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: fallback
            ]
            note += "；该输出不提供 btp2（共 \(available.count) 种），已回退 \(FourCC.string(fallback))"
        }
        session.commitConfiguration()

        let wallStart = Date()
        session.startRunning()
        sessionStarted = session.isRunning

        let waitResult = semaphore.wait(timeout: .now() + 25)
        let wallElapsed = Date().timeIntervalSince(wallStart)
        session.stopRunning()

        // ---- 步骤 3：整理结果 ----
        lock.lock()
        let collected = timestamps.sorted()
        let structure = firstStructure
        let sampleKeys = sampleAttachmentKeys
        let pixelKeys = pixelAttachmentKeys
        let formatKeys = formatExtensionKeys
        lock.unlock()

        var minInterval = 0.0
        var maxInterval = 0.0
        var avgInterval = 0.0
        var intervals: [Double] = []

        if collected.count > 1 {
            for index in 1..<collected.count {
                let delta = (collected[index] - collected[index - 1]) * 1000.0
                if delta > 0 {
                    intervals.append(delta)
                }
            }
        }

        if !intervals.isEmpty {
            minInterval = intervals.min() ?? 0
            maxInterval = intervals.max() ?? 0
            avgInterval = intervals.reduce(0, +) / Double(intervals.count)
        }

        var measuredFPS = 0.0
        if let first = collected.first, let last = collected.last, collected.count > 1, last > first {
            measuredFPS = Double(collected.count - 1) / (last - first)
        }

        if waitResult == .timedOut {
            note += "；等待帧超时（25 秒）"
        }
        if !sessionStarted {
            note += "；会话未启动"
        }

        let capture = LiveCaptureResult(
            sessionStarted: sessionStarted,
            framesReceived: collected.count,
            captureWallSeconds: wallElapsed,
            measuredFPS: (measuredFPS * 1000).rounded() / 1000,
            intervalMinMS: (minInterval * 100).rounded() / 100,
            intervalMaxMS: (maxInterval * 100).rounded() / 100,
            intervalAvgMS: (avgInterval * 100).rounded() / 100,
            structure: structure,
            sampleBufferAttachmentKeys: sampleKeys,
            pixelBufferAttachmentKeys: pixelKeys,
            formatDescriptionExtensionKeys: formatKeys,
            note: note.isEmpty ? "正常" : note
        )

        return (rateCheck, capture)
    }

    private func emptyResult(note: String) -> LiveCaptureResult {
        LiveCaptureResult(
            sessionStarted: false,
            framesReceived: 0,
            captureWallSeconds: 0,
            measuredFPS: 0,
            intervalMinMS: 0,
            intervalMaxMS: 0,
            intervalAvgMS: 0,
            structure: nil,
            sampleBufferAttachmentKeys: [],
            pixelBufferAttachmentKeys: [],
            formatDescriptionExtensionKeys: [],
            note: note
        )
    }
}
