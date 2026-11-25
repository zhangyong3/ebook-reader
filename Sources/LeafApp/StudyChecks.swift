#if DEBUG
import AppKit
import WebKit
import LeafCore

@MainActor enum StudyChecks {
    static func run(model: AppModel, web: WKWebView) async throws -> [String:Any] {
        var checks: [String:Bool]=[:]
        func expect(_ value: Bool, _ name: String) throws {
            checks[name]=value
            if !value { throw LeafError.invalid("Study integration check failed: " + name) }
        }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<300 { if condition() { return }; try await Task.sleep(for:.milliseconds(50)) }
            throw LeafError.invalid("Study integration check timed out.")
        }
        model.go("two.xhtml")
        try await Task.sleep(for:.milliseconds(500))
        func select(_ word: String) async throws {
            _ = try await web.callAsyncJavaScript("""
                const frame=document.querySelector('#viewer iframe'),doc=frame.contentDocument;
                const walker=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT);let node;
                while((node=walker.nextNode())) {
                    const start=node.textContent.indexOf(word);if(start<0)continue;
                    const range=doc.createRange();range.setStart(node,start);range.setEnd(node,start+word.length);
                    const selection=doc.defaultView.getSelection();selection.removeAllRanges();selection.addRange(range);
                    const rect=range.getBoundingClientRect();
                    node.parentElement.dispatchEvent(new doc.defaultView.MouseEvent('mouseup',{bubbles:true,button:0,detail:1,clientX:rect.left+3,clientY:rect.top+3}));return true;
                } throw new Error('Selection fixture word missing');
                """,arguments:["word":word],in:nil,contentWorld:.page)
            try await wait { model.selection?.text == word }
        }
        func clickTool(_ action: String) async throws {
            _ = try await web.callAsyncJavaScript("document.querySelector('#leaf-selection-tools button[aria-label=\"'+label+'\"]').click();return true",arguments:["label":action],in:nil,contentWorld:.page)
            try await Task.sleep(for:.milliseconds(150))
        }
        try await select("reader")
        try expect(model.lookupWord.isEmpty,"selectionDoesNotAutomaticallyLookup")
        let visible=try await web.evaluateJavaScript("!document.getElementById('leaf-selection-tools').hidden") as? Bool ?? false
        try expect(visible,"floatingToolbarVisible")
        try await clickTool("高亮")
        guard let highlight=model.currentAnnotations.first(where:{$0.quote=="reader"&&$0.kind=="highlight"}) else { throw LeafError.invalid("Highlight fixture missing") }
        model.changeHighlight(highlight.id,kind:"strikethrough",color:"blue")
        try await select("world");try await clickTool("高亮")
        try expect(model.currentAnnotations.contains(where:{$0.quote=="world"&&$0.kind=="strikethrough"&&$0.color=="blue"}),"lastHighlightStyleIsReused")
        let painted = try await web.evaluateJavaScript("""
            (()=>{const mark=document.querySelector('.leaf-mark.strikethrough');if(!mark)return false;
            const style=getComputedStyle(mark);return style.getPropertyValue('--mark-color').trim().length>0&&style.backgroundImage!=='none';})()
            """) as? Bool ?? false
        try expect(painted,"highlightColorActuallyPainted")
        try await select("world");try await clickTool("书签")
        let pinCount=try await web.evaluateJavaScript("document.querySelectorAll('.leaf-bookmark-pin').length") as? Int ?? 0
        try expect(pinCount>0,"bookmarkPinRendered")
        _ = try await web.evaluateJavaScript("""
            (()=>{const doc=document.querySelector('#viewer iframe').contentDocument;
            doc.body.dispatchEvent(new doc.defaultView.MouseEvent('dblclick',{bubbles:true,detail:2,button:0,clientX:3,clientY:170}));return true;})()
            """)
        try await wait { model.currentAnnotations.contains(where:{$0.kind=="freeNote"}) }
        let note=try XCTNote(model)
        _ = try await web.callAsyncJavaScript("const note=document.querySelector('.leaf-free-note');note.value='即时笔记测试';note.dispatchEvent(new Event('input',{bubbles:true}));return true",arguments:[:],in:nil,contentWorld:.page)
        try await wait { model.annotations.contains(where:{$0.id==note.id&&$0.note=="即时笔记测试"}) }
        model.styleFreeNote(note.id,font:"mono",color:"#1e5d9d",size:22)
        try await Task.sleep(for:.milliseconds(120))
        let fontSize=try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.leaf-free-note')).fontSize") as? String
        try expect(fontSize=="22px","inlineNoteStyleApplied")
        try await select("reader")
        model.lookup("reader");try await wait { !model.lookingUp }
        model.lookup("READER");try await wait { !model.lookingUp }
        let historyID=QueryHistory(kind:"dictionary",query:"reader").id
        try expect(model.queryHistory.filter{$0.id==historyID}.count==1,"dictionaryHistoryDeduplicated")
        try expect(model.queryMarks.filter{$0.quote=="reader"}.count==1,"queriedWordMarkDeduplicated")
        var config=APIConfiguration();config.baseURL="http://127.0.0.1:8769/v1";config.model="leaf-fixture"
        try await select("A reader discovers a new world in every book.")
        model.startAnalysis("A reader discovers a new world in every book.",configuration:config,key:"local-fixture-key")
        try await wait { model.analysisStatus=="streaming" && !model.analysisText.isEmpty }
        checks["incrementalStreamingObserved"]=true
        try await wait { !["loading","streaming"].contains(model.analysisStatus) }
        try expect(model.analysisStatus=="completed"&&model.analysisText.contains("句子结构")&&model.analysisText.contains("🌿"),"SSEUnicodeAndCompletion")
        try await wait { model.queryMarks.contains(where:{$0.quote=="A reader discovers a new world in every book."}) }
        let dashed=try await web.evaluateJavaScript("Array.from(document.querySelectorAll('.leaf-mark.queried')).some(mark=>getComputedStyle(mark).borderBottomStyle==='dashed'&&mark.offsetWidth>0)") as? Bool ?? false
        try expect(dashed,"queriedSentenceHasDashedUnderline")
        let analysis=try model.queryHistory.first(where:{$0.kind=="analysis"}).unwrap("Analysis history missing")
        let stored=analysis.analysis
        model.analysisText="";model.openHistory(analysis)
        try expect(model.analysisText==stored&&model.analysisTask==nil,"analysisHistoryRestoresWithoutNewRequest")
        model.startAnalysis("cancel test",configuration:config,key:"local-fixture-key")
        try await wait { model.analysisStatus=="streaming" && !model.analysisText.isEmpty }
        model.stopAnalysis();let partial=model.analysisText
        try await Task.sleep(for:.milliseconds(250))
        try expect(model.analysisStatus=="stopped"&&model.analysisText==partial,"streamCancellationStopsUpdates")
        model.startAnalysis("error test",configuration:config,key:"local-fixture-key")
        try await wait { model.analysisStatus=="failed" }
        try expect(model.analysisError?.contains("Key")==true,"HTTPFailureIsShown")
        let store=try LibraryStore(root:model.root)
        try expect(try store.load(Annotation.self,kind:"annotation").contains(where:{$0.id==note.id&&$0.note=="即时笔记测试"}),"inlineNotesPersisted")
        let marks=try store.load(Annotation.self,kind:"queryMark")
        try expect(marks.contains(where:{$0.quote=="reader"}) && marks.contains(where:{$0.quote=="A reader discovers a new world in every book."}),"queryMarksPersistedSeparatelyFromNotes")
        model.openHistory(analysis)
        return ["passed":checks.values.allSatisfy{$0},"checks":checks]
    }
    private static func XCTNote(_ model: AppModel) throws -> Annotation {
        guard let note=model.currentAnnotations.first(where:{$0.kind=="freeNote"}) else { throw LeafError.invalid("Free note not created") };return note
    }
}
private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped { guard let value=self else { throw LeafError.invalid(message) };return value }
}
#endif
