import Foundation
import CoreMedia

/// MOV 容器标记注入：写 `colr`（nclc）与 `logs` 私有标识。
///
/// AVAssetWriter 不会写 `colr` atom，Apple Log 2 也没有标准 nclc 编码，
/// 所以这两项只能在文件写完之后直接改字节。PC 端的 `tools/movtag.py`
/// 用同一套算法，两边产出必须逐字节一致，否则同一段素材在两端会被
/// NLE 解释成不同的色彩空间。
///
/// 做法：重建视频 sample entry（去掉旧 colr/logs，追加新的），
/// 再逐级回填祖先 box 的 size；若 `mdat` 在插入点之后，同步修正
/// `stco` / `co64` 的每个 chunk offset。
enum MovTag {

    struct Result {
        var primaries = 9
        var transfer = 2
        var matrix = 9
        var delta = 0
        var chunksShifted = 0
    }

    enum TagError: LocalizedError {
        case noMoov
        case noVideoEntry
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noMoov: return "文件里没有 moov"
            case .noVideoEntry: return "没有找到 hvc1 视频轨"
            case .writeFailed(let detail): return "写回文件失败：\(detail)"
            }
        }
    }

    /// 读出当前的标记，用于验证和诊断
    static func describe(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        var out: [String: Any] = ["size": data.count]
        let bytes = [UInt8](data)
        guard let entry = pickVideoEntry(bytes),
              let kids = boxes(bytes, entry.offset + entry.header + 78, entry.offset + entry.size) else {
            return out
        }
        for kid in kids {
            let body = bytes[(kid.offset + kid.header)..<(kid.offset + kid.size)]
            if kid.type == "colr", body.count >= 10, Array(body.prefix(4)) == Array("nclc".utf8) {
                out["primaries"] = Int(body[4]) << 8 | Int(body[5])
                out["transfer"] = Int(body[6]) << 8 | Int(body[7])
                out["matrix"] = Int(body[8]) << 8 | Int(body[9])
            } else if kid.type == "logs" {
                out["logs"] = String(decoding: body.dropLast(), as: UTF8.self)
            }
        }
        return out
    }

    /// 注入标记。原地改写，成功返回变更摘要。
    @discardableResult
    static func inject(_ url: URL,
                       primaries: Int = 9,
                       transfer: Int = 2,
                       matrix: Int = 9,
                       logID: String = "com.apple.rec2020.apple-log") throws -> Result {

        var bytes = [UInt8](try Data(contentsOf: url))
        guard let moov = boxes(bytes, 0, bytes.count)?.first(where: { $0.type == "moov" }) else {
            throw TagError.noMoov
        }
        guard let entry = pickVideoEntry(bytes) else { throw TagError.noVideoEntry }

        let stsd = entry.stsd
        let fixedHeader = bytes[(entry.offset + entry.header)..<(entry.offset + entry.header + 78)]

        // 保留原有子 box（丢掉旧 colr/logs），末尾追加新的
        var kidsData = Data()
        if let kids = boxes(bytes, entry.offset + entry.header + 78, entry.offset + entry.size) {
            for kid in kids where kid.type != "colr" && kid.type != "logs" {
                kidsData.append(contentsOf: bytes[kid.offset..<(kid.offset + kid.size)])
            }
        }
        kidsData.append(makeColr(primaries: primaries, transfer: transfer, matrix: matrix))
        kidsData.append(makeLogs(logID))

        // 重建 entry
        var entryBody = Data(fixedHeader)
        entryBody.append(kidsData)
        var newEntry = Data()
        newEntry.append(be32(UInt32(8 + entryBody.count)))
        newEntry.append(contentsOf: Array("hvc1".utf8))
        newEntry.append(entryBody)

        // 重建 stsd：替换目标 entry，保留其余
        var entries = Data()
        if let list = boxes(bytes, stsd.offset + stsd.header + 8, stsd.offset + stsd.size) {
            for e in list {
                if e.offset == entry.offset {
                    entries.append(newEntry)
                } else {
                    entries.append(contentsOf: bytes[e.offset..<(e.offset + e.size)])
                }
            }
        }
        var stsdHead = Data(bytes[stsd.offset..<(stsd.offset + stsd.header + 8)])
        var newStsd = Data()
        newStsd.append(be32(UInt32(stsdHead.count + entries.count)))
        newStsd.append(contentsOf: bytes[(stsd.offset + 4)..<(stsd.offset + 8)])   // type
        newStsd.append(stsdHead.dropFirst(stsd.header))                            // verflags + count
        newStsd.append(entries)

        let delta = newStsd.count - stsd.size
        bytes.replaceSubrange(stsd.offset..<(stsd.offset + stsd.size), with: newStsd)

        // 逐级回填祖先 size
        // chain 末尾是 stsd 本身，它的 size 已经在 newStsd 里写好了，
        // 再加一次会把长度算重；只回填它的祖先。
        for node in entry.chain.dropLast() {
            setSize(&bytes, node, node.size + delta)
        }
        setSize(&bytes, moov, moov.size + delta)

        // mdat 在 stsd 之后 → 修正 chunk offset
        var shifted = 0
        if delta != 0 {
            shifted = shiftChunks(&bytes, threshold: stsd.offset, delta: delta)
        }

        do {
            try Data(bytes).write(to: url, options: .atomic)
        } catch {
            throw TagError.writeFailed(error.localizedDescription)
        }
        return Result(primaries: primaries, transfer: transfer, matrix: matrix,
                      delta: delta, chunksShifted: shifted)
    }

    // MARK: - box 解析

    private struct Node {
        var type: String
        var offset: Int
        var size: Int
        var header: Int
    }

    private struct Entry {
        var offset: Int
        var size: Int
        var header: Int
        var chain: [Node]       // stsd 及其祖先，从外到内
        var stsd: Node
    }

    private static func boxes(_ bytes: [UInt8], _ start: Int, _ end: Int) -> [Node]? {
        var result: [Node] = []
        var i = start
        while i + 8 <= end {
            let size32 = Int(be32(bytes, i))
            let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
            var size = size32
            var header = 8
            if size32 == 1 {
                guard i + 16 <= end else { break }
                size = Int(be64(bytes, i + 8))
                header = 16
            } else if size32 == 0 {
                size = end - i
            }
            guard size >= header, i + size <= end else { break }
            result.append(Node(type: type, offset: i, size: size, header: header))
            i += size
        }
        return result
    }

    private static func pickVideoEntry(_ bytes: [UInt8]) -> Entry? {
        guard let top = boxes(bytes, 0, bytes.count),
              let moov = top.first(where: { $0.type == "moov" }),
              let traks = boxes(bytes, moov.offset + moov.header, moov.offset + moov.size) else {
            return nil
        }
        for trak in traks where trak.type == "trak" {
            var chain: [Node] = [trak]
            var cursor = trak
            var found = true
            for want in ["mdia", "minf", "stbl", "stsd"] {
                guard let list = boxes(bytes, cursor.offset + cursor.header, cursor.offset + cursor.size),
                      let next = list.first(where: { $0.type == want }) else {
                    found = false; break
                }
                chain.append(next)
                cursor = next
            }
            guard found else { continue }
            let stsd = cursor
            guard let entries = boxes(bytes, stsd.offset + stsd.header + 8, stsd.offset + stsd.size) else {
                continue
            }
            if let entry = entries.first(where: { $0.type == "hvc1" || $0.type == "hev1" }) {
                return Entry(offset: entry.offset, size: entry.size, header: entry.header,
                             chain: chain, stsd: stsd)
            }
        }
        return nil
    }

    private static func shiftChunks(_ bytes: inout [UInt8], threshold: Int, delta: Int) -> Int {
        guard let top = boxes(bytes, 0, bytes.count),
              let moov = top.first(where: { $0.type == "moov" }),
              let traks = boxes(bytes, moov.offset + moov.header, moov.offset + moov.size) else {
            return 0
        }
        var count = 0
        for trak in traks where trak.type == "trak" {
            var cursor = trak
            var ok = true
            for want in ["mdia", "minf", "stbl"] {
                guard let list = boxes(bytes, cursor.offset + cursor.header, cursor.offset + cursor.size),
                      let next = list.first(where: { $0.type == want }) else { ok = false; break }
                cursor = next
            }
            guard ok,
                  let kids = boxes(bytes, cursor.offset + cursor.header, cursor.offset + cursor.size) else { continue }
            for kid in kids where kid.type == "stco" || kid.type == "co64" {
                let base = kid.offset + kid.header + 4
                let n = Int(be32(bytes, base - 4))
                let width = kid.type == "stco" ? 4 : 8
                for k in 0..<n {
                    let p = base + width * k
                    let value = width == 4 ? Int(be32(bytes, p)) : Int(be64(bytes, p))
                    guard value >= threshold else { continue }
                    if width == 4 {
                        writeBE32(&bytes, p, UInt32(value + delta))
                    } else {
                        writeBE64(&bytes, p, UInt64(value + delta))
                    }
                    count += 1
                }
            }
        }
        return count
    }

    // MARK: - 构造

    private static func makeColr(primaries: Int, transfer: Int, matrix: Int) -> Data {
        var d = Data()
        d.append(be32(18))
        d.append(contentsOf: Array("colr".utf8))
        d.append(contentsOf: Array("nclc".utf8))
        d.append(be16(UInt16(primaries)))
        d.append(be16(UInt16(transfer)))
        d.append(be16(UInt16(matrix)))
        return d
    }

    private static func makeLogs(_ identifier: String) -> Data {
        var payload = Data(identifier.utf8)
        payload.append(0)
        var d = Data()
        d.append(be32(UInt32(8 + payload.count)))
        d.append(contentsOf: Array("logs".utf8))
        d.append(payload)
        return d
    }

    // MARK: - 字节序

    private static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        (UInt32(bytes[at]) << 24) | (UInt32(bytes[at + 1]) << 16)
            | (UInt32(bytes[at + 2]) << 8) | UInt32(bytes[at + 3])
    }

    private static func be64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(bytes[at + i]) }
        return v
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
              UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    private static func be16(_ value: UInt16) -> Data {
        Data([UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    private static func writeBE32(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        bytes[at] = UInt8((value >> 24) & 0xff)
        bytes[at + 1] = UInt8((value >> 16) & 0xff)
        bytes[at + 2] = UInt8((value >> 8) & 0xff)
        bytes[at + 3] = UInt8(value & 0xff)
    }

    private static func writeBE64(_ bytes: inout [UInt8], _ at: Int, _ value: UInt64) {
        for i in 0..<8 {
            bytes[at + i] = UInt8((value >> (8 * (7 - i))) & 0xff)
        }
    }

    private static func setSize(_ bytes: inout [UInt8], _ node: Node, _ size: Int) {
        if node.header == 16 {
            writeBE32(&bytes, node.offset, 1)
            writeBE64(&bytes, node.offset + 8, UInt64(size))
        } else {
            writeBE32(&bytes, node.offset, UInt32(size))
        }
    }
}
