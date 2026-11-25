import XCTest
@testable import LeafCore

final class StudyTests: XCTestCase {
    func testLocalAPIKeyLifecycleIsolationAndFilePermissions() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=LocalAPIKeyStore(root:root)
        XCTAssertNil(try store.read(baseURL:"https://service-a.example/v1"))
        try store.save("local-test-a",baseURL:"https://service-a.example/v1/")
        try store.save("local-test-b",baseURL:"https://service-b.example/v1")
        let reopened=LocalAPIKeyStore(root:root)
        XCTAssertEqual(try reopened.read(baseURL:"https://service-a.example/v1"),"local-test-a")
        let permissions=try FileManager.default.attributesOfItem(atPath:store.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue,0o600)
        try reopened.save("replacement",baseURL:"https://service-a.example/v1")
        XCTAssertEqual(try store.read(baseURL:"https://service-a.example/v1"),"replacement")
        try store.save("  ",baseURL:"https://service-a.example/v1")
        XCTAssertNil(try reopened.read(baseURL:"https://service-a.example/v1"))
        XCTAssertEqual(try reopened.read(baseURL:"https://service-b.example/v1"),"local-test-b")
        let other=LocalAPIKeyStore(root:root.appendingPathComponent("other-library"))
        XCTAssertNil(try other.read(baseURL:"https://service-b.example/v1"))
        let invalid=Data("invalid-json".utf8)
        try invalid.write(to:store.fileURL)
        XCTAssertThrowsError(try store.save("new-value",baseURL:"https://service-b.example/v1"))
        XCTAssertEqual(try Data(contentsOf:store.fileURL),invalid)
    }
    func testOldAnnotationsStillDecodeWithoutNewFields() throws {
        var item=Annotation(bookID:"book",cfi:"epubcfi(/6/2!/4/2/1:0)",quote:"old selection")
        item.note="original note"
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(item)) as? [String:Any])
        object["placement"]=nil; object["noteAppearance"]=nil
        let restored=try JSONDecoder().decode(Annotation.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNil(restored.placement); XCTAssertNil(restored.noteAppearance)
        XCTAssertEqual(restored.note,"original note"); XCTAssertEqual(restored.cfi,item.cfi)
    }
    func testFreeNoteStylesAndLocationSurvivePersistence() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try LibraryStore(root:root)
        var note=Annotation(bookID:"book",cfi:"cfi",quote:"",kind:"freeNote",note:"保留想法")
        note.placement=NotePlacement(offsetX:1.5,offsetY:2.0)
        note.noteAppearance=NoteAppearance();note.noteAppearance?.font="serif";note.noteAppearance?.size=22
        try store.save(note,kind:"annotation",id:note.id.uuidString)
        let restored=try XCTUnwrap(store.load(Annotation.self,kind:"annotation").first)
        XCTAssertEqual(restored,note)
    }
    func testHistoryDeduplicatesCaseAndWhitespaceButKeepsKindsSeparate() throws {
        let a=QueryHistory(kind:"dictionary",query:"  Reader  ")
        let b=QueryHistory(kind:"dictionary",query:"reader")
        let c=QueryHistory(kind:"analysis",query:"reader")
        XCTAssertEqual(a.id,b.id);XCTAssertNotEqual(a.id,c.id)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try LibraryStore(root:root)
        try store.save(a,kind:"history",id:a.id)
        try store.save(b,kind:"history",id:b.id)
        XCTAssertEqual(try store.load(QueryHistory.self,kind:"history").count,1)
    }
    func testAPIEndpointNormalizationAndSecurityBoundaries() throws {
        var settings=APIConfiguration()
        XCTAssertEqual(try settings.endpoint().absoluteString,"https://api.openai.com/v1/chat/completions")
        settings.baseURL="https://example.com";XCTAssertEqual(try settings.endpoint().path,"/v1/chat/completions")
        settings.baseURL="https://example.com/proxy/v1/";XCTAssertEqual(try settings.endpoint().path,"/proxy/v1/chat/completions")
        settings.baseURL="http://127.0.0.1:8769/v1";XCTAssertNotNil(try settings.endpoint())
        settings.baseURL="https://example.com/v1/chat/completions";XCTAssertEqual(try settings.endpoint().path,"/v1/chat/completions")
        for invalid in ["not a URL","http://example.com/v1","https://key@example.com/v1","https://example.com/v1?key=secret"] {
            settings.baseURL=invalid;XCTAssertThrowsError(try settings.endpoint())
        }
    }
    func testSSEMultilineCommentsUnicodeAndDone() throws {
        var parser=SSEDecoder()
        XCTAssertNil(parser.consume(": heartbeat"))
        XCTAssertNil(parser.consume("event: message"))
        XCTAssertNil(parser.consume("data: {\"choices\":["))
        XCTAssertNil(parser.consume("data: {\"delta\":{\"content\":\"语法分析 🌿\"}}]}"))
        let event=try XCTUnwrap(parser.consume("\r"))
        XCTAssertEqual(try ChatChunk.decode(event),.text("语法分析 🌿"))
        XCTAssertNil(parser.consume("data: [DONE]"))
        XCTAssertEqual(try ChatChunk.decode(XCTUnwrap(parser.finish())),.finish(nil))
    }
    func testStreamErrorAndTruncationAreDistinct() throws {
        XCTAssertThrowsError(try ChatChunk.decode("{\"error\":{\"message\":\"bad request\"}}"))
        XCTAssertEqual(try ChatChunk.decode("{\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}"),.finish("length"))
        XCTAssertNil(try ChatChunk.decode("{\"choices\":[],\"usage\":{\"total_tokens\":100}}"))
    }
}
