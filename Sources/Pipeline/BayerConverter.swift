import Foundation
import CoreVideo
import CoreMedia
import Metal

/// btp2（Bayer 12-bit 打包）→ 10-bit YCbCr 的 GPU 转换。
///
/// 这条链路唯一可靠的写法是**直接写进输出像素缓冲的纹理**：
/// 早先是 GPU 写自有 MTLBuffer、再逐行 memcpy 回 CVPixelBuffer，
/// 结果编码器收到的缓冲始终是全 0（成片纯绿），而 GPU 侧明明有数据。
/// 现在把平面包成 `texture2d<write>` 让 kernel 直接落盘，
/// 中间不再有任何一块“可能没复制过去”的内存。
///
/// 参数用扁平 uint32 缓冲传：结构体一旦布局判断错，kernel 读到的 width 就是 0，
/// 所有线程立刻 return，命令缓冲却显示 completed。
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
        var width: UInt32 = 0
        var height: UInt32 = 0
        var sourceBytesPerRow: UInt32 = 0
        /// 0 = 4:2:0（HEVC）  1 = 4:2:2（ProRes）
        var chroma422: Int32 = 0
    }

    /// 一次转换的自检结果。真机上直接读数，不用猜。
    struct Diagnostics {
        var kernelRan = false
        var kernelWidth: UInt32 = 0
        var kernelHeight: UInt32 = 0
        /// 写完之后，从**输出像素缓冲**上读回来的 Y 极值（10-bit）
        var cvYMin: UInt32 = 0
        var cvYMax: UInt32 = 0

        var isBlack: Bool { cvYMax < 32 }
        var summary: String {
            "GPU \(kernelRan ? "1" : "0") · \(kernelWidth)×\(kernelHeight) · CV[\(cvYMin),\(cvYMax)]"
        }
    }

    static let bayerFormat: OSType = FourCC.code("btp2")

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

    /// 纹理引用必须在 GPU 跑完之前一直活着，否则底层表面可能被回收
    private var yTextureRef: CVMetalTexture?
    private var cTextureRef: CVMetalTexture?

    /// 构造失败的原因，显示在设置页
    private(set) static var compileNote: String?

    /// 初始化失败即代表这台设备走不了 Bayer 通路，调用方应降级到系统 ISP 格式。
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }

        do {
            let options = MTLCompileOptions()
            let library = try device.makeLibrary(source: Self.shaderSource, options: options)
            guard let function = library.makeFunction(name: "bayer_to_yuv") else {
                Self.compileNote = "找不到 bayer_to_yuv"
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

    private(set) var lastFailureStage: String?
    private(set) var lastDiagnostics = Diagnostics()

    func convert(
        _ source: CVPixelBuffer,
        chroma422: Bool,
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

        // x422 的 CV 常量在 iOS SDK 上并不总是存在，统一用四字符码拼
        let format = chroma422
            ? FourCC.code("x422")
            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

        guard let output = pooledBuffer(format: format, width: width, height: height) else {
            lastFailureStage = "输出像素缓冲创建失败"
            return nil
        }
        guard let cache = textureCache else {
            lastFailureStage = "纹理缓存缺失"
            return nil
        }

        let chromaWidth = width / 2
        let chromaHeight = chroma422 ? height : height / 2

        var yCVTexture: CVMetalTexture?
        var cCVTexture: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, output, nil,
            MTLPixelFormat.r16Unorm, width, height, 0, &yCVTexture
        )
        let cStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, output, nil,
            MTLPixelFormat.rg16Unorm, chromaWidth, chromaHeight, 1, &cCVTexture
        )
        guard yStatus == kCVReturnSuccess, cStatus == kCVReturnSuccess,
              let yCVTexture = yCVTexture, let cCVTexture = cCVTexture,
              let yTexture = CVMetalTextureGetTexture(yCVTexture),
              let cTexture = CVMetalTextureGetTexture(cCVTexture)
        else {
            lastFailureStage = "纹理创建失败（Y \(yStatus) / C \(cStatus)）"
            return nil
        }
        yTextureRef = yCVTexture
        cTextureRef = cCVTexture

        // ---- 源：Bayer 没有对应像素格式，只能拷进 MTLBuffer ----
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        guard let sourceBase = CVPixelBufferGetBaseAddress(source) else {
            lastFailureStage = "源地址不可读"
            return nil
        }
        let sourceRowBytes = CVPixelBufferGetBytesPerRow(source)
        let sourceLength = sourceRowBytes * height

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
        memcpy(bayerBuffer.contents(), sourceBase, sourceLength)

        // ---- 参数：扁平 uint32，下标即协议 ----
        let floats = [parameters.blackLevel, parameters.whiteLevel,
                      parameters.redGain, parameters.greenGain, parameters.blueGain]
        var slots = [UInt32](repeating: 0, count: 10)
        slots[0] = UInt32(width)
        slots[1] = UInt32(height)
        slots[2] = UInt32(sourceRowBytes)
        slots[3] = chroma422 ? 1 : 0
        for (index, value) in floats.enumerated() {
            slots[4 + index] = value.bitPattern
        }
        slots[9] = UInt32(bitPattern: parameters.pattern)
        slots.withUnsafeBytes { memcpy(paramsBuffer.contents(), $0.baseAddress, 40) }
        memset(probeBuffer.contents(), 0, 32)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            lastFailureStage = "命令队列失败"
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(bayerBuffer, offset: 0, index: 0)
        encoder.setTexture(yTexture, index: 0)
        encoder.setTexture(cTexture, index: 1)
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

        guard commandBuffer.status == .completed else {
            lastFailureStage = "GPU 未完成（\(commandBuffer.status.rawValue)）"
            return nil
        }

        let probe = probeBuffer.contents().bindMemory(to: UInt32.self, capacity: 8)
        var diagnostics = Diagnostics()
        diagnostics.kernelRan = probe[0] == 1
        diagnostics.kernelWidth = probe[1]
        diagnostics.kernelHeight = probe[2]

        // 纹理引用用完即放，并清一次纹理缓存，避免缓存无限增长
        yTextureRef = nil
        cTextureRef = nil
        CVMetalTextureCacheFlush(cache, 0)

        // ---- 从输出像素缓冲上直接读回来：这一步是唯一可信的验收 ----
        CVPixelBufferLockBaseAddress(output, .readOnly)
        if let plane = CVPixelBufferGetBaseAddressOfPlane(output, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
            var minValue = UInt32.max
            var maxValue: UInt32 = 0
            var row = 0
            while row < height {
                let rowPointer = plane.advanced(by: row * stride)
                    .assumingMemoryBound(to: UInt16.self)
                var column = 0
                while column < width {
                    let value = UInt32(rowPointer[column])
                    if value < minValue { minValue = value }
                    if value > maxValue { maxValue = value }
                    column += 97
                }
                row += 97
            }
            diagnostics.cvYMin = minValue == UInt32.max ? 0 : minValue
            diagnostics.cvYMax = maxValue
        }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)

        lastDiagnostics = diagnostics

        if !diagnostics.kernelRan {
            lastFailureStage = "kernel 未执行（probe 为 0）"
            return nil
        }
        if diagnostics.isBlack {
            lastFailureStage = "输出全黑（CV Y≤\(diagnostics.cvYMax)）"
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
            guard status == kCVReturnSuccess, let created = pool else { return nil }
            pools[format] = created
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

    // MIPI RAW12：两个像素打包进 3 字节
    //   p0 = (b0 << 4) | (b1 >> 4)
    //   p1 = ((b1 & 0x0F) << 8) | b2
    inline ushort ac_raw12(const device uchar* base, uint rowBytes, int x, int y) {
        const device uchar* q = base + uint(y) * rowBytes + uint(x >> 1) * 3u;
        if ((x & 1) == 0) {
            return ushort((ushort(q[0]) << 4) | (ushort(q[1]) >> 4));
        }
        return ushort((ushort(q[1] & 0x0F) << 8) | ushort(q[2]));
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

    inline float3 ac_pixel(const device uchar* src, uint rowBytes, int w, int h,
                           int x, int y, int pattern,
                           float black, float invRange, float3 gains) {
        int xm = ac_clamp(x - 1, 0, w - 1);
        int xp = ac_clamp(x + 1, 0, w - 1);
        int ym = ac_clamp(y - 1, 0, h - 1);
        int yp = ac_clamp(y + 1, 0, h - 1);

        float c  = float(ac_raw12(src, rowBytes, x,  y));
        float l  = float(ac_raw12(src, rowBytes, xm, y));
        float r  = float(ac_raw12(src, rowBytes, xp, y));
        float u  = float(ac_raw12(src, rowBytes, x,  ym));
        float d  = float(ac_raw12(src, rowBytes, x,  yp));
        float ul = float(ac_raw12(src, rowBytes, xm, ym));
        float ur = float(ac_raw12(src, rowBytes, xp, ym));
        float dl = float(ac_raw12(src, rowBytes, xm, yp));
        float dr = float(ac_raw12(src, rowBytes, xp, yp));

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

    kernel void bayer_to_yuv(const device uchar* src [[buffer(0)]],
                             texture2d<float, access::write> yTex [[texture(0)]],
                             texture2d<float, access::write> cTex [[texture(1)]],
                             constant uint* p [[buffer(3)]],
                             device uint* probe [[buffer(4)]],
                             uint2 gid [[thread_position_in_grid]]) {
        uint w = p[0];
        uint h = p[1];
        uint rowBytes = p[2];
        int chroma422 = int(p[3]);
        float black = as_type<float>(p[4]);
        float white = as_type<float>(p[5]);
        float3 gains = float3(as_type<float>(p[6]), as_type<float>(p[7]), as_type<float>(p[8]));
        int pattern = int(p[9]);

        if (gid.x == 0u && gid.y == 0u) {
            probe[0] = 1u;
            probe[1] = w;
            probe[2] = h;
            probe[3] = rowBytes;
        }

        int x0 = int(gid.x) * 2;
        int y0 = int(gid.y) * 2;
        if (x0 >= int(w) || y0 >= int(h)) { return; }

        float invRange = 1.0f / max(white - black, 1.0f);
        int x1 = min(x0 + 1, int(w) - 1);
        int y1 = min(y0 + 1, int(h) - 1);

        float3 e0 = ac_pixel(src, rowBytes, int(w), int(h), x0, y0, pattern, black, invRange, gains);
        float3 e1 = ac_pixel(src, rowBytes, int(w), int(h), x1, y0, pattern, black, invRange, gains);
        float3 e2 = ac_pixel(src, rowBytes, int(w), int(h), x0, y1, pattern, black, invRange, gains);
        float3 e3 = ac_pixel(src, rowBytes, int(w), int(h), x1, y1, pattern, black, invRange, gains);

        // 10-bit 存在 16-bit 容器的高 10 位：写 unorm 时按 /1023 归一，
        // 硬件量化后正好落到 value << 6。
        const float invCode = 1.0f / 1023.0f;
        float3 lumaWeights = float3(0.2126f, 0.7152f, 0.0722f);

        yTex.write(float4(dot(e0, lumaWeights) * invCode, 0.0f, 0.0f, 1.0f), uint2(uint(x0), uint(y0)));
        yTex.write(float4(dot(e1, lumaWeights) * invCode, 0.0f, 0.0f, 1.0f), uint2(uint(x1), uint(y0)));
        yTex.write(float4(dot(e2, lumaWeights) * invCode, 0.0f, 0.0f, 1.0f), uint2(uint(x0), uint(y1)));
        yTex.write(float4(dot(e3, lumaWeights) * invCode, 0.0f, 0.0f, 1.0f), uint2(uint(x1), uint(y1)));

        // 色度：BT.709 的 Cb/Cr，视频范围 64..960，中性 512
        if (chroma422 == 1) {
            float3 pairTop = (e0 + e1) * 0.5f;
            float3 pairBottom = (e2 + e3) * 0.5f;

            float yT = dot(pairTop, lumaWeights);
            float cbT = (pairTop.b - yT) / 1.8556f;
            float crT = (pairTop.r - yT) / 1.5748f;
            cTex.write(float4((512.0f + cbT * 896.0f) * invCode,
                              (512.0f + crT * 896.0f) * invCode, 0.0f, 1.0f),
                       uint2(uint(x0) / 2u, uint(y0)));

            float yB = dot(pairBottom, lumaWeights);
            float cbB = (pairBottom.b - yB) / 1.8556f;
            float crB = (pairBottom.r - yB) / 1.5748f;
            cTex.write(float4((512.0f + cbB * 896.0f) * invCode,
                              (512.0f + crB * 896.0f) * invCode, 0.0f, 1.0f),
                       uint2(uint(x0) / 2u, uint(y1)));
        } else {
            float3 average = (e0 + e1 + e2 + e3) * 0.25f;
            float yv = dot(average, lumaWeights);
            float cb = (average.b - yv) / 1.8556f;
            float cr = (average.r - yv) / 1.5748f;
            cTex.write(float4((512.0f + cb * 896.0f) * invCode,
                              (512.0f + cr * 896.0f) * invCode, 0.0f, 1.0f),
                       uint2(uint(x0) / 2u, uint(y0) / 2u));
        }
    }
    """#
}
