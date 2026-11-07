import Foundation
import CoreVideo
import CoreMedia
import Metal

/// btp2（Bayer 12-bit 打包）→ 10-bit YCbCr 的 GPU 转换。
///
/// 为什么必须有这一层：4224×3024 这个全幅格式在 `AVCaptureVideoDataOutput` 上
/// **只暴露 Bayer**，没有任何 YUV 输出（探针实测 availableVideoPixelFormatTypes
/// 只有 btp2）。Bayer 数据不能直接喂给 HEVC / ProRes 编码器，`append` 会被逐帧
/// 拒绝——表现就是「计时在走、文件 0 字节、波形图不出」。
///
/// 着色器在**运行时**编译（`makeLibrary(source:)`）而不是编成 .metal：
/// 着色器写错只会让转换器初始化失败、走降级通路，不会把整个 App 编挂。
final class BayerConverter {

    /// 与着色器里的 `Params` 一一对应。全部 4 字节成员，无隐式内边距。
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

    static let bayerFormat: OSType = FourCC.code("btp2")

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    private var sourceBuffer: MTLBuffer?
    private var sourceCapacity = 0
    private var yPlaneBuffer: MTLBuffer?
    private var cPlaneBuffer: MTLBuffer?
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
    }

    // MARK: - 转换

    /// 最近一次失败发生在哪一步。全幅链路出问题时，这句话直接显示在界面上，
    /// 不用再靠猜是哪一环。
    private(set) var lastFailureStage: String?

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

        var params = parameters
        params.width = UInt32(width)
        params.height = UInt32(height)
        params.sourceBytesPerRow = UInt32(sourceRowBytes)
        params.chroma422 = chroma422 ? 1 : 0

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
        encoder.setBytes(&params, length: MemoryLayout<Parameters>.stride, index: 3)

        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: (width + 1) / 2, height: (height + 1) / 2, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.status == .completed else {
            lastFailureStage = "GPU 未完成（\(commandBuffer.status.rawValue)）"
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
        // 之前是把平面指针直接包成 MTLBuffer 让 GPU 写（bytesNoCopy 要求页对齐），
        // 对齐不满足时整条链路静默返回 nil——现在只依赖 memcpy。
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

    struct Params {
        float blackLevel;
        float whiteLevel;
        float redGain;
        float greenGain;
        float blueGain;
        int pattern;
        uint width;
        uint height;
        uint sourceBytesPerRow;
        int chroma422;
    };

    inline int ac_clamp(int v, int lo, int hi) {
        return v < lo ? lo : (v > hi ? hi : v);
    }

    // MIPI RAW12：两个像素打包进 3 字节
    //   p0 = (b0 << 4) | (b1 >> 4)
    //   p1 = ((b1 & 0x0F) << 8) | b2
    inline ushort ac_raw12(const device uchar* base, uint rowBytes, int x, int y) {
        const device uchar* p = base + uint(y) * rowBytes + uint(x >> 1) * 3u;
        if ((x & 1) == 0) {
            return ushort((ushort(p[0]) << 4) | (ushort(p[1]) >> 4));
        }
        return ushort((ushort(p[1] & 0x0F) << 8) | ushort(p[2]));
    }

    inline float ac_rec709(float v) {
        v = clamp(v, 0.0f, 1.0f);
        return (v < 0.018f) ? (4.5f * v) : (1.099f * pow(v, 0.45f) - 0.099f);
    }

    kernel void bayer_to_yuv(const device uchar* src [[buffer(0)]],
                             device ushort* yPlane [[buffer(1)]],
                             device ushort* cPlane [[buffer(2)]],
                             constant Params& p [[buffer(3)]],
                             uint2 gid [[thread_position_in_grid]]) {
        int w = int(p.width);
        int h = int(p.height);
        int x0 = int(gid.x) * 2;
        int y0 = int(gid.y) * 2;
        if (x0 >= w || y0 >= h) { return; }

        // 每个相位分别是什么颜色：0=R 1=G 2=B
        const int colors[16] = {
            0, 1, 1, 2,   // RGGB
            2, 1, 1, 0,   // BGGR
            1, 0, 2, 1,   // GRBG
            1, 2, 0, 1    // GBRG
        };

        float invRange = 1.0f / max(p.whiteLevel - p.blackLevel, 1.0f);
        float3 gains = float3(p.redGain, p.greenGain, p.blueGain);

        float encR[4];
        float encG[4];
        float encB[4];

        for (int k = 0; k < 4; k++) {
            int x = min(x0 + (k & 1), w - 1);
            int y = min(y0 + (k >> 1), h - 1);

            int xm = ac_clamp(x - 1, 0, w - 1);
            int xp = ac_clamp(x + 1, 0, w - 1);
            int ym = ac_clamp(y - 1, 0, h - 1);
            int yp = ac_clamp(y + 1, 0, h - 1);

            float c  = float(ac_raw12(src, p.sourceBytesPerRow, x,  y));
            float l  = float(ac_raw12(src, p.sourceBytesPerRow, xm, y));
            float r  = float(ac_raw12(src, p.sourceBytesPerRow, xp, y));
            float u  = float(ac_raw12(src, p.sourceBytesPerRow, x,  ym));
            float d  = float(ac_raw12(src, p.sourceBytesPerRow, x,  yp));
            float ul = float(ac_raw12(src, p.sourceBytesPerRow, xm, ym));
            float ur = float(ac_raw12(src, p.sourceBytesPerRow, xp, ym));
            float dl = float(ac_raw12(src, p.sourceBytesPerRow, xm, yp));
            float dr = float(ac_raw12(src, p.sourceBytesPerRow, xp, yp));

            int phase = (x & 1) | ((y & 1) << 1);
            int color = colors[p.pattern * 4 + phase];

            float R, G, B;
            if (color == 1) {
                G = c;
                int horizontal = colors[p.pattern * 4 + (phase ^ 1)];
                if (horizontal == 0) {
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

            float3 linear = clamp(float3((R - p.blackLevel) * invRange,
                                         (G - p.blackLevel) * invRange,
                                         (B - p.blackLevel) * invRange), 0.0f, 1.0f);
            linear = clamp(linear * gains, 0.0f, 1.0f);

            float3 enc = float3(ac_rec709(linear.r), ac_rec709(linear.g), ac_rec709(linear.b));
            float Y = dot(enc, float3(0.2126f, 0.7152f, 0.0722f));

            yPlane[uint(y) * p.width + uint(x)] = ushort(clamp(64.0f + Y * 876.0f, 64.0f, 940.0f));

            encR[k] = enc.r;
            encG[k] = enc.g;
            encB[k] = enc.b;
        }

        if (p.chroma422 == 1) {
            for (int k = 0; k < 4; k++) {
                int x = min(x0 + (k & 1), w - 1);
                int y = min(y0 + (k >> 1), h - 1);
                float Y = 0.2126f * encR[k] + 0.7152f * encG[k] + 0.0722f * encB[k];
                float cb = (encB[k] - Y) / 1.8556f;
                float cr = (encR[k] - Y) / 1.5748f;
                uint index = (uint(y) * p.width + uint(x)) * 2u;
                cPlane[index] = ushort(clamp(512.0f + cb * 896.0f, 64.0f, 960.0f));
                cPlane[index + 1] = ushort(clamp(512.0f + cr * 896.0f, 64.0f, 960.0f));
            }
        } else {
            float3 average = float3(
                (encR[0] + encR[1] + encR[2] + encR[3]) * 0.25f,
                (encG[0] + encG[1] + encG[2] + encG[3]) * 0.25f,
                (encB[0] + encB[1] + encB[2] + encB[3]) * 0.25f
            );
            float Y = 0.2126f * average.r + 0.7152f * average.g + 0.0722f * average.b;
            float cb = (average.b - Y) / 1.8556f;
            float cr = (average.r - Y) / 1.5748f;

            uint chromaWidth = p.width / 2u;
            uint index = ((uint(y0) / 2u) * chromaWidth + (uint(x0) / 2u)) * 2u;
            cPlane[index] = ushort(clamp(512.0f + cb * 896.0f, 64.0f, 960.0f));
            cPlane[index + 1] = ushort(clamp(512.0f + cr * 896.0f, 64.0f, 960.0f));
        }
    }
    """#
}
