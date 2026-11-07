import Foundation
import CoreVideo
import CoreMedia
import Metal

/// btp2（Bayer 12-bit 打包）→ 10-bit YCbCr 的 GPU 转换。
///
/// 为什么必须有这一层：4224×3024 这个全幅格式在 `AVCaptureVideoDataOutput` 上
/// **只暴露 Bayer**，没有任何 YUV 输出（探针实测 availableVideoPixelFormatTypes
/// 只有 btp2）。Bayer 不能直接喂给 HEVC / ProRes 编码器。
///
/// 参数用**扁平 uint32 缓冲**传，不用结构体：结构体一旦有一处对齐/布局判断错，
/// kernel 读到的 width 就是 0，所有线程立刻 return，而命令缓冲仍然显示 completed——
/// 成片就是一片绿。扁平数组没有布局歧义，同时把 kernel 看到的值回读出来做探针。
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
        /// kernel 是否真的进来了（probe[0] == 1）
        var kernelRan = false
        /// kernel 读到的 width / height / rowBytes
        var kernelWidth: UInt32 = 0
        var kernelHeight: UInt32 = 0
        var kernelRowBytes: UInt32 = 0
        /// 写出后 Y 平面的最小/最大值（10-bit）
        var yMin: UInt32 = 0
        var yMax: UInt32 = 0

        var isBlack: Bool { yMax < 32 }
        var summary: String {
            "GPU \(kernelRan ? "1" : "0") · \(kernelWidth)×\(kernelHeight) · Y[\(yMin),\(yMax)]"
        }
    }

    static let bayerFormat: OSType = FourCC.code("btp2")

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    private var sourceBuffer: MTLBuffer?
    private var sourceCapacity = 0
    private var yPlaneBuffer: MTLBuffer?
    private var cPlaneBuffer: MTLBuffer?
    private var paramsBuffer: MTLBuffer?
    private var probeBuffer: MTLBuffer?
    private var pools: [OSType: CVPixelBufferPool] = [:]
    private var poolWidth = 0
    private var poolHeight = 0

    /// 初始化失败即代表这台设备走不了 Bayer 通路，调用方应降级到系统 ISP 格式。
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }

        do {
            let options = MTLCompileOptions()
            let library = try device.makeLibrary(source: Self.shaderSource, options: options)
            guard let function = library.makeFunction(name: "bayer_to_yuv") else { return nil }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            return nil
        }

        self.device = device
        self.queue = queue
        self.paramsBuffer = device.makeBuffer(length: 64, options: .storageModeShared)
        self.probeBuffer = device.makeBuffer(length: 64, options: .storageModeShared)
        guard paramsBuffer != nil, probeBuffer != nil else { return nil }
    }

    // MARK: - 转换

    /// 最近一次失败发生在哪一步
    private(set) var lastFailureStage: String?
    /// 最近一次转换的自检数据
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
        guard let bayerBuffer = sourceBuffer else {
            lastFailureStage = "源缓冲缺失"
            return nil
        }
        memcpy(bayerBuffer.contents(), sourceBase, sourceLength)

        // x422 的 CV 常量在 iOS SDK 上并不总是存在，统一用四字符码拼
        let format = chroma422
            ? FourCC.code("x422")
            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

        guard let yBuffer = outputBuffer(&yPlaneBuffer, bytes: width * height * 2),
              let cBuffer = outputBuffer(&cPlaneBuffer, bytes: (chroma422 ? width * height : width * height / 2) * 2)
        else {
            lastFailureStage = "输出缓冲分配失败"
            return nil
        }

        // ---- 参数：扁平 uint32，下标即协议 ----
        guard let paramsBuffer = paramsBuffer, let probeBuffer = probeBuffer else {
            lastFailureStage = "参数缓冲缺失"
            return nil
        }
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
        memcpy(paramsBuffer.contents(), slots, 40)
        memset(probeBuffer.contents(), 0, 32)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            lastFailureStage = "命令队列失败"
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(bayerBuffer, offset: 0, index: 0)
        encoder.setBuffer(yBuffer, offset: 0, index: 1)
        encoder.setBuffer(cBuffer, offset: 0, index: 2)
        encoder.setBuffer(paramsBuffer, offset: 0, index: 3)
        encoder.setBuffer(probeBuffer, offset: 0, index: 4)

        // 每个线程处理 2×2 个像素；用固定 16×16 线程组 + 线程组数派发，
        // 不用 dispatchThreads（那个接口对超大网格的行为在真机上不好排查）。
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

        // ---- 自检：kernel 到底进没进来、看到的是多大 ----
        let probe = probeBuffer.contents().bindMemory(to: UInt32.self, capacity: 8)
        var diagnostics = Diagnostics()
        diagnostics.kernelRan = probe[0] == 1
        diagnostics.kernelWidth = probe[1]
        diagnostics.kernelHeight = probe[2]
        diagnostics.kernelRowBytes = probe[3]

        // 稀疏采样求 Y 的极值：全量扫 1277 万样本只为了看有没有画面，没有必要
        let ySamples = yBuffer.contents().bindMemory(to: UInt16.self, capacity: width * height)
        var minValue = UInt32.max
        var maxValue: UInt32 = 0
        var index = 0
        let total = width * height
        while index < total {
            let value = UInt32(ySamples[index])
            if value < minValue { minValue = value }
            if value > maxValue { maxValue = value }
            index += 509
        }
        diagnostics.yMin = minValue == UInt32.max ? 0 : minValue
        diagnostics.yMax = maxValue
        lastDiagnostics = diagnostics

        if !diagnostics.kernelRan {
            lastFailureStage = "kernel 未执行（probe 为 0）"
            return nil
        }
        if diagnostics.isBlack {
            lastFailureStage = "输出全黑（Y≤\(diagnostics.yMax)）"
            return nil
        }

        guard let output = pooledBuffer(format: format, width: width, height: height) else {
            lastFailureStage = "输出像素缓冲创建失败"
            return nil
        }

        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(output, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(output, 1)
        else {
            lastFailureStage = "输出平面不可写"
            return nil
        }

        // 逐行回写：平面 stride 可以大于紧排字节数，按行搬最稳。
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
        let yRowBytes = width * 2
        let ySource = yBuffer.contents()
        for row in 0..<height {
            memcpy(yBase + row * yStride, ySource + row * yRowBytes, yRowBytes)
        }

        let chromaHeight = chroma422 ? height : height / 2
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
        let cRowBytes = (chroma422 ? width : width / 2) * 4
        let cSource = cBuffer.contents()
        for row in 0..<chromaHeight {
            memcpy(cBase + row * cStride, cSource + row * cRowBytes, cRowBytes)
        }

        return output
    }

    // MARK: - 缓冲

    private func outputBuffer(_ cache: inout MTLBuffer?, bytes: Int) -> MTLBuffer? {
        if let existing = cache, existing.length >= bytes { return existing }
        guard let created = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            return nil
        }
        cache = created
        return created
    }

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

        // 池这条路不通就直接建一个：池失败通常只是属性问题，
        // 没必要因此让整条全幅链路瘫掉。
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

    // 每个相位是什么颜色：0=R 1=G 2=B
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
                             device ushort* yPlane [[buffer(1)]],
                             device ushort* cPlane [[buffer(2)]],
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

        ushort y0v = ushort(clamp(64.0f + dot(e0, float3(0.2126f, 0.7152f, 0.0722f)) * 876.0f, 64.0f, 940.0f));
        ushort y1v = ushort(clamp(64.0f + dot(e1, float3(0.2126f, 0.7152f, 0.0722f)) * 876.0f, 64.0f, 940.0f));
        ushort y2v = ushort(clamp(64.0f + dot(e2, float3(0.2126f, 0.7152f, 0.0722f)) * 876.0f, 64.0f, 940.0f));
        ushort y3v = ushort(clamp(64.0f + dot(e3, float3(0.2126f, 0.7152f, 0.0722f)) * 876.0f, 64.0f, 940.0f));

        yPlane[uint(y0) * w + uint(x0)] = y0v;
        yPlane[uint(y0) * w + uint(x1)] = y1v;
        yPlane[uint(y1) * w + uint(x0)] = y2v;
        yPlane[uint(y1) * w + uint(x1)] = y3v;

        if (chroma422 == 1) {
            float3 list0 = e0;
            float3 list1 = e1;
            float3 list2 = e2;
            float3 list3 = e3;
            float yv0 = dot(list0, float3(0.2126f, 0.7152f, 0.0722f));
            float yv1 = dot(list1, float3(0.2126f, 0.7152f, 0.0722f));
            float yv2 = dot(list2, float3(0.2126f, 0.7152f, 0.0722f));
            float yv3 = dot(list3, float3(0.2126f, 0.7152f, 0.0722f));

            uint i0 = (uint(y0) * w + uint(x0)) * 2u;
            uint i1 = (uint(y0) * w + uint(x1)) * 2u;
            uint i2 = (uint(y1) * w + uint(x0)) * 2u;
            uint i3 = (uint(y1) * w + uint(x1)) * 2u;

            cPlane[i0] = ushort(clamp(512.0f + (list0.b - yv0) / 1.8556f * 896.0f, 64.0f, 960.0f));
            cPlane[i0 + 1] = ushort(clamp(512.0f + (list0.r - yv0) / 1.5748f * 896.0f, 64.0f, 960.0f));
            cPlane[i1] = ushort(clamp(512.0f + (list1.b - yv1) / 1.8556f * 896.0f, 64.0f, 960.0f));
            cPlane[i1 + 1] = ushort(clamp(512.0f + (list1.r - yv1) / 1.5748f * 896.0f, 64.0f, 960.0f));
            cPlane[i2] = ushort(clamp(512.0f + (list2.b - yv2) / 1.8556f * 896.0f, 64.0f, 960.0f));
            cPlane[i2 + 1] = ushort(clamp(512.0f + (list2.r - yv2) / 1.5748f * 896.0f, 64.0f, 960.0f));
            cPlane[i3] = ushort(clamp(512.0f + (list3.b - yv3) / 1.8556f * 896.0f, 64.0f, 960.0f));
            cPlane[i3 + 1] = ushort(clamp(512.0f + (list3.r - yv3) / 1.5748f * 896.0f, 64.0f, 960.0f));
        } else {
            float3 average = (e0 + e1 + e2 + e3) * 0.25f;
            float yv = dot(average, float3(0.2126f, 0.7152f, 0.0722f));
            uint chromaWidth = w / 2u;
            uint index = ((uint(y0) / 2u) * chromaWidth + (uint(x0) / 2u)) * 2u;
            cPlane[index] = ushort(clamp(512.0f + (average.b - yv) / 1.8556f * 896.0f, 64.0f, 960.0f));
            cPlane[index + 1] = ushort(clamp(512.0f + (average.r - yv) / 1.5748f * 896.0f, 64.0f, 960.0f));
        }
    }
    """#
}
