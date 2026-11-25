import Foundation
import CryptoKit
import CZlib

/// Reads the ZIP directory before writing anything; refuses traversal, symlinks, encryption, and oversized entries.
struct EPUBArchive {
    struct Entry { let name: String; let method: Int; let compressed: Int; let size: Int; let offset: Int; let crc: UInt32 }
    let data: Data
    let entries: [Entry]
    init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw LeafError.invalid("这不是有效的 EPUB 文件。") }
        let lower = max(0, data.count - 65_557)
        var end: Int?
        for pos in stride(from: data.count - 22, through: lower, by: -1) {
            if data[pos] == 0x50 && data[pos+1] == 0x4b && data[pos+2] == 0x05 && data[pos+3] == 0x06 { end = pos; break }
        }
        guard let end else { throw LeafError.invalid("找不到 EPUB 压缩目录。") }
        var tail = ByteReader(data: data, offset: end + 4)
        let disk = try tail.int(2, little: true), directoryDisk = try tail.int(2, little: true)
        let diskCount = try tail.int(2, little: true), count = try tail.int(2, little: true)
        _ = try tail.int(4, little: true)
        let start = try tail.int(4, little: true)
        guard disk == 0, directoryDisk == 0, count == diskCount, count < 65_535, start < end else { throw LeafError.invalid("不支持分卷或 ZIP64 EPUB。") }
        var reader = ByteReader(data: data, offset: start)
        var parsed: [Entry] = []; var names = Set<String>(); var total = 0
        for _ in 0..<count {
            guard try reader.number(4, little: true) == 0x02014b50 else { throw LeafError.invalid("EPUB 压缩目录损坏。") }
            _ = try reader.bytes(4)
            let flags = try reader.int(2, little: true), method = try reader.int(2, little: true)
            _ = try reader.bytes(4)
            let checksum = try reader.number(4, little: true)
            let compressed = try reader.int(4, little: true), size = try reader.int(4, little: true)
            let nameLength = try reader.int(2, little: true), extra = try reader.int(2, little: true), comment = try reader.int(2, little: true)
            _ = try reader.bytes(4)
            let attributes = try reader.number(4, little: true), offset = try reader.int(4, little: true)
            let nameData = try reader.bytes(nameLength)
            guard let name = String(data: nameData, encoding: .utf8) else { throw LeafError.invalid("EPUB 资源名称必须采用 UTF-8 编码。") }
            _ = try reader.bytes(extra + comment)
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0"), !components.contains(".."), !components.contains("."), names.insert(name).inserted else { throw LeafError.invalid("EPUB 含有不安全或重复的资源路径。") }
            guard flags & 1 == 0, method == 0 || method == 8, (attributes >> 16) & 0xf000 != 0xa000 else { throw LeafError.invalid("EPUB 含有不支持的加密、压缩或符号链接。") }
            total += size
            guard size <= 128 * 1024 * 1024, total <= 1024 * 1024 * 1024, offset < start else { throw LeafError.invalid("EPUB 解压体积超出限制（单资源 128 MB，总计 1 GB）。") }
            parsed.append(Entry(name: name, method: method, compressed: compressed, size: size, offset: offset, crc: UInt32(checksum)))
        }
        entries = parsed
    }
    func read(_ name: String) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else { throw LeafError.invalid("EPUB 缺少资源：\(name)") }
        return try read(entry)
    }
    func read(_ entry: Entry) throws -> Data {
        var local = ByteReader(data: data, offset: entry.offset)
        guard try local.number(4, little: true) == 0x04034b50 else { throw LeafError.invalid("EPUB 文件头损坏。") }
        _ = try local.bytes(22)
        let name = try local.int(2, little: true), extra = try local.int(2, little: true)
        _ = try local.bytes(name + extra)
        let compressed = try local.bytes(entry.compressed)
        let result = entry.method == 0 ? compressed : try inflateData(compressed, expected: entry.size, raw: true)
        let checksum = result.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(result.count)) }
        guard result.count == entry.size, checksum == entry.crc else { throw LeafError.invalid("EPUB 资源校验失败：\(entry.name)") }
        return result
    }
}

