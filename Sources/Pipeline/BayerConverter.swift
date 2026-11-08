import Foundation
import CoreVideo
import CoreMedia
import Metal

/// btp2（Bayer 12-bit 打包）→ 32BGRA。
///
/// **为什么不再自己写 YUV**
///
/// 10-bit biplanar 的平面是 16-bit 容器、10-bit 有效、video range 64..940。
/// 往里写一个样本要同时满足三件事：按 /1023 归一、叠上 64+876*y 的映射、
/// 色度再加 512 偏置。漏掉任何一件都不会报错，只会得到一张错图——
/// 实测 0.5.11 的成片就是 Y 全 0、Cb 467、Cr 684，播放器里呈现纯红：
/// 亮度每个像素都被压进 0 附近的量化格，色度却按正确公式算出了颜色。
///
/// BGRA 没有这一层歧义：写 0..1 就是 0..255。转成 10-bit YUV 的事交给
/// AVFoundation 的标准路径，那是系统每天都在跑的代码。
///
/// 位深从 10 bit 降到 8 bit 是当前阶段的自觉取舍：先把画面弄对，
/// 等 Apple Log 2 接进来时再换 16-bit 浮点通路（Log 本来就要在 RGB 域做）。
final class BayerConverter {

    /// 与着色器里的 `p[...]` 下标一一对应。
    struct Parameters {
        var blackLevel: Float = 0
        var whiteLevel: Float = 4095
        var redGain: Float = 1
        var greenGain: Float = 1
        var blueGain: Float = 1
        /// 0=RGGB 1=BGGR 2=GRBG 3=GBRG
        var pattern: Int32 = 0
        /// 源是 `bp16`（系统 ProRes RAW 解码输出）而不是 `btp2`。
        ///
        /// 两者差别是根本性的：`btp2` 需要自己解包、自己猜位序和相位，
        /// 而 `bp16` 每个 sensel 一个 16-bit 值，相位由系统在 buffer
        /// attachment 里声明。所以这条路上**不做设备端标定**，
        /// 相位与白平衡全部由调用方给定。
        var planar16: Bool = false
        /// 自校准算出的解包位序。有值时只评估这一种，不再搜索。
        ///
        /// 搜索出来的位序一直不可靠：判据奖励「相邻像素共享低位字节」的排法，
        /// mode9/10 永远胜出，而它们与官方解码对不上。自校准用官方解码结果
        /// 做标准答案反推位序，一旦成立就该锁死，不能再让搜索改回去。
        var lockMode: Int32? = nil
    }

    /// 一次转换的自检结果。直接读数，不猜。
    struct Diagnostics {
        var kernelRan = false
        var kernelWidth: UInt32 = 0
        var kernelHeight: UInt32 = 0
        /// kernel 自己算出来的第一个像素（RGB ×1000），验证像素管线是否有值
        var firstPixel = "—"
        /// 输出缓冲上稀疏采样得到的 RGB 极值与均值（0..255）
        var outMin: [UInt8] = [0, 0, 0]
        var outMax: [UInt8] = [0, 0, 0]
        var outMean: [UInt8] = [0, 0, 0]
        /// 原始 Bayer 样本范围（未扣黑电平），用来判断黑白电平参数是否合理
        var rawRange = "—"
        /// 源数据前 24 字节的十六进制。打包方式若有疑问，用这 8 组字节在 PC 上直接验算。
        var rawHead = "—"
        /// 按当前解包方式读出的第一行前 16 个像素值
        var firstPixels = "—"
        /// 源的每行字节数。像素排法全靠它和宽度相除得出，必须留档。
        var sourceRowBytes = 0
        var calibration = ""

        var maxChannel: UInt8 { outMax.max() ?? 0 }

        /// 整幅基本无亮度就判失败
        var isBlack: Bool { maxChannel < 10 }

        var summary: String {
            var text = "GPU \(kernelRan ? 1 : 0) · \(kernelWidth)×\(kernelHeight)"
            text += " · RGB≤\(outMin[0])/\(outMin[1])/\(outMin[2])…\(outMax[0])/\(outMax[1])/\(outMax[2])"
            if !calibration.isEmpty { text += " · " + calibration }
            return text
        }

