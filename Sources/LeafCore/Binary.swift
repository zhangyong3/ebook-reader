import Foundation
import CZlib

struct ByteReader {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset >= 0, count <= remaining else { throw LeafError.invalid("文件内容不完整或长度不合法。") }
        defer { offset += count }; return data.subdata(in: offset..<(offset + count))
    }
    mutating func number(_ count: Int, little: Bool = false) throws -> UInt64 {
        guard (1...8).contains(count) else { throw LeafError.invalid("不支持的数值长度。") }
        let raw = try bytes(count)
        return (little ? Array(raw.reversed()) : Array(raw)).reduce(0) { ($0 << 8) | UInt64($1) }
    }
    mutating func int(_ count: Int, little: Bool = false) throws -> Int {
        let n = try number(count, little: little)
        guard n <= Int.max else { throw LeafError.invalid("文件尺寸超出限制。") }; return Int(n)
    }
}

func inflateData(_ data: Data, expected: Int, raw: Bool = false) throws -> Data {
    guard expected >= 0, expected <= 128 * 1024 * 1024 else { throw LeafError.invalid("单个资源超过 128 MB 限制。") }
    var output = Data(count: max(expected, 1))
    var stream = z_stream()
    guard inflateInit2_(&stream, raw ? -MAX_WBITS : MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw LeafError.invalid("无法初始化解压器。") }
    defer { inflateEnd(&stream) }
    let capacity = output.count
    let status: Int32 = output.withUnsafeMutableBytes { out in
        data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(capacity)
            return inflate(&stream, Z_FINISH)
        }
    }
    guard status == Z_STREAM_END, stream.total_out == expected else { throw LeafError.invalid("压缩资源损坏或长度不符。") }
    output.count = expected; return output
}

func adler(_ data: Data) -> UInt32 {
    data.withUnsafeBytes { UInt32(adler32(1, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
}