private final class PackageXML: NSObject, XMLParserDelegate {
    var title = "", author = "", package = "", identifier = "", fixed = false
    private var identifierRef = ""
    private var field = ""
    private var failed = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        if name == "rootfile", package.isEmpty { package = attributes["full-path"] ?? "" }
        field = name
        if name == "package" { identifierRef = attributes["unique-identifier"] ?? "" }
        if name == "identifier" { field = attributes["id"] == identifierRef ? "uniqueID" : "" }
        if name == "meta", attributes["property"] == "rendition:layout" { field = "layout" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field == "uniqueID" { identifier += string }
        if field == "title" { title += string }; if field == "creator" { author += string }
        if field == "layout", string.contains("pre-paginated") { fixed = true }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { field = "" }
    static func parse(_ data: Data) throws -> PackageXML {
        let delegate = PackageXML(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw LeafError.invalid("EPUB 的 XML 元数据无法解析。") }; return delegate
    }
}

private final class EncryptionXML: NSObject, XMLParserDelegate {
    var resources: [(String, String)] = []
    private var algorithm = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        if name == "EncryptedData" { algorithm = "" }
        if name == "EncryptionMethod" { algorithm = attributes["Algorithm"] ?? "" }
        if name == "CipherReference", let uri = attributes["URI"] { resources.append((algorithm,uri)) }
    }
}

public enum EPUBImporter {
    public static func importBook(from source: URL, library: URL) throws -> Book {
        let input = try Data(contentsOf: source, options: .mappedIfSafe)
        guard input.count <= 512 * 1024 * 1024 else { throw LeafError.invalid("首版支持 512 MB 以内的 EPUB。") }
        let archive = try EPUBArchive(data: input)
        guard String(data: try archive.read("mimetype"), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip" else { throw LeafError.invalid("文件不是 EPUB 格式。") }
        let container = try PackageXML.parse(archive.read("META-INF/container.xml"))
        guard !container.package.isEmpty, archive.entries.contains(where: { $0.name == container.package }) else { throw LeafError.invalid("EPUB 缺少有效的书籍描述文件。") }
        let metadata = try PackageXML.parse(archive.read(container.package))
        guard !metadata.fixed else { throw LeafError.invalid("首版暂不支持固定版式 EPUB，请使用流式排版版本。") }
        var obfuscation: [String: String] = [:]
        if archive.entries.contains(where: { $0.name == "META-INF/encryption.xml" }) {
            let encryption = EncryptionXML()
            let parser = XMLParser(data: try archive.read("META-INF/encryption.xml")); parser.delegate = encryption
            parser.shouldResolveExternalEntities = false
            guard parser.parse(), !encryption.resources.isEmpty else { throw LeafError.invalid("书籍加密信息不完整。") }
            for (algorithm, path) in encryption.resources {
                guard algorithm == "http://www.idpf.org/2008/embedding" || algorithm == "http://ns.adobe.com/pdf/enc#RC" else { throw LeafError.invalid("这本书受 DRM 保护，首版无法打开。") }
                obfuscation[path.removingPercentEncoding ?? path] = algorithm
            }
        }
        let id = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        let destination = library.appendingPathComponent("Books/\(id)")
        if !FileManager.default.fileExists(atPath: destination.appendingPathComponent("original.epub").path) {
            let staging = library.appendingPathComponent("import-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let content = staging.appendingPathComponent("content")
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
            for entry in archive.entries {
                let path = content.appendingPathComponent(entry.name)
                if entry.name.hasSuffix("/") { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); continue }
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                var bytes = try archive.read(entry)
                if let algorithm = obfuscation[entry.name] {
                    let key: [UInt8]; let limit: Int
                    if algorithm == "http://www.idpf.org/2008/embedding" {
                        let identifier = metadata.identifier.filter { ![" ","\t","\r","\n"].contains(String($0)) }
                        guard !identifier.isEmpty else { throw LeafError.invalid("混淆字体缺少书籍唯一标识。") }
                        key = Array(Insecure.SHA1.hash(data: Data(identifier.utf8))); limit = 1040
                    } else {
                        let identifier = metadata.identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "urn:uuid:",with: "").replacingOccurrences(of: "-",with: "")
                        guard identifier.count == 32, identifier.allSatisfy({ $0.isHexDigit }) else { throw LeafError.invalid("Adobe 混淆字体缺少有效 UUID。") }
                        let characters = Array(identifier)
                        key = stride(from:0,to:32,by:2).compactMap { UInt8(String(characters[$0...$0+1]),radix:16) }; limit = 1024
                    }
                    for offset in 0..<min(limit,bytes.count) { bytes[offset] ^= key[offset % key.count] }
                }
                try bytes.write(to: path, options: .atomic)
            }
            try input.write(to: staging.appendingPathComponent("original.epub"), options: .atomic)
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        return Book(id: id, title: metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? source.deletingPathExtension().lastPathComponent, author: metadata.author.trimmingCharacters(in: .whitespacesAndNewlines).nonempty ?? "未知作者", packagePath: container.package)
    }
}

extension String {
    var nonempty: String? { isEmpty ? nil : self }
    func matches(pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = self as NSString
        return regex.matches(in: self, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
}
