#if DEBUG
import AppKit
import WebKit
import LeafCore

/// Measure overlays against the actual glyph ranges after native sidebar geometry changes.
@MainActor enum AnnotationLayoutChecks {
    static func run(model: AppModel, web: WKWebView, window: NSWindow) async throws -> [String:Any] {
        var web=web
        model.showTOC=false; model.showInspector=false
        try await Task.sleep(for:.milliseconds(300))
        web=model.bridge.webView ?? web
        model.settings { $0.width=420; $0.fontSize=22; $0.scrolling=false }
        try await Task.sleep(for:.milliseconds(700))
        web=model.bridge.webView ?? web
        _ = try await web.callAsyncJavaScript("await window.readerCommand({action:'go',target:'two.xhtml'});return true",arguments:[:],in:nil,contentWorld:.page)
        try await Task.sleep(for:.milliseconds(200))
        let samples=[("highlight","reader"),("underline","A reader discovers a new world in every book."),("strikethrough","thought"),("queried","leaf"),("bookmark","world")]
        for (kind,quote) in samples {
            _ = try await web.callAsyncJavaScript("""
                const doc=document.querySelector('#viewer iframe').contentDocument,walker=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT);let node;
                while((node=walker.nextNode())) {
                    const start=node.textContent.indexOf(quote);if(start<0)continue;
                    const range=doc.createRange();range.setStart(node,start);range.setEnd(node,start+quote.length);
                    const selected=doc.defaultView.getSelection();selected.removeAllRanges();selected.addRange(range);
                    const r=range.getBoundingClientRect();node.parentElement.dispatchEvent(new doc.defaultView.MouseEvent('mouseup',{bubbles:true,button:0,clientX:r.left+2,clientY:r.top+2}));return true;
                }throw new Error('Layout fixture text missing');
                """,arguments:["quote":quote],in:nil,contentWorld:.page)
            for _ in 0..<100 { if model.selection?.text==quote { break }; try await Task.sleep(for:.milliseconds(20)) }
            guard let selected=model.selection, selected.text==quote, let bookID=model.currentID else { throw LeafError.invalid("Layout fixture selection missing") }
            if kind=="queried" { if let mark=model.queryMark(for:quote) { model.saveQueryMark(mark) } }
            else { model.persist(Annotation(bookID:bookID,cfi:selected.cfi,href:selected.href,quote:selected.text,prefix:selected.prefix,suffix:selected.suffix,kind:kind)) }
            try await Task.sleep(for:.milliseconds(50))
        }
        let items=samples.map { ["kind":$0.0,"quote":$0.1] }
        var states:[[String:Any]]=[]
        func measure(_ name: String) async throws {
            try await Task.sleep(for:.milliseconds(450))
            web=model.bridge.webView ?? web
            var data:[String:Any]
            do { data=try await web.callAsyncJavaScript(Self.measurement,arguments:["items":items],in:nil,contentWorld:.page) as? [String:Any] ?? [:] }
            catch { data=["passed":false,"error":(error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription] }
            data["state"]=name;states.append(data)
        }
        func width(_ requested: CGFloat) async throws {
            guard let root=window.contentView,let split=findSplit(root) else { throw LeafError.invalid("Layout split view missing") }
            split.setPosition(split.bounds.width-requested-split.dividerThickness,ofDividerAt:0)
        }
        try await measure("noSidebars")
        model.showInspector=true;try await Task.sleep(for:.milliseconds(200));try await width(300)
        try await measure("right300")
        try await width(500);try await measure("right500")
        model.showInspector=false;try await measure("rightCollapsed")
        model.showTOC=true;try await measure("leftExpanded")
        model.showTOC=false;try await measure("leftCollapsed")
        model.showInspector=true;try await Task.sleep(for:.milliseconds(200));try await width(360)
        model.showTOC=true;try await measure("bothExpanded")
        window.setContentSize(NSSize(width:920,height:600));try await measure("minimumWindow")
        window.setContentSize(NSSize(width:1180,height:800));model.showTOC=false
        // Also cross the reading-width cap, where the EPUB itself has to reflow.
        model.settings { $0.width=680 }
        try await width(500);try await measure("reflowNarrow")
        try await width(280);try await measure("reflowWide")
        model.showInspector=false;try await measure("reflowCollapsed")
        model.settings { $0.scrolling=true };model.showInspector=true
        try await Task.sleep(for:.milliseconds(300));try await width(300);try await measure("scrollRight300")
        try await width(500);try await measure("scrollRight500")
        model.showInspector=false;try await measure("scrollCollapsed")
        return ["passed":states.allSatisfy{$0["passed"] as? Bool == true},"states":states]
    }
    private static func findSplit(_ view: NSView) -> NSSplitView? {
        if let split=view as? NSSplitView,split.isVertical,split.arrangedSubviews.count==2 { return split }
        for child in view.subviews { if let split=findSplit(child) { return split } };return nil
    }
    private static let measurement="""
        const frame=document.querySelector('#viewer iframe'),doc=frame.contentDocument,offset=frame.getBoundingClientRect();
        const visible=r=>r.left+r.width>=0&&r.left<innerWidth&&r.top+r.height>=0&&r.top<innerHeight;
        const source=quote=>{const walker=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT);let node;
          while((node=walker.nextNode())){const i=node.textContent.indexOf(quote);if(i<0)continue;const range=doc.createRange();range.setStart(node,i);range.setEnd(node,i+quote.length);return range;}throw new Error('Source missing');};
        const results=items.map(item=>{
          const range=source(item.quote),all=[...range.getClientRects()].map(r=>({left:offset.left+r.left,top:offset.top+r.top,width:r.width,height:r.height}));
          let expected,actual;
          if(item.kind==='bookmark'){
            const r=all[0];expected=visible(r)?[{left:Math.max(2,r.left-25),top:Math.max(0,r.top)}]:[];
            actual=[...document.querySelectorAll('.leaf-bookmark-pin')].map(el=>el.getBoundingClientRect());
          }else{
            expected=all.filter(r=>visible(r)&&r.width>=1);actual=[...document.querySelectorAll('.leaf-mark.'+item.kind)].map(el=>el.getBoundingClientRect());
          }
          let error=0;if(actual.length!==expected.length)error=9999;
          for(let i=0;i<Math.min(expected.length,actual.length);i++)for(const key of item.kind==='bookmark'?['left','top']:['left','top','width','height'])error=Math.max(error,Math.abs(expected[i][key]-actual[i][key]));
          return {kind:item.kind,error,expected:expected.length,actual:actual.length};
        });
        return {passed:results.every(r=>r.error<=1),viewport:innerWidth,frameLeft:offset.left,frameWidth:offset.width,results};
        """
}
#endif
