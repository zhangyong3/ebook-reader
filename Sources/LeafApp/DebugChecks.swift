#if DEBUG
import AppKit
import WebKit
import Foundation

/// Opt-in integration checks against the actual WKWebView, using an isolated library via LEAF_LIBRARY_PATH.
@MainActor enum DebugChecks {
    static func run(model: AppModel, reportURL: URL) async {
        var report: [String: Any] = [:]
        do {
            for _ in 0..<300 {
                if model.readerReady { break }
                if let error = model.readingError { throw NSError(domain: "LeafChecks",code:1,userInfo:[NSLocalizedDescriptionKey:error]) }
                try await Task.sleep(for:.milliseconds(100))
            }
            if !model.readerReady {
                report["bookID"] = model.currentID ?? "none"
                report["readingError"] = model.readingError ?? model.error ?? "none"
                if let web = model.bridge.webView {
                    report["document"] = try? await web.evaluateJavaScript("JSON.stringify({url:location.href,ready:document.readyState,command:typeof window.readerCommand,frames:document.querySelectorAll('#viewer iframe').length,text:document.body.innerText})")
                }
            }
            guard model.readerReady, let web = model.bridge.webView, let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.keyWindow else {
                throw NSError(domain:"LeafChecks",code:2,userInfo:[NSLocalizedDescriptionKey:"Reader did not become ready"])
            }
            if CommandLine.arguments.contains("--pagination-check") {
                let result=try await PaginationChecks.run(model:model,window:window)
                report["pagination"]=result;report["passed"]=result["passed"]
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:reportURL,options:.atomic)
                return
            }
            if CommandLine.arguments.contains("--annotation-layout-check") {
                let layout=try await AnnotationLayoutChecks.run(model:model,web:web,window:window)
                report["annotationLayout"]=layout;report["passed"]=layout["passed"]
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:reportURL,options:.atomic)
                return
            }
            let originalSize = window.contentLayoutRect.size
            model.showTOC = true; model.showInspector = true
            var layouts: [[String: Any]] = []
            for size in [NSSize(width:920,height:600),NSSize(width:920,height:800),NSSize(width:1180,height:600),NSSize(width:1180,height:800)] {
                window.setContentSize(size)
                try await Task.sleep(for:.milliseconds(600))
                let result = try await web.evaluateJavaScript("""
                    (() => { const viewer=document.getElementById('viewer'); const stage=document.querySelector('#viewer .epub-container');
                    return {viewport:innerWidth,viewer:viewer.clientWidth,stage:stage?.clientWidth||0,frameCount:document.querySelectorAll('#viewer iframe').length}; })()
                    """) as? [String:Any] ?? [:]
                var entry = result; entry["windowWidth"] = size.width; entry["windowHeight"] = size.height
                let width = result["viewer"] as? Double ?? 0, stage = result["stage"] as? Double ?? 0
                entry["passed"] = width > 0 && stage > 0 && stage <= width+1
                layouts.append(entry)
            }
            report["layouts"] = layouts
            _ = try await web.evaluateJavaScript("""
                (() => { const doc=document.querySelector('#viewer iframe').contentDocument; const script=doc.createElement('script');
                script.textContent='parent.__leafBookScriptExecuted=true'; doc.head.append(script); return true; })()
                """)
            try await Task.sleep(for:.milliseconds(150))
            let security = try await web.evaluateJavaScript("""
                (() => ({bookScriptBlocked:window.__leafBookScriptExecuted!==true,
                baseURI:document.querySelector('#viewer iframe').contentDocument.baseURI}))()
                """) as? [String:Any] ?? [:]
            report["security"] = security
            report["passed"] = layouts.allSatisfy { $0["passed"] as? Bool == true } && security["bookScriptBlocked"] as? Bool == true
            if CommandLine.arguments.contains("--study-check") {
                let study = try await StudyChecks.run(model: model, web: web)
                report["study"] = study
                report["passed"] = report["passed"] as? Bool == true && study["passed"] as? Bool == true
            }
            if CommandLine.arguments.contains("--dictionary-check") {
                let dictionary = try await checkDictionary(model: model, window: window)
                report["dictionary"] = dictionary
                report["passed"] = report["passed"] as? Bool == true && dictionary["passed"] as? Bool == true
                model.showTOC = false; model.showInspector = true
            } else { model.showTOC = false; model.showInspector = CommandLine.arguments.contains("--study-check") }
            window.setContentSize(originalSize)
        } catch { report["passed"] = false; report["error"] = error.localizedDescription; report["javascriptError"] = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            if CommandLine.arguments.contains("--pagination-check"),let web=model.bridge.webView {
                report["paginationState"]=try? await web.callAsyncJavaScript("return await window.readerCommand({action:'paginationInfo'})",arguments:[:],in:nil,contentWorld:.page)
            }
        }
        do { try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:reportURL,options:.atomic) }
        catch { fputs("Leaf integration check report failed: \(error)\n",stderr) }
    }
    private static func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private static func checkDictionary(model: AppModel, window: NSWindow) async throws -> [String: Any] {
        guard !model.dictionaries.isEmpty else { throw NSError(domain: "LeafChecks", code: 3, userInfo: [NSLocalizedDescriptionKey: "Import a dictionary into the isolated test library first."]) }
        model.lookup("hello")
        for _ in 0..<300 {
            if !model.lookingUp && !model.lookupResults.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Exercise an inline !important authored color, in addition to the real dictionary stylesheet.
        model.lookupResults = model.lookupResults.map { ($0.0, $0.1, $0.2 + "<span id='leaf-contrast-probe' style='color:#111!important;background:#fff!important;-webkit-text-fill-color:#111!important'>Contrast probe</span><span id='leaf-background-probe' style='background:#fff url(data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciLz4=) no-repeat!important;color:#111!important'>Image background probe</span>") }
        try await Task.sleep(for: .milliseconds(500))
        guard let root = window.contentView else { throw NSError(domain: "LeafChecks", code: 4) }
        let webViews = descendants(root, of: WKWebView.self)
        var dictionaryView: WKWebView?
        for webView in webViews {
            if (try? await webView.evaluateJavaScript("document.body.id")) as? String == "leaf-dictionary" { dictionaryView = webView; break }
        }
        let splitViews = descendants(root, of: NSSplitView.self)
        guard let dictionary = dictionaryView,
              let split = splitViews.first(where: { $0.isVertical && $0.arrangedSubviews.count == 2 }) else {
            throw NSError(domain: "LeafChecks", code: 4, userInfo: [NSLocalizedDescriptionKey: "Dictionary or split view missing: webViews=\(webViews.count), splitViews=\(splitViews.count)"])
        }
        let originalAppearance = NSApp.appearance
        let originalWindowAppearance = window.appearance
        window.appearance = nil
        defer { NSApp.appearance = originalAppearance; window.appearance = originalWindowAppearance }
        var modes: [[String: Any]] = []
        for appearance in [NSAppearance.Name.darkAqua, .aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let dark = appearance == .darkAqua
            var measurement: [String: Any] = [:]
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(50))
                measurement = try await dictionary.evaluateJavaScript(Self.contrastMeasurement) as? [String: Any] ?? [:]
                if (dictionary.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) == dark && measurement["dark"] as? Bool == dark { break }
            }
            var mode = measurement
            mode["appearance"] = appearance.rawValue
            mode["nativeDark"] = dictionary.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            mode["passed"] = measurement["dark"] as? Bool == dark && measurement["imageBackgroundPreserved"] as? Bool == true && (dark
                ? (measurement["minimumContrast"] as? Double ?? 0) >= 4.5 && measurement["probeForeground"] as? String == "rgb(225, 229, 221)"
                : measurement["probeForeground"] as? String == "rgb(17, 17, 17)")
            modes.append(mode)
        }
        window.setContentSize(NSSize(width: 1180, height: 800))
        try await Task.sleep(for: .milliseconds(300))
        var widths: [[String: Any]] = []
        for requested: CGFloat in [300, 500, 360] {
            split.setPosition(split.bounds.width - requested - split.dividerThickness, ofDividerAt: 0)
            try await Task.sleep(for: .milliseconds(300))
            let width = split.arrangedSubviews.last?.frame.width ?? 0
            widths.append(["requested": requested, "actual": width, "passed": abs(width - requested) <= 2])
        }
        return ["modes": modes, "widths": widths, "passed": modes.allSatisfy { $0["passed"] as? Bool == true } && widths.allSatisfy { $0["passed"] as? Bool == true }]
    }

    private static let contrastMeasurement = """
        (() => {
            const dark = document.documentElement.dataset.leafTheme === 'dark';
            const rgb = value => (value.match(/[\\d.]+/g)||[]).slice(0,3).map(Number);
            const luminance = color => rgb(color).map(n => { const v=n/255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4; }).reduce((sum,v,i)=>sum+v*[.2126,.7152,.0722][i],0);
            const background = getComputedStyle(document.body).backgroundColor;
            const ratio = color => { const a=luminance(color),b=luminance(background);return (Math.max(a,b)+.05)/(Math.min(a,b)+.05); };
            const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
            const contrasts=[];let text;
            while((text=walker.nextNode())) {
                const parent=text.parentElement;
                if(!text.textContent.trim()||!parent?.getClientRects().length||['STYLE','SCRIPT'].includes(parent.tagName))continue;
                const style=getComputedStyle(parent);
                if(style.visibility==='hidden'||style.display==='none')continue;
                contrasts.push(ratio(style.color));
            }
            return {dark,background,imageBackgroundPreserved:getComputedStyle(document.getElementById('leaf-background-probe')).backgroundImage.includes('data:image/'),minimumContrast:Math.min(...contrasts),sampleCount:contrasts.length,stylesheets:[...document.styleSheets].filter(s=>s.href).map(s=>new URL(s.href).pathname.split('/').pop()),
                    probeForeground:getComputedStyle(document.getElementById('leaf-contrast-probe')).color};
        })()
        """

}
#endif