        /// 写进视频文件的诊断串，ffprobe 直接可读
        var metadataText: String {
            // 顺序即优先级：QuickTime 的元数据字段有长度上限，超出部分会被静默截掉。
            // 之前把 512 字节的 head 放在中间，结果 cal（相位与白平衡增益）和 pixels
            // 全被切掉——恰恰是最该看的两项。所以决定性字段必须排在前面，
            // head 只留前 48 字节（够看出解包对不对）。
            [
                "cal=\(calibration)",
                "raw=\(rawRange)",
                "rgb_mean=\(outMean[0]),\(outMean[1]),\(outMean[2])",
                "rgb_max=\(outMax[0]),\(outMax[1]),\(outMax[2])",
                "first=\(firstPixel)",
                "gpu=\(kernelRan ? 1 : 0)",
                "size=\(kernelWidth)x\(kernelHeight)",
                "row=\(sourceRowBytes)",
                "pixels=\(firstPixels)",
                "head=\(String(rawHead.prefix(96)))",
            ].joined(separator: ";")
        }
    }

    static let bayerFormat: OSType = FourCC.code("btp2")
    /// 系统 ProRes RAW 解码器的输出（'bp16'）。
    /// 用 FourCC 构造而不引用 `kCVPixelFormatType_16VersatileBayer` 常量：
    /// 后者在部分 SDK 版本里没有 Swift 符号，直接用字符串更稳。
    static let planar16Format: OSType = FourCC.code("bp16")
    static let outputFormat: OSType = kCVPixelFormatType_32BGRA
    /// 供外部（写入端）判断该走哪条追加路径
    static func isBayer(_ format: OSType) -> Bool { format == bayerFormat }
    /// bp16 是否可被本转换器直接消费
    static func accepts(_ format: OSType) -> Bool {
        format == bayerFormat || format == planar16Format
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?

    private var sourceBuffer: MTLBuffer?
    private var sourceCapacity = 0
    private var paramsBuffer: MTLBuffer?
    private var probeBuffer: MTLBuffer?
    private var pools: [OSType: CVPixelBufferPool] = [:]
    private var poolWidth = 0
    private var poolHeight = 0
    private var outputTextureRef: CVMetalTexture?

    /// 构造失败的原因，显示在设置页
    private(set) static var compileNote: String?

    /// 第一帧自动标定出来的解包方式与相位
    private(set) var calibration: BayerCalibration.Outcome?

    private(set) var lastFailureStage: String?
    private(set) var lastDiagnostics = Diagnostics()

    /// 初始化失败即代表这台设备走不了 Bayer 通路，调用方应降级到系统 ISP 格式。
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }

        do {
            let options = MTLCompileOptions()
            let library = try device.makeLibrary(source: Self.shaderSource, options: options)
            guard let function = library.makeFunction(name: "bayer_to_bgra") else {
                Self.compileNote = "找不到 bayer_to_bgra"
                return nil
            }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            Self.compileNote = "着色器编译失败：\(error.localizedDescription)"
            return nil
        }

