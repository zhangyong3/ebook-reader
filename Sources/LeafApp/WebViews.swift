import SwiftUI
import WebKit
import AVFoundation
import LeafCore

@MainActor
final class ReaderBridge {
    weak var webView: WKWebView?
    var onMessage: ((String, [String: Any]) -> Void)?
    func detach() { webView?.stopLoading(); webView = nil }
    func send(_ command: [String: Any]) {
        webView?.callAsyncJavaScript("return await window.readerCommand(command)", arguments: ["command": command], in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result {
                Task { @MainActor in self?.onMessage?("error", ["message": error.localizedDescription]) }
            }
        }
    }
}

final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    let dictionaries: DictionaryService
    private var jobs: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(root: URL, dictionaries: DictionaryService) { self.root = root; self.dictionaries = dictionaries }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let key = ObjectIdentifier(urlSchemeTask)
        jobs[key] = Task { @MainActor in
            do {
                let data: Data; let mime = Self.mime(url.pathExtension)
                switch url.host {
                case "app":
                    guard let base = Bundle.module.url(forResource: "Web", withExtension: nil) else { throw LeafError.invalid("应用缺少阅读资源。") }
                    let file = try Self.safeFile(base: base, path: url.path)
                    data = try Data(contentsOf: file)
                case "publication":
                    let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
                    guard let id = parts.first, id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { throw LeafError.invalid("书籍路径不合法。") }
                    let base = root.appendingPathComponent("Books/\(id)/content")
                    let path = parts.dropFirst().joined(separator: "/")
                    let file = try Self.safeFile(base: base, path: path)
                    let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
                    if ["html","xhtml","htm","svg"].contains(url.pathExtension.lowercased()), let html = String(data: bytes, encoding: .utf8) {
                        data = Self.secureHTML(html).data(using: .utf8)!
                    } else { data = bytes }
                case "dictionary":
                    let parts = url.path.split(separator: "/")
                    guard let first = parts.first, let id = UUID(uuidString: String(first)), let resource = try await dictionaries.resource(id: id, path: parts.dropFirst().joined(separator: "/")) else { throw LeafError.invalid("词典配套资源不存在。") }
                    data = resource
                default: throw LeafError.invalid("资源地址不受支持。")
                }
                guard !Task.isCancelled else { return }
                let csp = url.host == "app" ? "default-src 'none'; script-src leaf:; connect-src leaf:; frame-src leaf: blob:; style-src 'unsafe-inline' leaf:; img-src leaf: data: blob:; font-src leaf: data: blob:;" : "default-src 'none'; script-src 'none'; style-src 'unsafe-inline' leaf: blob:; img-src leaf: data: blob:; font-src leaf: data: blob:; media-src leaf: data: blob:;"
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Security-Policy": csp, "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"])!
                urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            } catch {
                if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
            }
            jobs[key] = nil
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask); jobs[key]?.cancel(); jobs[key] = nil
    }
    static func safeFile(base: URL, path: String) throws -> URL {
        let parts = path.split(separator: "/")
        guard !parts.contains(".."), !path.contains("\\"), !path.contains("\0") else { throw LeafError.invalid("拒绝不安全的资源路径。") }
        let file = base.appendingPathComponent(parts.joined(separator: "/")).standardizedFileURL.resolvingSymlinksInPath()
        let canonical = base.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard file.path.hasPrefix(canonical) else { throw LeafError.invalid("资源超出书籍目录。") }; return file
    }
    static func secureHTML(_ html: String) -> String {
        var clean = html.replacingOccurrences(of: "(?is)<script\\b[^>]*>.*?</script\\s*>", with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "(?is)<(?:iframe|object|embed)\\b[^>]*>.*?</(?:iframe|object|embed)\\s*>", with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "(?i)\\s+on[a-z]+\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: "", options: .regularExpression)
        return clean
    }
    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html","htm": return "text/html; charset=utf-8"
        case "xhtml": return "application/xhtml+xml; charset=utf-8"
        case "opf","ncx","xml": return "application/xml; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg","jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }
}

