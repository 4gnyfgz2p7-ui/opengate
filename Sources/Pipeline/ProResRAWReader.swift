import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo

/// 用系统的 ProRes RAW 解码器把 .mov 解成 16-bit Bayer。
///
/// ## 为什么改走这条路
///
/// 采集时相机给的是 `btp2`——2 像素 3 字节的私有打包，Apple 没有公开文档。
/// 自己解包反复对不上：同一场景下自研解包算出的偶/奇位比是 0.762，
/// 官方解码是 1.106，均值差 2.8 倍。换了十几版判据都没找到正确位序，
/// 因为判据奖励「人为制造相关性」的排法，原理性缺陷注定选错。
///
/// 但系统自己有一条完全正确的路。ProRes RAW 写入器接受 btp2 并产出合规
/// 文件（Apple 官方解码器已验证：宽高、黑电平、色彩矩阵、CCT 全部合规），
/// 再用 VideoToolbox 把它解回来，输出就是
/// `kCVPixelFormatType_16VersatileBayer`（'bp16'）——
/// **每个 sensel 一个 16-bit 值，不需要解包**，排布信息还通过
/// buffer attachment 一并给出。
///
/// 代价是离线：必须先有 ProRes RAW 文件，不能边录边出。
final class ProResRAWReader {

    enum ReaderError: LocalizedError {
        case noVideoTrack
        case readerRejected(String)
        case cannotStart(String)
        case sessionCreate(OSStatus)
        case decode(OSStatus)
        case unexpectedFormat(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                return "文件里没有视频轨"
            case .readerRejected(let detail):
                return "读取器拒绝该轨道：\(detail)"
            case .cannotStart(let detail):
                return "读取器无法启动：\(detail)"
            case .sessionCreate(let status):
                return "解码会话创建失败（OSStatus \(status)）"
            case .decode(let status):
                return "解码失败（OSStatus \(status)）"
            case .unexpectedFormat(let detail):
                return "解码输出格式不符：\(detail)"
            case .timeout:
                return "解码超时"
            }
        }
    }

    /// 首帧的自检信息。写进诊断，用来确认系统到底给了什么。
    struct Probe {
        var width = 0
        var height = 0
        var rowBytes = 0
        var pixelFormat = "—"
        /// buffer attachment 里声明的排布，0=RGGB 1=BGGR 2=GRBG 3=GBRG
        var bayerPattern: Int?
        /// 原始样本的最小/最大/均值（16-bit 域）
        var minValue = 0
        var maxValue = 0
        var meanValue = 0
        /// 首行前 12 个值，方便和 PC 端解码结果逐点对账
        var firstValues: [Int] = []
        var note = ""

        var summary: String {
            var text = "\(width)×\(height) rb=\(rowBytes) pf=\(pixelFormat)"
            text += " pat=\(bayerPattern.map(String.init) ?? "—")"
            text += " v=\(minValue)…\(maxValue)/\(meanValue)"
            if !firstValues.isEmpty {
                text += " head=\(firstValues.prefix(8).map(String.init).joined(separator: ","))"
            }
            if !note.isEmpty { text += " note=\(note)" }
            return text
        }
    }

    /// 解码一整个文件（或前 `limit` 帧）。
    ///
    /// `onFrame` 返回 false 表示调用方要求提前停止。抛错即中断。
    /// 返回实际解码帧数与首帧自检信息。
    @discardableResult
    /// `format` 为 nil 时不指定输出格式，交给解码器自己决定。
    /// 这一点很重要：如果设备不认 bp16，指定就会直接失败，
    /// 而不指定至少能看出它原生给的是什么。
    static func decode(
        url: URL,
        limit: Int = .max,
        format: OSType? = BayerConverter.planar16Format,
        onFrame: (CVPixelBuffer, CMTime, Int) throws -> Bool
    ) throws -> (count: Int, probe: Probe?) {

        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks(withMediaType: .video)
        guard let track = tracks.first else { throw ReaderError.noVideoTrack }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ReaderError.cannotStart(error.localizedDescription)
        }

        // outputSettings 传 nil = 只要压缩样本，不做解码。
        // 让 AVAssetReader 直接给 bp16 是行不通的：它不接受这个像素格式，
        // 必须自己接 VTDecompressionSession。
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ReaderError.readerRejected("canAdd 为 false")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ReaderError.cannotStart(reader.error?.localizedDescription ?? "未知原因")
        }

        var session: VTDecompressionSession?
        defer {
            if let session { VTDecompressionSessionInvalidate(session) }
            reader.cancelReading()
        }

        var count = 0
        var probe: Probe?

        while let sample = output.copyNextSampleBuffer() {
            guard let description = CMSampleBufferGetFormatDescription(sample) else { continue }

            if session == nil {
                // 首选 bp16：单平面、16-bit、每 sensel 一个样本，
                // 不需要解包，相位还由 attachment 声明。
                // 传 nil 则不指定，让解码器给它的原生格式——
                // WWDC 2020 提到 ProRes RAW 最原生的输出是 RGBA half-float，
                // 如果这台设备不认 bp16，至少能看出它实际给什么。
                var attributes: CFDictionary?
                if let format {
                    attributes = [kCVPixelBufferPixelFormatTypeKey: format] as CFDictionary
                }
                var created: VTDecompressionSession?
                let status = VTDecompressionSessionCreate(
                    allocator: kCFAllocatorDefault,
                    formatDescription: description,
                    decoderSpecification: nil,
                    imageBufferAttributes: attributes,
                    outputCallback: nil,
                    decompressionSessionOut: &created
                )
                guard status == noErr, let created else {
                    throw ReaderError.sessionCreate(status)
                }
                session = created
            }
            guard let session else { break }

            var decoded: CVPixelBuffer?
            var decodeStatus: OSStatus = noErr
            let semaphore = DispatchSemaphore(value: 0)

            let submit = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sample,
                flags: [],
                infoFlagsOut: nil
            ) { status, _, imageBuffer, _, _ in
                decodeStatus = status
                decoded = imageBuffer
                semaphore.signal()
            }
            guard submit == noErr else { throw ReaderError.decode(submit) }
            guard semaphore.wait(timeout: .now() + 20) == .success else {
                throw ReaderError.timeout
            }
            guard decodeStatus == noErr else { throw ReaderError.decode(decodeStatus) }
            guard let buffer = decoded else { continue }

            if probe == nil {
                probe = inspect(buffer)
            }

            count += 1
            let keepGoing = try onFrame(buffer, CMSampleBufferGetPresentationTimeStamp(sample), count)
            if !keepGoing { break }
            if count >= limit { break }
        }

        if probe == nil {
            let status = reader.status
            let detail = reader.error?.localizedDescription ?? "无错误信息"
            throw ReaderError.cannotStart("未解出帧（reader=\(status.rawValue) \(detail)）")
        }
        return (count, probe)
    }

    /// 系统在 buffer attachment 里声明的 Bayer 排布。
    /// 这是 bp16 相比 btp2 最省事的一点：相位不用猜，解码器直接告诉。
    static func declaredPattern(of buffer: CVPixelBuffer) -> Int32? {        guard let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] else {
            return nil
        }
        for key in ["ProResRAW_BayerPattern", "BayerPattern", "kCVImageBufferBayerPatternKey"] {
            if let value = attachments[key] as? Int { return Int32(value) }
            if let value = attachments[key] as? NSNumber { return Int32(value.intValue) }
        }
        return nil
    }

    /// 读首帧的实际形态：尺寸、行字节、排布声明、值域。
    private static func inspect(_ buffer: CVPixelBuffer) -> Probe {
        var probe = Probe()
        probe.width = CVPixelBufferGetWidth(buffer)
        probe.height = CVPixelBufferGetHeight(buffer)
        probe.rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        probe.pixelFormat = fourCC(CVPixelBufferGetPixelFormatType(buffer))
        probe.bayerPattern = declaredPattern(of: buffer).map(Int.init)

        if probe.bayerPattern == nil,
           let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] {
            probe.note = "attachments=" + attachments.keys.sorted().prefix(4).joined(separator: ",")
        }

        if CVPixelBufferGetPixelFormatType(buffer) == BayerConverter.planar16Format {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                let row = base.assumingMemoryBound(to: UInt16.self)
                let rowStride = rowBytes / 2
                var low = Int(UInt16.max)
                var high = 0
                var total: Int64 = 0
                var samples = 0
                for y in stride(from: 0, to: probe.height, by: 7) {
                    let line = row.advanced(by: y * rowStride)
                    for x in stride(from: 0, to: probe.width, by: 5) {
                        let value = Int(line[x])
                        if value < low { low = value }
                        if value > high { high = value }
                        total += Int64(value)
                        samples += 1
                    }
                }
                probe.minValue = low
                probe.maxValue = high
                probe.meanValue = samples > 0 ? Int(total / Int64(samples)) : 0
                probe.firstValues = (0..<min(12, probe.width)).map { Int(row[$0]) }
            }
        } else {
            probe.note = "非 bp16，系统没有按请求给格式"
        }
        return probe
    }

    // MARK: - YUV 直读

    /// 系统解码器能给的 YUV 输出，按位深从高到低排。
    ///
    /// 实测这台机器上请求 `bp16` 会被静默降级成 `p420`（8-bit 4:2:0），
    /// 也就是 iOS 的 ProRes RAW 解码器**不做 Bayer 输出**，而是内部走完
    /// RAW 处理，直接给成品视频。既然如此，与其拒绝，不如按它给的处理：
    /// 颜色由 Apple 自己的管线决定，我们只负责换编码。
    static let yuvCandidates: [(format: OSType, name: String)] = [
        (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, "x420"),
        (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, "xf20"),
        (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "420v"),
        (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, "420f"),
        (kCVPixelFormatType_420YpCbCr8Planar, "p420"),
    ]

    /// 让 AVAssetReader 自己解码成指定 YUV 格式。
    ///
    /// 和 `decode` 的区别：那条路只要压缩样本、自己接 VideoToolbox，
    /// 目的是拿 Bayer；这条路把解码交给 AVFoundation，只要它解码后的
    /// 像素缓冲，因为目标格式本来就是成品视频。
    @discardableResult
    static func decodeYUV(
        url: URL,
        format: OSType?,
        limit: Int = .max,
        onFrame: (CVPixelBuffer, CMTime, Int) throws -> Bool
    ) throws -> (count: Int, probe: Probe?) {

        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw ReaderError.noVideoTrack
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ReaderError.cannotStart(error.localizedDescription)
        }

        var settings: [String: Any]?
        if let format {
            settings = [kCVPixelBufferPixelFormatTypeKey as String: format]
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ReaderError.readerRejected("YUV 输出配置不被接受")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ReaderError.cannotStart(reader.error?.localizedDescription ?? "未知原因")
        }
        defer { reader.cancelReading() }

        var count = 0
        var probe: Probe?
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            if probe == nil { probe = inspect(buffer) }
            count += 1
            let keepGoing = try onFrame(
                buffer,
                CMSampleBufferGetPresentationTimeStamp(sample),
                count
            )
            if !keepGoing { break }
            if count >= limit { break }
        }

        if probe == nil {
            let status = reader.status
            let detail = reader.error?.localizedDescription ?? "无错误信息"
            throw ReaderError.cannotStart("未解出帧（reader=\(status.rawValue) \(detail)）")
        }
        return (count, probe)
    }

    /// 逐个试 YUV 候选，返回第一个系统真的给出的格式。
    ///
    /// 必须比对**实际输出**而不是请求值：这次就是请求 bp16、系统静默给
    /// p420，只在请求侧判断会一直以为自己在拿 Bayer。
    static func detectYUVFormat(url: URL) -> (format: OSType, name: String, probe: Probe)? {
        for candidate in yuvCandidates {
            do {
                var actual: OSType = 0
                var seen: Probe?
                let result = try decodeYUV(url: url, format: candidate.format, limit: 1) { buffer, _, _ in
                    actual = CVPixelBufferGetPixelFormatType(buffer)
                    seen = inspect(buffer)
                    return false
                }
                _ = result
                if actual == candidate.format, let seen {
                    TranscodeLog.write("YUV 探测：请求 \(candidate.name) 得到 \(seen.pixelFormat) \(seen.width)×\(seen.height)")
                    return (actual, seen.pixelFormat, seen)
                }
                TranscodeLog.write("YUV 探测：请求 \(candidate.name) 实际得到 \(fourCC(actual))，继续下一个")
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                TranscodeLog.write("YUV 探测：\(candidate.name) 不可用（\(reason)）")
            }
        }
        // 最后一个兜底：不指定格式，让系统自己挑
        do {
            var actual: OSType = 0
            var seen: Probe?
            _ = try decodeYUV(url: url, format: nil, limit: 1) { buffer, _, _ in
                actual = CVPixelBufferGetPixelFormatType(buffer)
                seen = inspect(buffer)
                return false
            }
            if let seen {
                TranscodeLog.write("YUV 探测：系统默认 \(seen.pixelFormat) \(seen.width)×\(seen.height)")
                return (actual, seen.pixelFormat, seen)
            }
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            TranscodeLog.write("YUV 探测：系统默认也失败（\(reason)）")
        }
        return nil
    }

    private static func fourCC(_ code: OSType) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        let text = String(bytes: bytes, encoding: .ascii) ?? ""
        return text.allSatisfy { $0.isLetter || $0.isNumber } ? text : String(code)
    }
}
