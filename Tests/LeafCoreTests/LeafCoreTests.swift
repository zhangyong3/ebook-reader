import XCTest
@testable import LeafCore

final class LeafCoreTests: XCTestCase {
    private var root: URL!
    private var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LeafTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testEPUBImportMetadataFingerprintAndDuplicate() throws {
        let store = try LibraryStore(root: root)
        let first = try EPUBImporter.importBook(from: fixtures.appendingPathComponent("Guide.epub"), library: root)
        let second = try EPUBImporter.importBook(from: fixtures.appendingPathComponent("Guide.epub"), library: root)
        XCTAssertEqual(first.id, second.id); XCTAssertEqual(first.id.count,64)
        XCTAssertEqual(first.title,"页间 · 阅读器使用指南"); XCTAssertEqual(first.author,"页间")
        XCTAssertEqual(first.packagePath,"EPUB/book.opf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.bookDirectory(first.id).appendingPathComponent("content/EPUB/one.xhtml").path))
    }
    func testEPUBRejectsTraversalAndTruncatedArchivesWithoutWriting() throws {
        let source = try Data(contentsOf:fixtures.appendingPathComponent("Guide.epub"))
        let dangerous = Data("../x/one.xhtml".utf8), valid = Data("EPUB/one.xhtml".utf8)
        var corrupted = source
        while let range = corrupted.range(of: valid) { corrupted.replaceSubrange(range,with:dangerous) }
        let url = root.appendingPathComponent("unsafe.epub"); try corrupted.write(to:url)
        XCTAssertThrowsError(try EPUBImporter.importBook(from:url,library:root))
        try source.prefix(80).write(to:url)
        XCTAssertThrowsError(try EPUBImporter.importBook(from:url,library:root))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("Books").path))
    }
    func testEPUBRestoresObfuscatedFontsWithoutChangingOriginal() throws {
        _ = try LibraryStore(root: root)
        let source = fixtures.appendingPathComponent("Obfuscated.epub")
        let book = try EPUBImporter.importBook(from: source, library: root)
        let directory = root.appendingPathComponent("Books/\(book.id)")
        let restored = try Data(contentsOf: directory.appendingPathComponent("content/EPUB/font.otf"))
        XCTAssertEqual(restored, Data((0..<2048).map { UInt8($0 % 256) }))
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: directory.appendingPathComponent("original.epub")))
    }
    func testMDictLZOArchive() throws {
        let dictionary = try MDict(url: fixtures.appendingPathComponent("LZO Demo.mdx"))
        XCTAssertTrue(try XCTUnwrap(dictionary.lookup("leaf")).contains("LZO"))
        XCTAssertTrue(try XCTUnwrap(dictionary.lookup("reader")).contains("读者"))
    }
    func testDatabasePersistsSettingsNotesAndRestoresTransactionally() throws {
        let store = try LibraryStore(root:root)
        var book = Book(id:"version-a",title:"书",author:"作者",packagePath:"content.opf")
        book.settings.fontSize=28; book.location="epubcfi(/6/2!/4/2/1:0)"
        try store.save(book,kind:"book",id:book.id)
        let note=Annotation(bookID:book.id,cfi:book.location!,quote:"原文\n第二行",note:"我的思考")
        try store.save(note,kind:"annotation",id:note.id.uuidString)
        let reopened=try LibraryStore(root:root)
        XCTAssertEqual(try reopened.load(Book.self,kind:"book").first?.settings.fontSize,28)
        XCTAssertEqual(try reopened.load(Annotation.self,kind:"annotation").first?.note,"我的思考")
        try store.remove(kind:"annotation",id:note.id.uuidString)
        try store.restore(Backup(books:[book],annotations:[note]))
        XCTAssertEqual(try store.load(Annotation.self,kind:"annotation").count,1)
        let wrong=Annotation(bookID:"other-edition",cfi:"x",quote:"原文")
        XCTAssertThrowsError(try store.restore(Backup(books:[book],annotations:[note,wrong])))
        XCTAssertEqual(try store.load(Annotation.self,kind:"annotation").count,1)
        XCTAssertTrue(Exporter.markdown(book:book,annotations:[note]).contains("> 原文\n> 第二行"))
    }
    func testMDictUnicodeRedirectsCrossBlockReadsAndResources() throws {
        let dict=try MDict(url:fixtures.appendingPathComponent("Leaf Demo.mdx"))
        XCTAssertEqual(dict.entryCount,5)
        XCTAssertTrue(try XCTUnwrap(dict.lookup("reader")).contains("读者"))
        XCTAssertEqual(try dict.lookup("reading"),try dict.lookup("READER"))
        XCTAssertTrue(try XCTUnwrap(dict.lookup("测试")).contains("中文词条"))
        XCTAssertTrue(try XCTUnwrap(dict.lookup("leaf")).contains("images/leaf.svg"))
        XCTAssertNil(try dict.lookup("absent"))
        let resources=try MDict(url:fixtures.appendingPathComponent("Leaf Demo.mdd"))
        XCTAssertTrue(try XCTUnwrap(resources.resource("images/leaf.svg")).starts(with:Data("<svg".utf8)))
        XCTAssertTrue(try XCTUnwrap(resources.resource("leaf.wav")).starts(with:Data("RIFF".utf8)))
    }
    func testMDictObfuscatedKeywordIndex() throws {
        var data = try Data(contentsOf: fixtures.appendingPathComponent("Leaf Demo.mdx"))
        var reader = ByteReader(data: data)
        let headerLength = try reader.int(4)
        let headerStart = reader.offset
        var header = String(data: try reader.bytes(headerLength), encoding: .utf16LittleEndian)!
        header = header.replacingOccurrences(of: "Encrypted=\"0\"", with: "Encrypted=\"2\"")
        let headerData = header.data(using: .utf16LittleEndian)!
        data.replaceSubrange(headerStart..<(headerStart+headerLength), with: headerData)
        let checksum = adler(headerData)
        data.replaceSubrange((headerStart+headerLength)..<(headerStart+headerLength+4), with: (0..<4).map { UInt8(truncatingIfNeeded: checksum >> ($0*8)) })
        let keyHeader = headerStart+headerLength+4
        var sizes = ByteReader(data: data, offset: keyHeader+24)
        let infoLength = try sizes.int(8)
        let infoStart = keyHeader+44
        let key = RIPEMD128.hash(data.subdata(in:(infoStart+4)..<(infoStart+8)) + Data([0x95,0x36,0,0]))
        var previous: UInt8 = 0x36
        for i in 0..<(infoLength-8) {
            let mixed = data[infoStart+8+i] ^ previous ^ UInt8(truncatingIfNeeded:i) ^ key[i%16]
            let encrypted = (mixed >> 4) | (mixed << 4)
            data[infoStart+8+i] = encrypted; previous = encrypted
        }
        let url = root.appendingPathComponent("obfuscated.mdx"); try data.write(to:url)
        let dictionary = try MDict(url:url)
        XCTAssertTrue(try XCTUnwrap(dictionary.lookup("reader")).contains("读者"))
    }
    private func compactDictionary(attributes: String, resource: Bool = false) throws -> URL {
        let sample = fixtures.appendingPathComponent(resource ? "Leaf Demo.mdd" : "Leaf Demo.mdx")
        let original = try Data(contentsOf: sample)
        var reader = ByteReader(data: original)
        let length = try reader.int(4)
        let originalHeader = try reader.bytes(length)
        _ = try reader.bytes(4)
        let header = String(data: originalHeader, encoding: .utf16LittleEndian)!
            .replacingOccurrences(of: " KeyCaseSensitive=", with: " \(attributes) KeyCaseSensitive=")
            .data(using: .utf16LittleEndian)!
        let size = UInt32(header.count), checksum = adler(header)
        var changed = Data((0..<4).map { UInt8(truncatingIfNeeded: size >> ((3-$0)*8)) })
        changed.append(header)
        changed.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: checksum >> ($0*8)) })
        changed.append(original.subdata(in: reader.offset..<original.count))
        let url = root.appendingPathComponent(UUID().uuidString + (resource ? ".mdd" : ".mdx"))
        try changed.write(to: url)
        return url
    }
    func testMDictCompactFlagsWithoutTemplatesAreNotAReasonToRejectImport() throws {
        for flags in ["Compact=\"Yes\"", "Compat=\"Yes\"", "Compact=\"Yes\" Compat=\"Yes\""] {
            let url = try compactDictionary(attributes: flags + " StyleSheet=\"\"")
            let dictionary = try MDict(url: url)
            XCTAssertTrue(try XCTUnwrap(dictionary.lookup("reader")).contains("读者"))
            XCTAssertEqual(try dictionary.lookup("reading"), try dictionary.lookup("reader"))
        }
        let resourceURL = try compactDictionary(attributes: "Compact=\"Yes\" Compat=\"Yes\" StyleSheet=\"\"", resource: true)
        let archive = try MDict(url: resourceURL)
        XCTAssertTrue(try XCTUnwrap(archive.resource("leaf.wav")).starts(with: Data("RIFF".utf8)))
    }
    func testMDictStillRejectsActualCompactTemplates() throws {
        let url = try compactDictionary(attributes: "Compact=\"Yes\" StyleSheet=\"1&#10;&lt;b&gt;&#10;&lt;/b&gt;\"")
        XCTAssertThrowsError(try MDict(url: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Compact"))
        }
    }
    func testLocalMDictWhenExplicitlyProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["LEAF_TEST_MDX"] else {
            throw XCTSkip("Set LEAF_TEST_MDX to verify a local dictionary without bundling its contents.")
        }
        let dictionary = try MDict(url: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(dictionary.entryCount, 0)
        for word in ["hello", "book", "reader"] {
            let definition = try XCTUnwrap(dictionary.lookup(word), "Missing test headword: \(word)")
            XCTAssertFalse(definition.isEmpty)
        }
        print("Local dictionary: \(dictionary.entryCount) entries; hello/book/reader lookups passed.")
    }
    func testMDictRejectsCorruption() throws {
        var data=try Data(contentsOf:fixtures.appendingPathComponent("Leaf Demo.mdx")); data[12] ^= 1
        let url=root.appendingPathComponent("damaged.mdx"); try data.write(to:url)
        XCTAssertThrowsError(try MDict(url:url))
        try data.prefix(6).write(to:url); XCTAssertThrowsError(try MDict(url:url))
    }
    func testRIPEMD128PublishedVectors() {
        func digest(_ value:String)->String { RIPEMD128.hash(Data(value.utf8)).map { String(format:"%02x",$0) }.joined() }
        XCTAssertEqual(digest(""),"cdf26213a150dc3ecb610f18f6b38b46")
        XCTAssertEqual(digest("abc"),"c14a12199c66e4ba84636b0f69144c77")
        XCTAssertEqual(digest("message digest"),"9e327b3d6e523062afc1132d7df9d1b8")
    }
    func testLZOLiteralsOverlappingReferencesAndMalformedInput() throws {
        let hello = Data([22])+Data("hello".utf8)+Data([144,0,17,0,0])
        XCTAssertEqual(try LZO.decompress(hello,expected:10),Data("hellohello".utf8))
        let overlap=Data([18,65,224,0,17,0,0])
        XCTAssertEqual(try LZO.decompress(overlap,expected:9),Data(repeating:65,count:9))
        let literal=Data([0,0,27])+Data(repeating:66,count:300)+Data([17,0,0])
        XCTAssertEqual(try LZO.decompress(literal,expected:300),Data(repeating:66,count:300))
        XCTAssertThrowsError(try LZO.decompress(hello,expected:9))
        XCTAssertThrowsError(try LZO.decompress(Data([64,255,17,0,0]),expected:3))
        XCTAssertThrowsError(try LZO.decompress(Data([0,0,0]),expected:1))
    }
}
