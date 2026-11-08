import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo

/// 边录边转：同一份 btp2 原始样本，一路落 RAW 文件，一路在内存里解成画面写 HEVC。
///
/// 与"双路采集"的区别：这里**只有一路采集**。数据在内存里分叉，
/// 解码用的就是写进 RAW 的那一帧，不额外占用 ISP、不多一次采样，
/// 画面严格来自这一条 RAW 流。
///
/// 解码走 VideoToolbox 的 ProRes RAW 解码器。实时性取决于这台机器能跑多快：
/// 跟不上时按帧丢弃并计数，主路写 RAW 不受任何影响。
final class LiveRawTranscoder {

    struct Stats {
        var submitted = 0
        var decoded = 0
        var dropped = 0
        var pixelFormat = "—"
        var lastError: String?

        var summary: String {
            var text = "decode \(decoded)/\(submitted)"
            if dropped > 0 { text += " 丢\(dropped)" }
            text += " pf=\(pixelFormat)"
            if let e = lastError { text += " err=\(e)" }
            return text
        }
    }

    let recorder: MovieRecorder
    /// 解码串行队列：保证帧序，也让采集回调立即返回
    private let queue = DispatchQueue(label: "acamera.live.raw", qos: .userInitiated)
    private let lock = NSLock()

    private var session: VTDecompressionSession?
    private var submitted = 0
    private var decoded = 0
    private var dropped = 0
    private var pixelFormat = "—"
    private var lastError: String?
    /// 积压超过这个数就丢帧：宁可少几帧，也不让内存无限涨
    private let maxPending = 6
    private var pending = 0
    private var stopped = false

    init(recorder: MovieRecorder) {
        self.recorder = recorder
    }

    var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return Stats(submitted: submitted, decoded: decoded, dropped: dropped,
                     pixelFormat: pixelFormat, lastError: lastError)
    }

    /// 采集回调里调用，立即返回。
    func submit(_ sample: CMSampleBuffer) {
        lock.lock()
        if stopped { lock.unlock(); return }
        submitted += 1
        if pending >= maxPending {
            dropped += 1
            lock.unlock()
            return
        }
        pending += 1
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.decodeAndAppend(sample)
            self.lock.lock(); self.pending -= 1; self.lock.unlock()
        }
    }

    private func decodeAndAppend(_ sample: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return }

        if session == nil {
            // 不指定输出格式：让解码器给原生格式，再按实际结果处理。
            // 指定 bp16 在这台机器上会被静默降级，不如先看清楚它给什么。
            var created: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: description,
                decoderSpecification: nil,
                imageBufferAttributes: nil,
                outputCallback: nil,
                decompressionSessionOut: &created
            )
            guard status == noErr, let created else {
                lock.lock()
                lastError = "会话创建失败 \(status)"
                stopped = true
                lock.unlock()
                return
            }
            session = created
        }
        guard let session else { return }

        var decodedBuffer: CVPixelBuffer?
        var decodeStatus: OSStatus = noErr
        let semaphore = DispatchSemaphore(value: 0)

        let submitStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            decodeStatus = status
            decodedBuffer = imageBuffer
            semaphore.signal()
        }
        guard submitStatus == noErr else {
            lock.lock(); lastError = "提交失败 \(submitStatus)"; lock.unlock()
            return
        }
        // 等太久说明这颗机器的 ProRes RAW 解码跟不上 24 fps，
        // 直接放弃这一帧，别把队列堵死。
        guard semaphore.wait(timeout: .now() + 2.0) == .success else {
            lock.lock(); dropped += 1; lastError = "解码超时"; lock.unlock()
            return
        }
        guard decodeStatus == noErr, let buffer = decodedBuffer else {
            lock.lock()
            lastError = "解码失败 \(decodeStatus)"
            lock.unlock()
            return
        }

        if pixelFormat == "—" {
            pixelFormat = Self.fourCC(CVPixelBufferGetPixelFormatType(buffer))
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let ok = recorder.appendImageBuffer(buffer, presentationTimeStamp: pts)
        lock.lock()
        if ok { decoded += 1 } else { dropped += 1 }
        lock.unlock()
    }

    /// 收尾。等队列排空后返回最终统计，主路照常保留。
    @discardableResult
    func finish() async -> Stats {
        lock.lock(); stopped = true; lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        return stats
    }

    private static func fourCC(_ code: OSType) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                     UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        let text = String(bytes: bytes, encoding: .ascii) ?? "?"
        return text.trimmingCharacters(in: .whitespaces)
    }
}
