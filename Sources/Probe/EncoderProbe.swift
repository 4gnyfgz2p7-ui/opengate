import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo
import CoreMedia

/// 编码回调与调用线程之间的结果容器。
final class EncodeResultBox {
    var framesEmitted: Int = 0
    var lastStatus: OSStatus = noErr
    var encodedWidth: Int32?
    var encodedHeight: Int32?
}

enum EncoderProbe {

    private static let outputCallback: VTCompressionOutputCallback = {
        _, sourceFrameRefCon, status, _, sampleBuffer in
        guard let sourceFrameRefCon = sourceFrameRefCon else { return }
        let box = Unmanaged<EncodeResultBox>
            .fromOpaque(sourceFrameRefCon)
            .takeUnretainedValue()
        box.lastStatus = status
        guard status == noErr, let sampleBuffer = sampleBuffer else { return }
        box.framesEmitted += 1
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            box.encodedWidth = dimensions.width
            box.encodedHeight = dimensions.height
        }
    }

    // MARK: - 压缩编码器探测

    /// 三步验证：
    /// 1. 用 `VTCopySupportedPropertyDictionaryForEncoder` 问编码器是否接受该宽高
    /// 2. 真实创建 `VTCompressionSession`
    /// 3. 真实编码一帧，从输出 `CMFormatDescription` 回读实际生效分辨率
    ///
    /// 第 3 步是关键：即使会话创建成功，编码器也可能按文档所述「改变宽高」。
    static func check(
        label: String,
        codec: CMVideoCodecType,
        width: Int32,
        height: Int32,
        inputPixelFormat: OSType,
        profileLevel: CFString?
    ) -> EncoderCheck {

        var result = EncoderCheck(
            label: label,
            codecFourCC: FourCC.string(codec),
            width: width,
            height: height,
            queryStatus: -1,
            queryOK: false,
            sessionCreateStatus: -1,
            sessionCreated: false,
            profileSetStatus: -1,
            realTimeSetStatus: -1,
            encodeStatus: -1,
            framesEmitted: 0,
            encodedWidth: nil,
            encodedHeight: nil,
            dimensionsPreserved: nil,
            profileLevelReadback: nil,
            note: ""
        )

        // 步骤 1：支持性查询
        let queryStatus = VTCopySupportedPropertyDictionaryForEncoder(
            width: width,
            height: height,
            codecType: codec,
            encoderSpecification: nil,
            encoderIDOut: nil,
            supportedPropertiesOut: nil
        )
        result.queryStatus = queryStatus
        result.queryOK = queryStatus == noErr

        // 步骤 2：创建会话
        let box = EncodeResultBox()
        let refCon = Unmanaged.passUnretained(box).toOpaque()

        let attributeDict: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: inputPixelFormat,
            kCVPixelBufferWidthKey as String: Int(width),
            kCVPixelBufferHeightKey as String: Int(height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]

        var session: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codec,
            encoderSpecification: nil,
            imageBufferAttributes: attributeDict as CFDictionary,
            compressedVideoOutputCallback: outputCallback,
            outputCallbackRefCon: refCon,
            compressionSessionOut: &session
        )
        result.sessionCreateStatus = createStatus
        result.sessionCreated = (createStatus == noErr && session != nil)

        guard let session = session, createStatus == noErr else {
            result.note = "会话创建失败，编码器不接受 \(width)x\(height)"
            return result
        }

        // 属性设置
        if let profileLevel = profileLevel {
            result.profileSetStatus = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                propertyValue: profileLevel
            )
        }
        result.realTimeSetStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_RealTime,
            propertyValue: kCFBooleanTrue
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            propertyValue: kCFBooleanFalse
        )

        var readback: CFTypeRef?
        let readbackStatus = VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            allocator: kCFAllocatorDefault,
            valueOut: &readback
        )
        if readbackStatus == noErr, let value = readback {
            result.profileLevelReadback = "\(value)"
        }

        // 步骤 3：编码一帧并回读实际分辨率
        var pixelBuffer: CVPixelBuffer?
        let bufferAttributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let bufferStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(width),
            Int(height),
            inputPixelFormat,
            bufferAttributes as CFDictionary,
            &pixelBuffer
        )

        guard bufferStatus == kCVReturnSuccess, let buffer = pixelBuffer else {
            result.note = "像素缓冲创建失败（CVReturn \(bufferStatus)）"
            VTCompressionSessionInvalidate(session)
            return result
        }

        fill(buffer: buffer, value: 0x40)

        var infoFlags = VTEncodeInfoFlags()
        result.encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: buffer,
            presentationTimeStamp: CMTime(value: 0, timescale: 24),
            duration: CMTime(value: 1, timescale: 24),
            frameProperties: nil,
            sourceFrameRefcon: refCon,
            infoFlagsOut: &infoFlags
        )

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        result.framesEmitted = box.framesEmitted
        result.encodedWidth = box.encodedWidth
        result.encodedHeight = box.encodedHeight

        if let encodedWidth = box.encodedWidth, let encodedHeight = box.encodedHeight {
            let preserved = (encodedWidth == width && encodedHeight == height)
            result.dimensionsPreserved = preserved
            result.note = preserved
                ? "编码输出分辨率与请求一致"
                : "编码器将 \(width)x\(height) 改为 \(encodedWidth)x\(encodedHeight)"
        } else if box.framesEmitted == 0 {
            result.note = "编码器未吐出帧（encodeStatus \(result.encodeStatus)）"
        }

        VTCompressionSessionInvalidate(session)
        return result
    }

    private static func fill(buffer: CVPixelBuffer, value: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let planeCount = CVPixelBufferGetPlaneCount(buffer)
        if planeCount > 1 {
            for plane in 0..<planeCount {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
                let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
                let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                memset(base, Int32(value), height * bytesPerRow)
            }
        } else if let base = CVPixelBufferGetBaseAddress(buffer) {
            let height = CVPixelBufferGetHeight(buffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            memset(base, Int32(value), height * bytesPerRow)
        }
    }

    // MARK: - AVAssetWriter 探测

    /// 只验证「writer 能否接受这组输出设置并进入 writing」，不做真实落盘。
    static func checkWriter(
        label: String,
        codec: AVVideoCodecType,
        width: Int,
        height: Int,
        extraSettings: [String: Any] = [:]
    ) -> WriterCheck {

        var result = WriterCheck(
            label: label,
            codec: codec.rawValue,
            width: width,
            height: height,
            writerCreateStatus: -1,
            canApplySettings: false,
            startWriting: false,
            note: ""
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString).mov")

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            result.writerCreateStatus = 0

            var settings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
            for (key, value) in extraSettings {
                settings[key] = value
            }

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            result.canApplySettings = input.canApply(outputSettings: settings, forMediaType: .video)

            if writer.canAdd(input) {
                writer.add(input)
                result.startWriting = writer.startWriting()
                writer.cancelWriting()
                if !result.startWriting {
                    result.note = "startWriting 失败"
                }
            } else {
                result.note = "writer 不接受该 input"
            }
        } catch {
            result.writerCreateStatus = Int32((error as NSError).code)
            result.note = error.localizedDescription
        }

        try? FileManager.default.removeItem(at: url)
        return result
    }
}