        self.device = device
        self.queue = queue
        self.paramsBuffer = device.makeBuffer(length: 64, options: .storageModeShared)
        self.probeBuffer = device.makeBuffer(length: 64, options: .storageModeShared)
        guard paramsBuffer != nil, probeBuffer != nil else { return nil }

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess else {
            Self.compileNote = "纹理缓存创建失败（\(status)）"
            return nil
        }
        textureCache = cache
    }

    // MARK: - 转换

    func convert(
        _ source: CVPixelBuffer,
        parameters: Parameters
    ) -> CVPixelBuffer? {
        lastFailureStage = nil

        let sourceFormat = CVPixelBufferGetPixelFormatType(source)
        guard sourceFormat == Self.bayerFormat || sourceFormat == Self.planar16Format else {
            lastFailureStage = "源既不是 btp2 也不是 bp16"
            return nil
        }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 1, height > 1 else {
            lastFailureStage = "源尺寸异常"
            return nil
        }

        guard let output = pooledBuffer(format: Self.outputFormat, width: width, height: height) else {
            lastFailureStage = "输出像素缓冲创建失败"
            return nil
        }
        guard let cache = textureCache else {
            lastFailureStage = "纹理缓存缺失"
            return nil
        }

        var cvTexture: CVMetalTexture?
        let textureStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, output, nil,
            MTLPixelFormat.bgra8Unorm, width, height, 0, &cvTexture
        )
        guard textureStatus == kCVReturnSuccess,
              let cvTexture = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture)
        else {
            lastFailureStage = "纹理创建失败（\(textureStatus)）"
            return nil
        }
        outputTextureRef = cvTexture

        // ---- 源：Bayer 没有对应像素格式，只能拷进 MTLBuffer ----
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        guard let sourceBase = CVPixelBufferGetBaseAddress(source) else {
            lastFailureStage = "源地址不可读"
            return nil
        }
        let sourceRowBytes = CVPixelBufferGetBytesPerRow(source)
        let sourceLength = sourceRowBytes * height

        // 前 512 字节的十六进制，供离线核验排法。
        //
        // 早先只存 24 字节（8 组三字节），够看出"每组的字节关系"，但不够
        // 做统计——判据在设备上选错时，靠这 24 字节只能人工推、无法回放验证。
        // 512 字节 = 170 组 ≈ 341 个像素，足以在 PC 上把每种排法各跑一遍
        // 相邻差，直接看出设备选的和真实排法差多少。
        var headText = ""
        let headPointer = sourceBase.assumingMemoryBound(to: UInt8.self)
        for index in 0..<min(512, sourceLength) {
            headText += String(format: "%02x", headPointer[index])
        }

        // 第一行前 16 个像素留到标定之后再读：那时才知道该用哪种排法，
        // 用错排法读出来的数字没有诊断价值。
        var pixelText = ""

        if sourceBuffer == nil || sourceCapacity < sourceLength {
            guard let allocated = device.makeBuffer(length: sourceLength, options: .storageModeShared) else {
                lastFailureStage = "源缓冲分配失败"
                return nil
            }
            sourceBuffer = allocated
            sourceCapacity = sourceLength
        }
        guard let bayerBuffer = sourceBuffer,
              let paramsBuffer = paramsBuffer,
              let probeBuffer = probeBuffer
        else {
            lastFailureStage = "缓冲缺失"
            return nil
        }

        // 第一帧把解包方式与 Bayer 相位定下来：取错排法不会报错，
        // 只会得到一张浮雕状的图，靠肉眼看是猜不出来的。
        // bp16 也必须走标定器，只是把位序钉死在 15。
        //
        // 早先这里直接跳过，相位与白平衡另算了一套——结果是同一次曝光
        // 在「离线处理文件」和「实时录制」两条路上得到不同的白平衡，
        // 拿离线结果去判断实时画面就没有意义了。测试工具必须和被测量对象
        // 是同一套代码，否则验证的是两件事。
        if calibration == nil {
            calibration = BayerCalibration.run(
                base: sourceBase,
                rowBytes: sourceRowBytes,
                width: width,
                height: height,
                black: parameters.blackLevel,
                white: parameters.whiteLevel,
                redGain: parameters.redGain,
                blueGain: parameters.blueGain,
                preferredPattern: parameters.pattern,
                forceMode: parameters.lockMode ?? (parameters.planar16 ? 15 : nil)
            )
        }

        memcpy(bayerBuffer.contents(), sourceBase, sourceLength)

        // 用标定选中的排法读第一行前 16 个像素：这串数字直接反映解包对不对
        //（正确排法下相邻值应在同一量级；错了会看到 10 倍以上的交替）
        let activeMode = parameters.planar16 ? 15 : Int(calibration?.unpackMode ?? 0)
        let headRow = headPointer
        for x in 0..<min(16, width) {
            let sample = BayerCalibration.unpack(headRow, x, mode: activeMode)
            pixelText += (x == 0 ? "" : ",") + String(Int(sample))
        }

        // ---- 参数：扁平 uint32，下标即协议 ----
        // 白平衡用标定出来的场景值：设备附件里的 WhiteBalance*Factor 量纲不明，
        // 直接乘会出现 G 被压到 63、R/B 抬到 100/91 的偏品红画面。
        var redGain = parameters.redGain
        var greenGain = parameters.greenGain
        var blueGain = parameters.blueGain
        var activePattern = parameters.pattern
        var activeUnpack: Int32 = parameters.planar16 ? 15 : 0
        if let calibrated = calibration {
            redGain = calibrated.whiteBalanceRed
            greenGain = 1
            blueGain = calibrated.whiteBalanceBlue
            // 位序被锁死（自校准）或走 bp16（系统已声明相位）时，
            // 相位以外部给定的为准，不让标定再猜一次
            activePattern = (parameters.lockMode != nil || parameters.planar16)
                ? parameters.pattern
                : calibrated.pattern
            activeUnpack = calibrated.unpackMode
        }
        let floats = [parameters.blackLevel, parameters.whiteLevel,
                      redGain, greenGain, blueGain]
        var slots = [UInt32](repeating: 0, count: 11)
        slots[0] = UInt32(width)
        slots[1] = UInt32(height)
        slots[2] = UInt32(sourceRowBytes)
        slots[3] = 0
        for (index, value) in floats.enumerated() {
            slots[4 + index] = value.bitPattern
        }
        slots[9] = UInt32(bitPattern: activePattern)
        slots[10] = UInt32(bitPattern: activeUnpack)
        slots.withUnsafeBytes { memcpy(paramsBuffer.contents(), $0.baseAddress, 44) }
        memset(probeBuffer.contents(), 0, 32)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            lastFailureStage = "命令队列失败"
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(bayerBuffer, offset: 0, index: 0)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(paramsBuffer, offset: 0, index: 3)
        encoder.setBuffer(probeBuffer, offset: 0, index: 4)

        let groupWidth = 16
        let groupHeight = 16
        let gridWidth = (width + 1) / 2
        let gridHeight = (height + 1) / 2
        encoder.dispatchThreadgroups(
            MTLSize(width: (gridWidth + groupWidth - 1) / groupWidth,
                    height: (gridHeight + groupHeight - 1) / groupHeight,
                    depth: 1),
            threadsPerThreadgroup: MTLSize(width: groupWidth, height: groupHeight, depth: 1)
        )
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        outputTextureRef = nil
        CVMetalTextureCacheFlush(cache, 0)

        guard commandBuffer.status == .completed else {
            lastFailureStage = "GPU 未完成（\(commandBuffer.status.rawValue)）"
            return nil
        }

        let probe = probeBuffer.contents().bindMemory(to: UInt32.self, capacity: 8)
        var diagnostics = Diagnostics()
        diagnostics.kernelRan = probe[0] == 1
        diagnostics.kernelWidth = probe[1]
        diagnostics.kernelHeight = probe[2]
        diagnostics.firstPixel = String(
            format: "%.3f/%.3f/%.3f",
            Double(probe[4]) / 1000.0,
            Double(probe[5]) / 1000.0,
            Double(probe[6]) / 1000.0
        )
        diagnostics.calibration = calibration?.summary ?? ""
        diagnostics.rawRange = calibration?.rawRangeText ?? "—"
        diagnostics.rawHead = headText
        diagnostics.firstPixels = pixelText
        diagnostics.sourceRowBytes = sourceRowBytes

        // ---- 从**最终像素缓冲**上读回来：这一步是唯一可信的验收 ----
        CVPixelBufferLockBaseAddress(output, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(output) {
            let stride = CVPixelBufferGetBytesPerRow(output)
            var lows = [UInt8](repeating: 255, count: 3)
            var highs = [UInt8](repeating: 0, count: 3)
            var sums = [Int](repeating: 0, count: 3)
            var count = 0
            var row = 0
            while row < height {
                let rowPointer = base.advanced(by: row * stride)
                var column = 0
                while column < width {
                    let pixel = rowPointer.advanced(by: column * 4)
                        .assumingMemoryBound(to: UInt8.self)
                    // BGRA 内存顺序
                    let values = [pixel[2], pixel[1], pixel[0]]
                    for channel in 0..<3 {
                        let value = values[channel]
                        if value < lows[channel] { lows[channel] = value }
                        if value > highs[channel] { highs[channel] = value }
                        sums[channel] += Int(value)
                    }
                    count += 1
                    column += 61
                }
                row += 61
            }
            if count > 0 {
                diagnostics.outMin = lows
                diagnostics.outMax = highs
                diagnostics.outMean = (0..<3).map { UInt8(clamping: sums[$0] / count) }
            }
        }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)

        lastDiagnostics = diagnostics

        if !diagnostics.kernelRan {
            lastFailureStage = "kernel 未执行（probe 为 0）"
            return nil
        }
        if diagnostics.isBlack {
            lastFailureStage = "输出无亮度（RGB≤\(diagnostics.maxChannel)）"
            return nil
        }

        return output
    }

    // MARK: - 缓冲

    private func pooledBuffer(format: OSType, width: Int, height: Int) -> CVPixelBuffer? {
        if poolWidth != width || poolHeight != height {
            pools.removeAll()
            poolWidth = width
            poolHeight = height
        }

        if pools[format] == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                nil,
                attributes as CFDictionary,
                &pool
            )
            if status == kCVReturnSuccess, let created = pool { pools[format] = created }
        }

        if let pool = pools[format] {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            if status == kCVReturnSuccess, let buffer = buffer { return buffer }
        }

        // 池这条路不通就直接建一个
        let directAttributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var direct: CVPixelBuffer?
        let directStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            directAttributes as CFDictionary,
            &direct
        )
        guard directStatus == kCVReturnSuccess else { return nil }
        return direct
    }

    // MARK: - 着色器

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    inline int ac_clamp(int v, int lo, int hi) {
        return v < lo ? lo : (v > hi ? hi : v);
    }

    // btp2 的字节排列没有公开文档。唯一确定的是 bytesPerRow = 4224 × 1.5，
    // 即每像素 1.5 字节；这 12 位由哪几个字节拼成有十一种讲得通的排法，
    // 尺寸验算全都成立，只有真数据上的统计性质能分辨。
    //
    // 排法由 CPU 侧标定后通过 p[10] 传进来（见 BayerCalibration.unpack），
    // 这里逐分支复刻同样的规则，保证两边算出同一个数。
    inline ushort ac_raw12(const device uchar* base, uint rowBytes, int x, int y, int mode) {
        if (mode == 15) {
            // bp16：系统 ProRes RAW 解码器的输出。
            //
            // 单平面、16-bit little-endian、**每个 sensel 一个样本**，
            // 也就是说根本不需要解包——这正是绕开 btp2 私有打包的意义。
            // 高 12 位是有效值，与 ffmpeg 的 bayer_rggb16le 同构，
            // 所以后面的扣黑、白平衡、矩阵全部可以照用。
            const device ushort* line = (const device ushort*)(base + uint(y) * rowBytes);
            return ushort(line[x] >> 4);
        }
        const device uchar* row = base + uint(y) * rowBytes;

        if (mode == 0) {
            int g = x >> 3, k = x & 7;
            const device uchar* blk = row + uint(g) * 12u;
            uint lo = uint(blk[8 + (k >> 1)]);
            uint nib = ((k & 1) == 0) ? (lo >> 4) : (lo & 0x0Fu);
            return ushort((uint(blk[k]) << 4) | nib);
        }
        if (mode == 1) {
            int g = x >> 3, k = x & 7;
            const device uchar* blk = row + uint(g) * 12u;
            uint lo = uint(blk[8 + (k >> 1)]);
            uint nib = ((k & 1) == 0) ? (lo & 0x0Fu) : (lo >> 4);
            return ushort((uint(blk[k]) << 4) | nib);
        }
        if (mode == 2 || mode == 3 || mode == 4 || mode == 5) {
            int g = x >> 1;
            const device uchar* blk = row + uint(g) * 3u;
            uint b0 = uint(blk[0]), b1 = uint(blk[1]), b2 = uint(blk[2]);
            bool even = (x & 1) == 0;
            if (mode == 2) { return ushort(even ? ((b0 << 4) | (b1 >> 4)) : (((b1 & 0x0Fu) << 8) | b2)); }
            if (mode == 3) { return ushort(even ? ((b0 << 4) | (b2 >> 4)) : (((b2 & 0x0Fu) << 8) | b1)); }
            if (mode == 4) { return ushort(even ? (b0 | ((b1 & 0x0Fu) << 8)) : ((b1 >> 4) | (b2 << 4))); }
            return ushort(even ? (b0 | ((b2 & 0x0Fu) << 8)) : ((b2 >> 4) | (b1 << 4)));
        }
        if (mode == 6) {
            int g = x >> 2, k = x & 3;
            const device uchar* blk = row + uint(g) * 6u;
            uint lo = uint(blk[4 + (k >> 1)]);
            uint nib = ((k & 1) == 0) ? (lo >> 4) : (lo & 0x0Fu);
            return ushort((uint(blk[k]) << 4) | nib);
        }
        if (mode == 7) {
            int g = x >> 2, k = x & 3;
            const device uchar* blk = row + uint(g) * 6u;
            uint lo = uint(blk[k >> 1]);
            uint nib = ((k & 1) == 0) ? (lo >> 4) : (lo & 0x0Fu);
            return ushort((uint(blk[2 + k]) << 4) | nib);
        }
        if (mode == 8) {
            int g = x >> 3, k = x & 7;
            const device uchar* blk = row + uint(g) * 12u;
            uint lo = uint(blk[k >> 1]);
            uint nib = ((k & 1) == 0) ? (lo >> 4) : (lo & 0x0Fu);
            return ushort((uint(blk[4 + k]) << 4) | nib);
        }
        {
            // 9 / 10：2 像素 3 字节，前两个字节各做一个像素的高 8 位，
            // 第三个字节装两个低 4 位。
            int g = x >> 1;
            const device uchar* blk = row + uint(g) * 3u;
            uint b0 = uint(blk[0]), b1 = uint(blk[1]), b2 = uint(blk[2]);
            bool even = (x & 1) == 0;
            if (mode == 9) {
                return ushort(even ? ((b0 << 4) | (b2 >> 4)) : ((b1 << 4) | (b2 & 0x0Fu)));
            }
            return ushort(even ? ((b0 << 4) | (b2 & 0x0Fu)) : ((b1 << 4) | (b2 >> 4)));
        }
    }

    /// 传感器原生 RGB → BT.709 线性。
    ///
    /// 传感器给出的三通道是「相机原生空间」，不是 BT.709。缺这一步，
    /// 等于把相机空间的数值直接当 BT.709 播出去，色相整体旋转——这正是
    /// 反复调相位、调增益都修不好的原因：偏色不在那一层。
    ///
    /// 两个矩阵合并成一次乘法：
    ///   camera → CIE XYZ D65（取自 ProRes RAW 帧头，Apple 对这颗传感器的标定）
    ///   XYZ → BT.709 线性（D65 白点，标准矩阵）
    /// 三个行向量之和都是 1，所以中性灰进出不变，矩阵本身不会引入偏色。
    ///
    /// 数值在 4224×3024 的真实帧上验过：白墙保持暖白、木桌为暖棕，
    /// 与 Apple 相机同场景的观感一致。
    constant float3 kCamToRec709_0 = float3(0.8086f, 0.0994f, 0.0920f);
    constant float3 kCamToRec709_1 = float3(-0.0810f, 1.0462f, 0.0349f);
    constant float3 kCamToRec709_2 = float3(0.0342f, -0.3193f, 1.2852f);

    inline float ac_rec709(float v) {
        v = clamp(v, 0.0f, 1.0f);
        return (v < 0.018f) ? (4.5f * v) : (1.099f * pow(v, 0.45f) - 0.099f);
    }

    inline int ac_color_at(int pattern, int phase) {
        if (pattern == 0) {          // RGGB
            const int t[4] = {0, 1, 1, 2};
            return t[phase];
        } else if (pattern == 1) {   // BGGR
            const int t[4] = {2, 1, 1, 0};
            return t[phase];
        } else if (pattern == 2) {   // GRBG
            const int t[4] = {1, 0, 2, 1};
            return t[phase];
        }
        const int t[4] = {1, 2, 0, 1};   // GBRG
        return t[phase];
    }

    /// 双线性 demosaic → 扣黑 → 白平衡 → REC.709 传递函数。返回 0..1 的 RGB。
    inline float3 ac_pixel(const device uchar* src, uint rowBytes, int w, int h,
                           int x, int y, int pattern, int mode,
                           float black, float invRange, float3 gains) {
        int xm = ac_clamp(x - 1, 0, w - 1);
        int xp = ac_clamp(x + 1, 0, w - 1);
        int ym = ac_clamp(y - 1, 0, h - 1);
        int yp = ac_clamp(y + 1, 0, h - 1);

        float c  = float(ac_raw12(src, rowBytes, x,  y,  mode));
        float l  = float(ac_raw12(src, rowBytes, xm, y,  mode));
        float r  = float(ac_raw12(src, rowBytes, xp, y,  mode));
        float u  = float(ac_raw12(src, rowBytes, x,  ym, mode));
        float d  = float(ac_raw12(src, rowBytes, x,  yp, mode));
        float ul = float(ac_raw12(src, rowBytes, xm, ym, mode));
        float ur = float(ac_raw12(src, rowBytes, xp, ym, mode));
        float dl = float(ac_raw12(src, rowBytes, xm, yp, mode));
        float dr = float(ac_raw12(src, rowBytes, xp, yp, mode));

        int phase = (x & 1) | ((y & 1) << 1);
        int color = ac_color_at(pattern, phase);

        float R = 0.0f;
        float G = 0.0f;
        float B = 0.0f;
        if (color == 1) {
            G = c;
            int horiz = ac_color_at(pattern, phase ^ 1);
            if (horiz == 0) {
                R = 0.5f * (l + r);
                B = 0.5f * (u + d);
            } else {
                B = 0.5f * (l + r);
                R = 0.5f * (u + d);
            }
        } else if (color == 0) {
            R = c;
            G = 0.25f * (l + r + u + d);
            B = 0.25f * (ul + ur + dl + dr);
        } else {
            B = c;
            G = 0.25f * (l + r + u + d);
            R = 0.25f * (ul + ur + dl + dr);
        }

        float3 linear = float3((R - black) * invRange,
                               (G - black) * invRange,
                               (B - black) * invRange);
        // 扣黑之后先只挡负数，不做上限截断：截到 1 会把高光里的
        // 相对比例削平（谁先到 1 谁先丢），矩阵也就无从把它拉回来。
        linear = max(linear, float3(0.0f)) * gains;
        float3 rgb = float3(dot(linear, kCamToRec709_0),
                            dot(linear, kCamToRec709_1),
                            dot(linear, kCamToRec709_2));
        rgb = clamp(rgb, 0.0f, 1.0f);
        // 高光滚降 + 阴影提升，再进 REC.709 传递函数。
        //
        // 线性直出会瘫在暗部：本机桌面这条片子的线性中位数只有 0.039，
        // 白色鼠标出来是灰的。系统预览走 ISP 的 S 曲线，所以预览正常、
        // 成片发暗——「HEVC 变亮度」说的就是这一层。
        //
        // 膝点 0.25 是在官方解码的真实帧上标出来的，不是估的：
        //   中位亮度 41 → 91，白鼠标回到白；p95 108 → 167；
        //   p99 仍留 226，高光不削顶（纯线性直出时 p99 已经 247）。
        // Reinhard 对亮度自适应，暗场景提得多、亮场景提得少，不需要按场景换参数。
        //
        // 但必须**只对亮度施加，三通道同步缩放**。
        // 早先写成 rgb / (rgb + 0.25) 对每个通道各自施加，通道值越大压得越狠，
        // 比例于是被重排：紫色 (0.35,0.20,0.45) 会变成 (0.58,0.44,0.64)，
        // R/G 从 1.75 掉到 1.32、B/G 从 2.25 掉到 1.45——饱和度掉四分之一，
        // 色相也跟着偏。表现为「通道比全是 1.00 但画面发灰发闷」：
        // 白平衡把均值拉平了，掩盖了每个像素比例已经被改写的事实。
        float luma = dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
        float mapped = luma / (luma + 0.25f);
        float scale = (luma > 1e-5f) ? (mapped / luma) : 0.0f;
        float3 tone = rgb * scale;

        // 缩放后可能越过 1。按峰值整体压回来，保持三通道比例——
        // 逐通道 clamp 会把高光重新去饱和，等于把上面修的问题又引回来一次。
        float peak = max(tone.r, max(tone.g, tone.b));
        if (peak > 1.0f) {
            tone /= peak;
        }
        tone = max(tone, float3(0.0f));
        return float3(ac_rec709(tone.r), ac_rec709(tone.g), ac_rec709(tone.b));
    }

    kernel void bayer_to_bgra(const device uchar* src [[buffer(0)]],
                              texture2d<float, access::write> dst [[texture(0)]],
                              constant uint* p [[buffer(3)]],
                              device uint* probe [[buffer(4)]],
                              uint2 gid [[thread_position_in_grid]]) {
        uint w = p[0];
        uint h = p[1];
        uint rowBytes = p[2];
        float black = as_type<float>(p[4]);
        float white = as_type<float>(p[5]);
        float3 gains = float3(as_type<float>(p[6]), as_type<float>(p[7]), as_type<float>(p[8]));
        int pattern = int(p[9]);
        int mode = int(p[10]);

        int x0 = int(gid.x) * 2;
        int y0 = int(gid.y) * 2;
        if (x0 >= int(w) || y0 >= int(h)) { return; }

        float invRange = 1.0f / max(white - black, 1.0f);
        int x1 = min(x0 + 1, int(w) - 1);
        int y1 = min(y0 + 1, int(h) - 1);

        float3 e0 = ac_pixel(src, rowBytes, int(w), int(h), x0, y0, pattern, mode, black, invRange, gains);
        float3 e1 = ac_pixel(src, rowBytes, int(w), int(h), x1, y0, pattern, mode, black, invRange, gains);
        float3 e2 = ac_pixel(src, rowBytes, int(w), int(h), x0, y1, pattern, mode, black, invRange, gains);
        float3 e3 = ac_pixel(src, rowBytes, int(w), int(h), x1, y1, pattern, mode, black, invRange, gains);

        if (gid.x == 0u && gid.y == 0u) {
            probe[0] = 1u;
            probe[1] = w;
            probe[2] = h;
            probe[3] = rowBytes;
            probe[4] = uint(clamp(e0.r, 0.0f, 1.0f) * 1000.0f);
            probe[5] = uint(clamp(e0.g, 0.0f, 1.0f) * 1000.0f);
            probe[6] = uint(clamp(e0.b, 0.0f, 1.0f) * 1000.0f);
        }

        // BGRA8Unorm：写 0..1 就是 0..255，没有位深与范围这一层歧义
        dst.write(float4(e0, 1.0f), uint2(uint(x0), uint(y0)));
        dst.write(float4(e1, 1.0f), uint2(uint(x1), uint(y0)));
        dst.write(float4(e2, 1.0f), uint2(uint(x0), uint(y1)));
        dst.write(float4(e3, 1.0f), uint2(uint(x1), uint(y1)));
    }
    """#
}
