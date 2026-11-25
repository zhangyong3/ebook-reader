#if DEBUG
import AppKit
import WebKit
import LeafCore

@MainActor enum PaginationChecks {
    static func run(model: AppModel, window: NSWindow) async throws -> [String:Any] {
        var checks:[String:Bool]=[:],phase="initial"
        func wait(_ condition: ()->Bool) async throws {
            for _ in 0..<600 {
                if let error=model.paginationError { throw LeafError.invalid(error) }
                if condition() { return };try await Task.sleep(for:.milliseconds(50))
            }
            throw LeafError.invalid("Pagination check timed out (\(phase)): page \(model.currentPage)/\(model.totalPages), loading=\(model.paginating)")
        }
        func expect(_ value: Bool,_ name: String) throws { checks[name]=value;if !value { throw LeafError.invalid("Pagination check failed: "+name) } }
        func web() throws -> WKWebView { guard let view=model.bridge.webView else { throw LeafError.invalid("Reader view missing") };return view }
        func script(_ code: String) async throws -> Any? { try await web().evaluateJavaScript(code) }
        func jump(_ page: Int) async throws { phase="jump \(page)";model.goToPage(page);try await wait { model.currentPage==page };try await Task.sleep(for:.milliseconds(100)) }
        try await wait { !model.paginating && model.totalPages>0 }
        try expect(model.totalPages>3,"wholeBookPageCount")
        let total=model.totalPages
        try await jump(total);try await jump(1)
        checks["directCrossChapterJumpToLastPage"]=true
        for page in 1...total {
            try await jump(page)
            guard let status=try await web().callAsyncJavaScript("return await window.readerCommand({action:'paginationInfo'})",arguments:[:],in:nil,contentWorld:.page) as? [String:Any],let sections=status["sections"] as? [[Any]] else { throw LeafError.invalid("Pagination metadata missing") }
            let location=try await script("document.querySelector('#viewer iframe').contentDocument.baseURI") as? String ?? ""
            try expect(!location.isEmpty && sections.count==3,"chapterPagesMeasured")
        }
        checks["everyPageCanBeJumpedTo"]=true
        let lastDisabled=try await script("document.querySelector('.leaf-page-arrow.next').disabled") as? Bool ?? false
        try expect(lastDisabled,"lastPageDisablesNext")
        try await jump(1)
        let firstDisabled=try await script("document.querySelector('.leaf-page-arrow.previous').disabled") as? Bool ?? false
        try expect(firstDisabled,"firstPageDisablesPrevious")
        phase="arrow next"
        _ = try await script("document.querySelector('.leaf-page-arrow.next').click();true")
        try await wait { model.currentPage==2 }
        phase="arrow previous"
        _ = try await script("document.querySelector('.leaf-page-arrow.previous').click();true")
        try await wait { model.currentPage==1 };checks["marginArrowsTurnPages"]=true
        model.goToPage(0);model.goToPage(total+1);try await Task.sleep(for:.milliseconds(150))
        try expect(model.currentPage==1,"invalidPageDoesNotNavigate")
        model.settings { $0.fontSize=30 }
        try await Task.sleep(for:.milliseconds(350));try await wait { !model.paginating }
        try expect(model.totalPages>total,"fontChangeRecalculatesTotal")
        model.showInspector=true
        try await Task.sleep(for:.milliseconds(500));try await wait { !model.paginating }
        let narrowTotal=model.totalPages
        model.showInspector=false
        try await Task.sleep(for:.milliseconds(500));try await wait { !model.paginating }
        try expect(model.totalPages<=narrowTotal,"sidebarChangeRecalculatesTotal")
        window.setContentSize(NSSize(width:920,height:600));model.showInspector=true;model.showTOC=true
        try await Task.sleep(for:.milliseconds(600));try await wait { !model.paginating }
        let fit=try await script("(()=>{const left=document.querySelector('.leaf-page-arrow.previous').getBoundingClientRect(),right=document.querySelector('.leaf-page-arrow.next').getBoundingClientRect();return left.left>=0&&right.right<=innerWidth&&left.right<=32&&right.left>=innerWidth-32;})()") as? Bool ?? false
        try expect(fit,"arrowsFitMinimumReadingArea")
        window.setContentSize(NSSize(width:1180,height:800));model.showTOC=false;model.showInspector=false
        model.settings { $0.fontSize=22;$0.scrolling=true }
        try await Task.sleep(for:.milliseconds(700));try await wait { !model.paginating }
        try await jump(2)
        phase="scroll next"
        _ = try await script("document.querySelector('.leaf-page-arrow.next').click();true")
        try await wait { model.currentPage==3 };checks["scrollModePageJumpAndArrows"]=true
        model.settings { $0.scrolling=false }
        try await Task.sleep(for:.milliseconds(500));try await wait { !model.paginating }
        for page in 1...model.totalPages { try await jump(page) }
        checks["reflowedPagesRemainReachable"]=true
        try await jump(1)
        return ["passed":checks.values.allSatisfy{$0},"checks":checks,"totalPages":model.totalPages]
    }
}
#endif
