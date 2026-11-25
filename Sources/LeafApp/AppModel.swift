import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LeafCore

struct TextSelection {
    var cfi = "", text = "", href = "", prefix = "", suffix = "", chapter = ""
}

actor DictionaryService {
    private var opened: [UUID: MDict] = [:]
    private var resources: [UUID: [MDict]] = [:]
    private var access: [UUID: URL] = [:]
    private var directories: [UUID: URL] = [:]
    private var warnings: [UUID: [String]] = [:]
    func open(_ record: DictionaryRecord) throws -> Int {
        if let dict = opened[record.id] { return dict.entryCount }
        var stale = false
        let url: URL
        if let bookmark = record.bookmark {
            url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        } else { url = URL(fileURLWithPath: record.path) }
        if url.startAccessingSecurityScopedResource() { access[record.id] = url }
        let dict = try MDict(url: url)
        directories[record.id] = url.deletingLastPathComponent()
        // Resource archives are optional. A bad MDD must not prevent text lookup.
        let base = url.deletingPathExtension().lastPathComponent
        let siblings = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        var archives: [MDict] = []
        for candidate in siblings.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where candidate.pathExtension.lowercased() == "mdd" && (candidate.deletingPathExtension().lastPathComponent == base || candidate.lastPathComponent.hasPrefix(base + ".")) {
            do { archives.append(try MDict(url: candidate)) } catch { warnings[record.id, default: []].append(candidate.lastPathComponent + "：" + error.localizedDescription) }
        }
        opened[record.id] = dict; resources[record.id] = archives
        return dict.entryCount
    }
    func lookup(_ word: String, records: [DictionaryRecord]) -> [(UUID, String, String)] {
        records.map { record in
            do {
                _ = try open(record)
                var html = try opened[record.id]?.lookup(word) ?? "<p>未找到这个词条。</p>"
                for warning in warnings[record.id] ?? [] { html += "<p>配套资源未载入：" + escapeHTML(warning) + "</p>" }
                return (record.id, record.name, html)
            } catch { return (record.id, record.name, "<p>" + escapeHTML(error.localizedDescription) + "</p>") }
        }
    }
    func resource(id: UUID, path: String) throws -> Data? {
        for archive in resources[id] ?? [] { if let data = try archive.resource(path) { return data } }
        if let directory = directories[id] {
            let normalized = path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let parts = normalized.split(separator: "/")
            guard !parts.contains(".."), !normalized.contains("\0") else { return nil }
            let file = directory.appendingPathComponent(normalized).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"), ["css","png","jpg","jpeg","svg","gif","webp","mp3","wav","ogg","ttf","otf","woff","woff2"].contains(file.pathExtension.lowercased()) else { return nil }
            if FileManager.default.fileExists(atPath: file.path) {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 32 * 1024 * 1024 else { throw LeafError.invalid("词典资源超过 32 MB。") }
                return try Data(contentsOf: file)
            }
        }
        return nil
    }
    func remove(_ id: UUID) {
        opened[id] = nil; resources[id] = nil; directories[id] = nil; warnings[id] = nil
        access.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
    }
}

