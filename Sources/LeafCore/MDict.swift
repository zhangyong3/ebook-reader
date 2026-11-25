import Foundation
import CoreFoundation

/// Native MDX/MDD v2 reader. Keeps mapped compressed data and indexes; inflates only the requested record blocks.
public final class MDict {
    private struct Key { let word: String; let start: Int }
    private struct Block { let offset: Int; let compressed: Int; let start: Int; let size: Int }
    private let data: Data
    private var keys: [Key] = []
    private var lookupIndex: [String: [Int]] = [:]
    private var blocks: [Block] = []
    private var cache: (index: Int, data: Data)?
    private let encoding: String.Encoding
    private let unit: Int
    private let caseSensitive: Bool
    public let title: String
    public let isResource: Bool
    public var entryCount: Int { keys.count }

    public init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        var reader = ByteReader(data: data)
        let length = try reader.int(4)
        guard length <= 4 * 1024 * 1024 else { throw LeafError.invalid("词典头部长度不合法。") }
        let headerData = try reader.bytes(length)
        guard adler(headerData) == (try reader.number(4, little: true)) else { throw LeafError.invalid("词典头部校验失败。") }
        let header = String(data: headerData, encoding: .utf16LittleEndian) ?? ""
        func attribute(_ name: String) -> String { header.matches(pattern: "\(name)\\s*=\\s*[\"']([^\"']*)[\"']").first ?? "" }
        let version = Double(attribute("GeneratedByEngineVersion")) ?? 0
        guard version >= 2, version < 3 else { throw LeafError.invalid("首版支持 MDX/MDD 2.x；该词典版本为 \(version)。") }
        let encryptedText = attribute("Encrypted")
        let encrypted = Int(encryptedText) ?? (encryptedText.lowercased() == "yes" ? 1 : 0)
        guard encrypted & 1 == 0 else { throw LeafError.invalid("此词典需要注册密码，暂不支持。") }
        // Many MDX builders set Compact/Compat even when entries are ordinary HTML.
        // Only a nonempty StyleSheet denotes a template that needs expansion.
        let compact = [attribute("Compact"), attribute("Compat")].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes" }
        let stylesheet = attribute("StyleSheet").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact || stylesheet.isEmpty else { throw LeafError.invalid("此词库包含非空 Compact 样式模板，暂不支持展开。") }
        isResource = url.pathExtension.lowercased() == "mdd"
        let codec = attribute("Encoding").uppercased().replacingOccurrences(of: "-", with: "")
        if isResource || codec == "UTF16" { encoding = .utf16LittleEndian; unit = 2 }
        else if codec == "GBK" || codec == "GB18030" || codec == "GB2312" { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))); unit = 1 }
        else if codec == "BIG5" { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))); unit = 1 }
        else if codec == "UTF8" || codec.isEmpty { encoding = .utf8; unit = 1 }
        else { throw LeafError.invalid("不支持的词库编码：\(codec)") }
        title = attribute("Title").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).nonempty ?? url.deletingPathExtension().lastPathComponent
        caseSensitive = attribute("KeyCaseSensitive").lowercased() == "yes"
        let headerStart = reader.offset
        let keyBlockCount = try reader.int(8), keyCount = try reader.int(8)
        let infoSize = try reader.int(8), compressedInfoSize = try reader.int(8), keyBytes = try reader.int(8)
        guard keyBlockCount <= 1_000_000, keyCount <= 10_000_000, infoSize <= 128 * 1024 * 1024 else { throw LeafError.invalid("词库索引超出支持范围。") }
        let headerChecksum = try reader.number(4)
        guard adler(data.subdata(in: headerStart..<(headerStart+40))) == headerChecksum else { throw LeafError.invalid("词库索引头校验失败。") }
        var packedInfo = try reader.bytes(compressedInfoSize)
        if encrypted & 2 != 0 {
            guard packedInfo.count >= 8 else { throw LeafError.invalid("加密索引不完整。") }
            let key = RIPEMD128.hash(packedInfo.subdata(in: 4..<8) + Data([0x95,0x36,0,0]))
            var previous: UInt8 = 0x36
            for index in 8..<packedInfo.count {
                let current = packedInfo[index]
                packedInfo[index] = ((current >> 4) | (current << 4)) ^ previous ^ UInt8(truncatingIfNeeded: index-8) ^ key[(index-8)%16]
                previous = current
            }
        }
        var info = ByteReader(data: try Self.unpack(packedInfo, size: infoSize))
        guard keyBytes <= reader.remaining else { throw LeafError.invalid("词库关键字区长度不合法。") }
        let keysEnd = reader.offset + keyBytes
        for _ in 0..<keyBlockCount {
            _ = try info.int(8)
            let first = try info.int(2); _ = try info.bytes((first+1)*unit)
            let last = try info.int(2); _ = try info.bytes((last+1)*unit)
            let compressed = try info.int(8), size = try info.int(8)
            var part = ByteReader(data: try Self.unpack(reader.bytes(compressed), size: size))
            while part.remaining > 0 {
                let start = try part.int(8)
                let word = try readString(&part)
                guard keys.count < keyCount else { throw LeafError.invalid("词库词条数量不符。") }
                let index = keys.count; keys.append(Key(word: word, start: start))
                lookupIndex[normalize(word), default: []].append(index)
            }
        }
        guard reader.offset == keysEnd, keys.count == keyCount else { throw LeafError.invalid("词库关键字索引不完整。") }
        let recordCount = try reader.int(8), recordEntries = try reader.int(8), recordInfoSize = try reader.int(8), recordBytes = try reader.int(8)
        guard recordCount <= 1_000_000, recordInfoSize == recordCount * 16, recordEntries == keyCount else { throw LeafError.invalid("词库正文索引不合法。") }
        var packedOffset = reader.offset + recordInfoSize, expandedOffset = 0
        for _ in 0..<recordCount {
            let compressed = try reader.int(8), size = try reader.int(8)
            guard compressed <= data.count - packedOffset, size <= 128 * 1024 * 1024, expandedOffset <= Int.max - size else { throw LeafError.invalid("词库数据块长度不合法。") }
            blocks.append(Block(offset: packedOffset, compressed: compressed, start: expandedOffset, size: size))
            packedOffset += compressed; expandedOffset += size
        }
        guard packedOffset - reader.offset == recordBytes, keys.allSatisfy({ $0.start <= expandedOffset }), zip(keys, keys.dropFirst()).allSatisfy({ $0.start <= $1.start }) else { throw LeafError.invalid("词库正文位置不合法。") }
    }
    private func normalize(_ word: String) -> String {
        let key = word.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
        return caseSensitive && !isResource ? key : key.lowercased()
    }
    private func readString(_ reader: inout ByteReader) throws -> String {
        let start = reader.offset
        while reader.remaining >= unit {
            let chunk = try reader.bytes(unit)
            if chunk.allSatisfy({ $0 == 0 }) {
                let content = reader.data.subdata(in: start..<(reader.offset-unit))
                guard let string = String(data: content, encoding: encoding) else { throw LeafError.invalid("词条编码与词库声明不符。") }
                return string
            }
        }
        throw LeafError.invalid("词条末尾缺少终止符。")
    }
    private static func unpack(_ data: Data, size: Int) throws -> Data {
        var reader = ByteReader(data: data)
        let type = try reader.int(4, little: true), checksum = try reader.number(4)
        let payload = try reader.bytes(reader.remaining)
        let result: Data
        switch type {
        case 0: result = payload
        case 2: result = try inflateData(payload, expected: size)
        case 1: result = try LZO.decompress(payload, expected: size)
        default: throw LeafError.invalid("无法识别词库压缩方式。")
        }
        guard result.count == size, adler(result) == checksum else { throw LeafError.invalid("词库数据校验失败。") }; return result
    }
    public func resource(_ word: String) throws -> Data? {
        var query = normalize(word)
        if isResource, !query.hasPrefix("/") { query = "/" + query }
        guard let index = lookupIndex[query]?.first else { return nil }
        return try record(index)
    }
    public func lookup(_ word: String) throws -> String? {
        var query = word.trimmingCharacters(in: .whitespacesAndNewlines); var visited = Set<String>()
        for _ in 0..<12 {
            guard visited.insert(normalize(query)).inserted else { throw LeafError.invalid("词条跳转出现循环。") }
            guard let index = lookupIndex[normalize(query)]?.first else { return nil }
            guard let string = String(data: try record(index), encoding: encoding) else { throw LeafError.invalid("词条内容编码错误。") }
            let text = string.trimmingCharacters(in: .controlCharacters)
            if text.hasPrefix("@@@LINK=") { query = String(text.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines); continue }
            return text
        }
        throw LeafError.invalid("词条跳转层数过多。")
    }
    private func record(_ index: Int) throws -> Data {
        let start = keys[index].start
        let end = index+1 < keys.count ? keys[index+1].start : (blocks.last.map { $0.start+$0.size } ?? start)
        guard end >= start, end-start <= 32 * 1024 * 1024 else { throw LeafError.invalid("单个词条内容过大。") }
        var output = Data()
        for (i, block) in blocks.enumerated() where block.start < end && block.start+block.size > start {
            let expanded: Data
            if cache?.index == i { expanded = cache!.data }
            else {
                expanded = try Self.unpack(data.subdata(in: block.offset..<(block.offset+block.compressed)), size: block.size)
                cache = (i, expanded)
            }
            let lower = max(start,block.start)-block.start, upper = min(end,block.start+block.size)-block.start
            output.append(expanded.subdata(in: lower..<upper))
        }
        guard output.count == end-start else { throw LeafError.invalid("词条正文不完整。") }; return output
    }
}