struct ReaderWebView: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalSchemeHandler(root: model.root, dictionaries: model.dictionaryService), forURLScheme: "leaf")
        config.userContentController.add(context.coordinator, name: "leaf")
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        model.bridge.webView = web
        web.load(URLRequest(url: URL(string: "leaf://app/index.html")!))
        return web
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading(); nsView.configuration.userContentController.removeScriptMessageHandler(forName: "leaf")
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var model: AppModel?
        init(_ model: AppModel) { self.model = model }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let command = model?.initialCommand() { model?.bridge.send(command) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { model?.readingError = error.localizedDescription }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let name = body["event"] as? String, message.frameInfo.request.url?.host == "app" else { return }
            if name == "context", let model, let web = model.bridge.webView { ReaderContextMenu.show(model: model, body: body, view: web) }
            else { model?.receive(name, body) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if ["leaf","about","blob","data"].contains(url.scheme ?? "") { decisionHandler(.allow) }
            else {
                if action.navigationType == .linkActivated, ["https","http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            }
        }
    }
}

private enum DictionaryAppearance {
    static func resource(_ name: String) -> String {
        guard let base = Bundle.module.url(forResource: "Web", withExtension: nil),
              let source = try? String(contentsOf: base.appendingPathComponent(name), encoding: .utf8) else {
            preconditionFailure("Missing bundled dictionary appearance resource: \(name)")
        }
        return source
    }
    static let css = resource("dictionary.css")
    static let script = resource("dictionary-theme.js")
}

struct DictionaryWebView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let id: UUID
    let html: String
    @ObservedObject var model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model, id: id) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.addUserScript(WKUserScript(source: DictionaryAppearance.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(LocalSchemeHandler(root: model.root, dictionaries: model.dictionaryService), forURLScheme: "leaf")
        let web = WKWebView(frame: .zero, configuration: config); web.navigationDelegate = context.coordinator
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.dark = colorScheme == .dark
        if context.coordinator.lastHTML == html { context.coordinator.applyAppearance(web); return }
        context.coordinator.lastHTML = html
        context.coordinator.appliedDark = nil
        let clean = LocalSchemeHandler.secureHTML(html).replacingOccurrences(of: "\\", with: "/")
        let page = """
        <!doctype html><html lang="zh" data-leaf-theme="\(colorScheme == .dark ? "dark" : "light")"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline' leaf:; img-src leaf: data:; font-src leaf: data:; media-src leaf: data:;"><style>\(DictionaryAppearance.css)</style></head><body id="leaf-dictionary">\(clean)</body></html>
        """
        web.loadHTMLString(page, baseURL: URL(string: "leaf://dictionary/\(id.uuidString)/"))
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        weak var model: AppModel?
        let id: UUID
        var lastHTML = ""
        var dark = false
        var appliedDark: Bool?
        var player: AVAudioPlayer?
        init(model: AppModel, id: UUID) { self.model = model; self.id = id }
        func applyAppearance(_ webView: WKWebView, force: Bool = false) {
            guard force || appliedDark != dark else { return }
            appliedDark = dark
            webView.callAsyncJavaScript("window.leafSetDictionaryAppearance?.(dark)", arguments: ["dark": dark], in: nil, in: .defaultClient, completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { applyAppearance(webView, force: true) }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else { decisionHandler(.allow); return }
            if ["entry","bword"].contains(url.scheme ?? "") {
                let word = url.absoluteString.components(separatedBy: "://").dropFirst().joined(separator: "://").removingPercentEncoding ?? ""
                model?.lookup(word); decisionHandler(.cancel)
            } else if url.scheme == "sound" {
                let path = url.absoluteString.components(separatedBy: "://").dropFirst().joined(separator: "://").removingPercentEncoding ?? ""
                Task { [weak self] in
                    guard let self, let model else { return }
                    do {
                        guard let data = try await model.dictionaryService.resource(id: id, path: path) else { throw LeafError.invalid("词库中找不到这段音频。") }
                        player = try AVAudioPlayer(data: data); player?.play()
                    } catch { model.error = error.localizedDescription }
                }
                decisionHandler(.cancel)
            } else if ["http","https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url); decisionHandler(.cancel) }
            else if url.fragment != nil { decisionHandler(.allow) }
            else { decisionHandler(.cancel) }
        }
    }
}