func escapeHTML(_ string: String) -> String {
    string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

@MainActor
final class AppModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var annotations: [Annotation] = []
    @Published var dictionaries: [DictionaryRecord] = []
    @Published var currentID: String?
    @Published var sessionID = UUID()
    @Published var libraryQuery = ""
    @Published var error: String?
    @Published var busy = false
    @Published var showTOC = false
    @Published var showInspector = false
    @Published var inspector = "dictionary"
    @Published var showDictionaries = false
    @Published var toc: [TOCEntry] = []
    @Published var selection: TextSelection?
    @Published var chapter = ""
    @Published var searchQuery = ""
    @Published var searchResults: [SearchHit] = []
    @Published var searching = false
    @Published var searchVisible = false
    @Published var lookupWord = ""
    @Published var lookupResults: [(UUID, String, String)] = []
    @Published var lookingUp = false
    @Published var unresolved: Set<String> = []
    @Published var currentPage = 0
    @Published var totalPages = 0
    @Published var paginating = true
    @Published var paginationError: String?
    @Published var readerReady = false
    @Published var readingError: String?
    @Published var editingAnnotation: Annotation?
    @Published var noteText = ""
    @Published var showSettings = false
    @Published var apiConfiguration = APIConfiguration()
    @Published var highlightStyle = HighlightStyle()
    @Published var queryHistory: [QueryHistory] = []
    @Published var queryMarks: [Annotation] = []
    @Published var analysisQuery = ""
    @Published var analysisText = ""
    @Published var analysisStatus = "idle"
    @Published var analysisError: String?
    var analysisTask: Task<Void, Never>?
    var analysisRunID = UUID()
    var analysisModel = ""
    var analysisHistory: QueryHistory?

    var store: LibraryStore?
    var lookupTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    let dictionaryService = DictionaryService()
    let bridge = ReaderBridge()
    var root: URL { store?.root ?? FileManager.default.temporaryDirectory.appendingPathComponent("Leaf-unavailable") }
    var currentBook: Book? { books.first { $0.id == currentID } }
    var currentAnnotations: [Annotation] { annotations.filter { $0.bookID == currentID }.sorted { $0.createdAt < $1.createdAt } }
    var renderedAnnotations: [Annotation] { queryMarks.filter { $0.bookID == currentID } + currentAnnotations }
    var visibleBooks: [Book] {
        books.filter { libraryQuery.isEmpty || ($0.title + " " + $0.author).localizedCaseInsensitiveContains(libraryQuery) }.sorted { $0.lastOpened > $1.lastOpened }
    }

    init() {
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let override = ProcessInfo.processInfo.environment["LEAF_LIBRARY_PATH"].map { URL(fileURLWithPath: $0) }
            store = try LibraryStore(root: override ?? support.appendingPathComponent("Leaf"))
            try reload()
        } catch { self.error = error.localizedDescription }
        bridge.onMessage = { [weak self] name, body in self?.receive(name, body) }
    }
    func reload() throws {
        guard let store else { return }
        books = try store.load(Book.self, kind: "book")
        annotations = try store.load(Annotation.self, kind: "annotation")
        queryMarks = try store.load(Annotation.self, kind: "queryMark")
        queryHistory = try store.load(QueryHistory.self, kind: "history").sorted { $0.updatedAt > $1.updatedAt }
        apiConfiguration = try store.load(APIConfiguration.self, kind: "apiConfiguration").first ?? APIConfiguration()
        highlightStyle = try store.load(HighlightStyle.self, kind: "highlightStyle").first ?? HighlightStyle()
        dictionaries = try store.load(DictionaryRecord.self, kind: "dictionary").sorted { ($0.priority ?? 0, $0.path) < ($1.priority ?? 0, $1.path) }
    }
    func saveBook(_ book: Book) {
        do { try store?.save(book, kind: "book", id: book.id) }
        catch { self.error = error.localizedDescription }
        if let index = books.firstIndex(where: { $0.id == book.id }) { books[index] = book }
    }
    func open(_ book: Book) {
        flushProgress(); sessionID = UUID(); currentID = book.id; selection = nil; toc = []; unresolved = []; chapter = ""
        readerReady = false; currentPage=0; totalPages=0; paginating=true; paginationError=nil; readingError = nil; searchResults = []; searchVisible = false
        var book = book; book.lastOpened = Date(); saveBook(book)
    }
    func closeBook() { flushProgress(); currentID = nil; selection = nil; bridge.detach() }
    func flushProgress() { progressTask?.cancel(); if let book = currentBook { saveBook(book) } }
    func pickBooks() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data]
        panel.allowsMultipleSelection = true; panel.message = "导入 EPUB 到本地书库"
        guard panel.runModal() == .OK else { return }; importBooks(panel.urls)
    }
    func importBooks(_ urls: [URL]) {
        guard !busy, store != nil else { return }; busy = true
        let root = root
        Task {
            var imported: Book?; var failures: [String] = []
            for url in urls {
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        return try EPUBImporter.importBook(from: url, library: root)
                    }.value
                    if let existing = books.first(where: { $0.id == result.id }) { imported = existing }
                    else { try store?.save(result, kind: "book", id: result.id); books.append(result); imported = result }
                } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
            busy = false
            if let imported { open(imported) }
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }
    func removeBook(_ book: Book) {
        let alert = NSAlert(); alert.messageText = "从书库移除《\(book.title)》？"
        alert.informativeText = "书库中的副本和批注会一起删除，原始文件不受影响。建议先导出笔记。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            if currentID == book.id { closeBook() }
            for annotation in annotations where annotation.bookID == book.id { try store?.remove(kind: "annotation", id: annotation.id.uuidString) }
            for mark in queryMarks where mark.bookID == book.id { try store?.remove(kind: "queryMark", id: mark.id.uuidString) }
            try store?.remove(kind: "book", id: book.id)
            NSApp.mainWindow?.undoManager?.removeAllActions(withTarget: self)
            try FileManager.default.removeItem(at: root.appendingPathComponent("Books/\(book.id)"))
            try reload()
        } catch { self.error = error.localizedDescription }
    }
    func settings(_ change: (inout ReadingSettings) -> Void) {
        guard var book = currentBook else { return }; change(&book.settings); saveBook(book)
        bridge.send(["action": "settings", "settings": json(book.settings)])
    }
    func initialCommand() -> [String: Any]? {
        guard let book = currentBook else { return nil }
        return ["action": "open", "url": "leaf://publication/\(book.id)/\(book.packagePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? book.packagePath)", "location": book.location ?? "", "settings": json(book.settings), "annotations": renderedAnnotations.map { json($0) }]
    }
    func receive(_ name: String, _ body: [String: Any]) {
        switch name {
        case "ready": readerReady = true
        case "pagination":
            currentPage=body["current"] as? Int ?? 0; totalPages=body["total"] as? Int ?? 0
            paginating=body["loading"] as? Bool ?? false; paginationError=body["error"] as? String
            if !paginating,totalPages>1,currentPage>0,var book=currentBook {
                let progress=Double(currentPage-1)/Double(totalPages-1)
                if abs(book.progression-progress)>0.0001 { progressTask?.cancel();book.progression=progress;saveBook(book) }
            }
        case "toc": toc = decode([TOCEntry].self, body["items"]) ?? []
        case "location":
            guard var book = currentBook else { return }
            book.location = body["cfi"] as? String
            book.progression = min(1, max(0, body["progress"] as? Double ?? 0))
            chapter = body["chapter"] as? String ?? ""
            if let index = books.firstIndex(where: { $0.id == book.id }) { books[index] = book }
            progressTask?.cancel()
            let bookID=book.id
            progressTask = Task {
                try? await Task.sleep(for:.milliseconds(500))
                if !Task.isCancelled,let latest=books.first(where:{$0.id==bookID}) { saveBook(latest) }
            }
        case "selection":
            let text = body["text"] as? String ?? ""
            if text.isEmpty { selection = nil; return }
            selection = TextSelection(cfi: body["cfi"] as? String ?? "", text: text, href: body["href"] as? String ?? "", prefix: body["prefix"] as? String ?? "", suffix: body["suffix"] as? String ?? "", chapter: chapter)

        case "selectionAction":
            guard let selection else { return }
            switch body["action"] as? String {
            case "dictionary": lookup(selection.text)
            case "analysis": analyze(selection.text)
            case "highlight": annotate(kind: highlightStyle.kind, color: highlightStyle.color)
            case "bookmark": bookmarkSelection()
            default: break
            }
        case "noteCreate": createFreeNote(body)
        case "noteSave": saveFreeNote(body)
        case "context": break // The WebKit coordinator presents the native context menu.
        case "unresolved": unresolved = Set(body["ids"] as? [String] ?? [])
        case "search": searchResults = decode([SearchHit].self, body["items"]) ?? []; searching = false
        case "error": readingError = body["message"] as? String ?? "无法显示这本书。"; searching = false
        default: break
        }
    }
    func annotate(kind: String, color: String = "yellow", withNote: Bool = false) {
        guard let book = currentBook, let selection, !selection.cfi.isEmpty else { return }
        var item = annotations.first { $0.bookID == book.id && $0.cfi == selection.cfi && $0.kind == kind } ?? Annotation(bookID: book.id, cfi: selection.cfi, href: selection.href, quote: selection.text, prefix: selection.prefix, suffix: selection.suffix, chapter: selection.chapter, kind: kind, color: color)
        item.color = color
        if withNote { editingAnnotation = item; noteText = "" }
        else { persist(item) }
    }
    func edit(_ item: Annotation) {
        if item.kind == "freeNote" {
            go(item.cfi)
            Task { try? await Task.sleep(for: .milliseconds(300)); bridge.send(["action":"focusNote","id":item.id.uuidString]) }
            return
        }
        editingAnnotation = item; noteText = item.note; showInspector = true; inspector = "notes" }
    func saveNote() { guard var item = editingAnnotation else { return }; item.note = noteText; persist(item); rememberHighlight(item); editingAnnotation = nil; showInspector = true; inspector = "notes" }
    func persist(_ item: Annotation) {
        let previous = annotations.first { $0.id == item.id }
        do {
            try store?.save(item, kind: "annotation", id: item.id.uuidString)
            annotations.removeAll { $0.id == item.id }; annotations.append(item)
            refreshAnnotations(); selection = nil
            NSApp.mainWindow?.undoManager?.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { if let previous { target.persist(previous) } else { target.deleteAnnotation(item) } }
            }
            NSApp.mainWindow?.undoManager?.setActionName(previous == nil ? "添加批注" : "编辑批注")
        } catch { self.error = error.localizedDescription }
    }
    func deleteAnnotation(_ item: Annotation) {
        do {
            try store?.remove(kind: "annotation", id: item.id.uuidString); annotations.removeAll { $0.id == item.id }; refreshAnnotations()
            // Register an inverse operation with the window's native Undo manager.
            NSApp.mainWindow?.undoManager?.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { target.persist(item) } }
            NSApp.mainWindow?.undoManager?.setActionName("删除批注")
        } catch { self.error = error.localizedDescription }
    }
    func refreshAnnotations() { bridge.send(["action": "annotations", "items": renderedAnnotations.map { json($0) }]) }
    func bookmark() {
        guard let book = currentBook, let cfi = book.location else { return }
        persist(Annotation(bookID: book.id, cfi: cfi, quote: chapter.isEmpty ? "阅读位置" : chapter, chapter: chapter, kind: "bookmark"))
    }
    func go(_ target: String) { bridge.send(["action": "go", "target": target]); selection = nil }
    func goToPage(_ page: Int) {
        guard readerReady,!paginating,page>=1,page<=totalPages else { return }
        selection=nil;bridge.send(["action":"page","page":page])
    }
    func search() { guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; searching = true; bridge.send(["action": "search", "query": searchQuery]) }
    func lookup(_ word: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        lookupWord = word; inspector = "dictionary"; showInspector = true; lookingUp = true
        lookupTask?.cancel(); let records = dictionaries, mark = queryMark(for: word)
        lookupTask = Task {
            let result = await dictionaryService.lookup(word, records: records)
            guard !Task.isCancelled else { return }; lookupResults = result; lookingUp = false
            if !records.isEmpty {
                if let mark { saveQueryMark(mark) }
                recordHistory(QueryHistory(kind: "dictionary", query: word, dictionaries: result.map { DictionarySnapshot(id: $0.0, name: $0.1, html: $0.2) }))
            }
        }
    }
    func pickDictionaries() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "mdx") ?? .data]; panel.allowsMultipleSelection = true
        panel.message = "选择 MDX 词库；配套 MDD 文件请放在同一文件夹"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls; busy = true
        Task {
            var failures: [String] = []
            for url in urls {
                do {
                    if dictionaries.contains(where: { $0.path == url.path }) { continue }
                    let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                    let record = DictionaryRecord(name: url.deletingPathExtension().lastPathComponent, path: url.path, bookmark: bookmark, priority: dictionaries.count)
                    _ = try await dictionaryService.open(record)
                    try store?.save(record, kind: "dictionary", id: record.id.uuidString); dictionaries.append(record)
                } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            }
            busy = false
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
            if !lookupWord.isEmpty { lookup(lookupWord) }
        }
    }
    func moveDictionary(_ record: DictionaryRecord, by offset: Int) {
        guard let index = dictionaries.firstIndex(where: { $0.id == record.id }), dictionaries.indices.contains(index+offset) else { return }
        dictionaries.swapAt(index,index+offset)
        do {
            for i in dictionaries.indices {
                dictionaries[i].priority = i
                try store?.save(dictionaries[i], kind: "dictionary", id: dictionaries[i].id.uuidString)
            }
        } catch { self.error = error.localizedDescription }
    }
    func removeDictionary(_ record: DictionaryRecord) {
        do {
            try store?.remove(kind: "dictionary", id: record.id.uuidString); dictionaries.removeAll { $0.id == record.id }
            Task { await dictionaryService.remove(record.id) }
            lookupResults = []
        } catch { self.error = error.localizedDescription }
    }
    func exportMarkdown() {
        guard let book = currentBook else { return }
        saveFile(Exporter.markdown(book: book, annotations: currentAnnotations).data(using: .utf8)!, name: "\(book.title)-笔记.md", type: UTType(filenameExtension: "md") ?? .plainText)
    }
    func exportBackup() {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            saveFile(try encoder.encode(Backup(books: books, annotations: annotations)), name: "页间-笔记备份.json", type: .json)
        } catch { self.error = error.localizedDescription }
    }
    private func saveFile(_ data: Data, name: String, type: UTType) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
    }
    func restoreBackup() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store?.restore(JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))); try reload(); if currentID != nil { refreshAnnotations() } }
        catch { self.error = error.localizedDescription }
    }
}

func json<T: Encodable>(_ value: T) -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) ?? [:] }
func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
    guard let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}
