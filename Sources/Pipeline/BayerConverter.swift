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
            [
                "gpu=\(kernelRan ? 1 : 0)",
                "size=\(kernelWidth)x\(kernelHeight)",
                "rgb_min=\(outMin[0]),\(outMin[1]),\(outMin[2])",
                "rgb_max=\(outMax[0]),\(outMax[1]),\(outMax[2])",
                "rgb_mean=\(outMean[0]),\(outMean[1]),\(outMean[2])",
                "first=\(firstPixel)",
                "raw=\(rawRange)",
                "head=\(rawHead)",
                "cal=\(calibration)",
            ].joined(separator: ";")
        }
    }

    static let bayerFormat: OSType = FourCC.code("btp2")
    static let outputFormat: OSType = kCVPixelFormatType_32BGRA
    /// 供外部（写入端）判断该走哪条追加路径
    static var isBayer(_ format: OSType) -> Bool { format == bayerFormat }

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

        guard CVPixelBufferGetPixelFormatType(source) == Self.bayerFormat else {
            lastFailureStage = "源不是 btp2"
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

        // 前 24 字节的十六进制：万一打包方式与假设不符，这 8 组三字节
        // 足够在 PC 上把两种排法各算一遍，一次定死。
        var headText = ""
        let headPointer = sourceBase.assumingMemoryBound(to: UInt8.self)
        for index in 0..<min(24, sourceLength) {
            headText += String(format: "%02x", headPointer[index])
        }

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
                preferredPattern: parameters.pattern
            )
        }

        memcpy(bayerBuffer.contents(), sourceBase, sourceLength)

        // ---- 参数：扁平 uint32，下标即协议 ----
        let floats = [parameters.blackLevel, parameters.whiteLevel,
                      parameters.redGain, parameters.greenGain, parameters.blueGain]
        var slots = [UInt32](repeating: 0, count: 11)
        slots[0] = UInt32(width)
        slots[1] = UInt32(height)
        slots[2] = UInt32(sourceRowBytes)
        slots[3] = 0
        for (index, value) in floats.enumerated() {
            slots[4 + index] = value.bitPattern
        }
        slots[9] = UInt32(bitPattern: calibration?.pattern ?? parameters.pattern)
        slots[10] = UInt32(bitPattern: calibration?.unpackMode ?? 0)
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

    // 12-bit 打包：两个像素三字节
    //   mode 0（MIPI 标准）：p0 = (b0<<4)|(b1>>4)      p1 = ((b1&0x0F)<<8)|b2
    //   mode 1（低位在前）  ：p0 = b0|((b1&0x0F)<<8)   p1 = (b1>>4)|(b2<<4)
    //   mode 2（首字节合装）：p0 = ((b0&0xF0)<<4)|b1   p1 = ((b0&0x0F)<<8)|b2
    inline ushort ac_raw12(const device uchar* base, uint rowBytes, int x, int y, int mode) {
        const device uchar* q = base + uint(y) * rowBytes + uint(x >> 1) * 3u;
        if (mode == 0) {
            if ((x & 1) == 0) {
                return ushort((ushort(q[0]) << 4) | (ushort(q[1]) >> 4));
            }
            return ushort((ushort(q[1] & 0x0F) << 8) | ushort(q[2]));
        }
        if (mode == 1) {
            if ((x & 1) == 0) {
                return ushort(ushort(q[0]) | (ushort(q[1] & 0x0F) << 8));
            }
            return ushort((ushort(q[1]) >> 4) | (ushort(q[2]) << 4));
        }
        if ((x & 1) == 0) {
            return ushort((ushort(q[0] & 0xF0) << 4) | ushort(q[1]));
        }
        return ushort((ushort(q[0] & 0x0F) << 8) | ushort(q[2]));
    }

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
                           int x, int y, int pattern,
                           float black, float invRange, float3 gains, int unpackMode) {
        int xm = ac_clamp(x - 1, 0, w - 1);
        int xp = ac_clamp(x + 1, 0, w - 1);
        int ym = ac_clamp(y - 1, 0, h - 1);
        int yp = ac_clamp(y + 1, 0, h - 1);

        float c  = float(ac_raw12(src, rowBytes, x,  y,  unpackMode));
        float l  = float(ac_raw12(src, rowBytes, xm, y,  unpackMode));
        float r  = float(ac_raw12(src, rowBytes, xp, y,  unpackMode));
        float u  = float(ac_raw12(src, rowBytes, x,  ym, unpackMode));
        float d  = float(ac_raw12(src, rowBytes, x,  yp, unpackMode));
        float ul = float(ac_raw12(src, rowBytes, xm, ym, unpackMode));
        float ur = float(ac_raw12(src, rowBytes, xp, ym, unpackMode));
        float dl = float(ac_raw12(src, rowBytes, xm, yp, unpackMode));
        float dr = float(ac_raw12(src, rowBytes, xp, yp, unpackMode));

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

        float3 linear = clamp(float3((R - black) * invRange,
                                     (G - black) * invRange,
                                     (B - black) * invRange), 0.0f, 1.0f);
        linear = clamp(linear * gains, 0.0f, 1.0f);
        return float3(ac_rec709(linear.r), ac_rec709(linear.g), ac_rec709(linear.b));
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
        int unpackMode = int(p[10]);

        int x0 = int(gid.x) * 2;
        int y0 = int(gid.y) * 2;
        if (x0 >= int(w) || y0 >= int(h)) { return; }

        float invRange = 1.0f / max(white - black, 1.0f);
        int x1 = min(x0 + 1, int(w) - 1);
        int y1 = min(y0 + 1, int(h) - 1);

        float3 e0 = ac_pixel(src, rowBytes, int(w), int(h), x0, y0, pattern, black, invRange, gains, unpackMode);
        float3 e1 = ac_pixel(src, rowBytes, int(w), int(h), x1, y0, pattern, black, invRange, gains, unpackMode);
        float3 e2 = ac_pixel(src, rowBytes, int(w), int(h), x0, y1, pattern, black, invRange, gains, unpackMode);
        float3 e3 = ac_pixel(src, rowBytes, int(w), int(h), x1, y1, pattern, black, invRange, gains, unpackMode);

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
