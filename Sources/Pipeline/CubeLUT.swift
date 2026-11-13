import Foundation
import CoreImage

/// `.cube` 3D LUT 的解析与应用。
///
/// 只支持最常见的 3D 形式（`LUT_3D_SIZE n`）。1D LUT 是另一套语义
/// （逐通道曲线），混进来会让结果不可预期，这里直接拒收并给出原因。
///
/// 数据顺序：`.cube` 与 `CIColorCube` 都是 **R 变化最快**，
/// 所以解析结果可以原样喂给 CoreImage，不需要重排。
struct CubeLUT {

    let title: String
    let size: Int
    /// RGBA float32，长度 size³ × 4，可直接作为 CIColorCube 的 inputCubeData
    let cubeData: Data

    enum LUTError: LocalizedError {
        case unreadable(String)
        case not3D
        case badSize(Int)
        case badDomain
        case countMismatch(expected: Int, got: Int)
        case badLine(Int, String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let d): return "读不了这个文件：\(d)"
            case .not3D: return "这是 1D LUT，只支持 3D（LUT_3D_SIZE）"
            case .badSize(let n): return "LUT_3D_SIZE 不合法：\(n)"
            case .badDomain: return "DOMAIN_MIN/MAX 不是 0–1，暂不支持"
            case .countMismatch(let e, let g): return "条目数不符，应为 \(e) 行，实际 \(g) 行"
            case .badLine(let n, let t): return "第 \(n) 行不是三个数：\(t)"
            }
        }
    }

    /// 解析。文件大小通常在几十 KB 到几 MB。
    static func load(from url: URL) throws -> CubeLUT {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // 有些 .cube 存成 UTF-16 或带 BOM
            if let alt = try? String(contentsOf: url, encoding: .utf16) {
                text = alt
            } else {
                throw LUTError.unreadable(error.localizedDescription)
            }
        }

        var title = url.deletingPathExtension().lastPathComponent
        var size = 0
        var domainMin = SIMD3<Float>(0, 0, 0)
        var domainMax = SIMD3<Float>(1, 1, 1)
        var entries: [SIMD3<Float>] = []

        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }

            let upper = line.uppercased()
            if upper.hasPrefix("TITLE") {
                if let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last {
                    title = String(line[line.index(after: first)..<last])
                }
                continue
            }
            if upper.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if parts.count >= 2, let n = Int(parts[1]) { size = n }
                continue
            }
            if upper.hasPrefix("LUT_1D_SIZE") {
                throw LUTError.not3D
            }
            if upper.hasPrefix("DOMAIN_MIN") || upper.hasPrefix("DOMAIN_MAX") {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Float($0) }
                if parts.count >= 3 {
                    let v = SIMD3<Float>(parts[0], parts[1], parts[2])
                    if upper.hasPrefix("DOMAIN_MIN") { domainMin = v } else { domainMax = v }
                }
                continue
            }

            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count < 3 {
                throw LUTError.badLine(index + 1, line)
            }
            guard let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else {
                throw LUTError.badLine(index + 1, line)
            }
            entries.append(SIMD3<Float>(r, g, b))
        }

        guard size > 1, size <= 128 else { throw LUTError.badSize(size) }
        // CoreImage 只接受 0–1 的归一化域。带偏移的 LUT 先拒收，
        // 免得画面出来一半被截断还不知道为什么。
        guard domainMin == SIMD3<Float>(0, 0, 0), domainMax == SIMD3<Float>(1, 1, 1) else {
            throw LUTError.badDomain
        }
        let expected = size * size * size
        guard entries.count == expected else {
            throw LUTError.countMismatch(expected: expected, got: entries.count)
        }

        var rgba = [Float](repeating: 1, count: expected * 4)
        for i in 0..<expected {
            rgba[i * 4 + 0] = entries[i].x
            rgba[i * 4 + 1] = entries[i].y
            rgba[i * 4 + 2] = entries[i].z
            rgba[i * 4 + 3] = 1
        }

        return CubeLUT(title: title, size: size,
                       cubeData: rgba.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// 中性轴（R=G=B）在给定输入下的输出 PQ 码值。
    ///
    /// `.cube` 是 R 变化最快，所以 (v,v,v) 落在 i·N² + i·N + i。
    /// 用来读 LUT 自己的白点：不同版本的同名 LUT，100% 白可能是
    /// 136 nits 也可能是 157 nits，写死一个常数必然偏。
    func neutralOutput(at v: Float) -> Float {
        let n = size
        let i = min(max(Int((v * Float(n - 1)).rounded()), 0), n - 1)
        let scalar = (i * n * n + i * n + i) * 4
        return cubeData.withUnsafeBytes { raw in
            raw.load(fromByteOffset: scalar * MemoryLayout<Float>.size, as: Float.self)
        }
    }

    /// 建一个可复用的 CIColorCube。转码循环里每帧调用它即可。
    func makeFilter() -> CIFilter? {
        guard let filter = CIFilter(name: "CIColorCube") else { return nil }
        filter.setValue(size, forKey: "inputCubeDimension")
        filter.setValue(cubeData, forKey: "inputCubeData")
        return filter
    }
}

/// 已安装 LUT 的存放位置与选择状态。
///
/// 只保留一份"当前 LUT"：素材处理是一次性的，堆一堆 LUT 反而要管理。
/// 换 LUT 就是覆盖这一个文件。
enum LUTStore {

    static var directory: URL {
        let base = MovieRecorder.recordingDirectory().deletingLastPathComponent()
        return base.appendingPathComponent("LUTs", isDirectory: true)
    }

    static var currentURL: URL {
        directory.appendingPathComponent("current.cube")
    }

    static var currentName: String? {
        UserDefaults.standard.string(forKey: "lut.currentName")
    }

    /// 默认开启：装了 LUT 就是要用，不该让用户再点一次。
    /// 只有显式关过（UserDefaults 有值且为 false）才关。
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "lut.enabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "lut.enabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "lut.enabled") }
    }

    /// 导入：先解析校验，通过才落盘。解析失败不留垃圾文件。
    @discardableResult
    static func install(from url: URL) throws -> CubeLUT {
        let lut = try CubeLUT.load(from: url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: currentURL.path) {
            try? FileManager.default.removeItem(at: currentURL)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: url, to: currentURL)
        UserDefaults.standard.set(lut.title, forKey: "lut.currentName")
        return lut
    }

    /// 转码时取用。没装或没开就返回 nil，管线直通。
    static func activeLUT() -> CubeLUT? {
        guard isEnabled, currentName != nil,
              FileManager.default.fileExists(atPath: currentURL.path) else { return nil }
        return try? CubeLUT.load(from: currentURL)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: currentURL)
        UserDefaults.standard.removeObject(forKey: "lut.currentName")
        UserDefaults.standard.set(false, forKey: "lut.enabled")
    }
}
