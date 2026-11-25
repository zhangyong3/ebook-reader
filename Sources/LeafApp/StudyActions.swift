import SwiftUI
import LeafCore

extension AppModel {
    /// Capture the exact source before an asynchronous query can outlive the selection or book.
    func queryMark(for query: String) -> Annotation? {
        guard let bookID=currentID, let selected=selection, !selected.cfi.isEmpty else { return nil }
        func canonical(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator:" ").lowercased() }
        guard canonical(selected.text)==canonical(query) else { return nil }
        return Annotation(bookID:bookID,cfi:selected.cfi,href:selected.href,quote:selected.text,prefix:selected.prefix,suffix:selected.suffix,chapter:selected.chapter,kind:"queried",color:"green")
    }
    func saveQueryMark(_ mark: Annotation) {
        guard books.contains(where: { $0.id==mark.bookID }), !queryMarks.contains(where: { $0.bookID==mark.bookID && $0.cfi==mark.cfi }) else { return }
        do {
            try store?.save(mark,kind:"queryMark",id:mark.id.uuidString)
            queryMarks.append(mark); refreshAnnotations()
        } catch { self.error=error.localizedDescription }
    }

    func recordHistory(_ item: QueryHistory) {
        do {
            try store?.save(item,kind:"history",id:item.id)
            queryHistory.removeAll { $0.id == item.id }; queryHistory.insert(item,at:0)
        } catch { self.error=error.localizedDescription }
    }
    func openHistory(_ item: QueryHistory) {
        lookupTask?.cancel(); lookupTask=nil
        showInspector=true
        if item.kind == "dictionary" {
            inspector="dictionary"; lookupWord=item.query
            lookingUp=true; lookupResults=[]
            let records=dictionaries.filter { record in item.dictionaries.contains(where: { $0.id==record.id }) }
            lookupTask=Task {
                for record in records { _ = try? await dictionaryService.open(record) }
                guard !Task.isCancelled else { return }
                lookupResults=item.dictionaries.map { ($0.id,$0.name,$0.html) }; lookingUp=false
            }
        } else {
            stopAnalysis()
            inspector="analysis"; analysisQuery=item.query; analysisText=item.analysis
            analysisStatus=item.status; analysisError=nil; analysisModel=item.model ?? ""
        }
        var recent=item; recent.updatedAt=Date(); recordHistory(recent)
    }
    func deleteHistory(_ item: QueryHistory) {
        do { try store?.remove(kind:"history",id:item.id); queryHistory.removeAll { $0.id==item.id } }
        catch { self.error=error.localizedDescription }
    }
    func analyze(_ query: String) {
        let text=query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= 12000 else { error="一次最多解析 12,000 个字符，请缩短选区。"; return }
        stopAnalysis()
        analysisQuery=text; analysisText=""; analysisError=nil; inspector="analysis"; showInspector=true
        let configuration=apiConfiguration
        let key: String
        do {
            _ = try configuration.endpoint()
            guard !configuration.model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  let saved=try LocalAPIKeyStore(root:root).read(baseURL:configuration.baseURL), !saved.isEmpty else {
                analysisStatus="idle"; analysisError="先在软件设置中填写 Base URL、Key 和模型，然后重新解析。"; showSettings=true; return
            }
            key=saved
        } catch { analysisStatus="failed"; analysisError=error.localizedDescription; return }
        startAnalysis(text, configuration:configuration, key:key)
    }
    /// The same streaming path is used by the opt-in local integration check, with a disposable test key.
    func startAnalysis(_ text: String, configuration: APIConfiguration, key: String) {
        stopAnalysis()
        analysisQuery=text; analysisText=""; analysisError=nil; analysisStatus="loading"; analysisModel=configuration.model
        inspector="analysis"; showInspector=true
        let run=UUID(), mark=queryMark(for:text); analysisRunID=run
        var marked=false
        analysisTask=Task { [self] in
            do {
                let reason=try await OpenAIClient().stream(query:text,configuration:configuration,key:key) { [self] chunk in
                    guard analysisRunID==run else { return }
                    analysisText += chunk; analysisStatus="streaming"
                    if !marked, let mark { marked=true; saveQueryMark(mark) }
                }
                guard analysisRunID==run else { return }
                analysisStatus=reason; saveAnalysisHistory()
            } catch {
                guard analysisRunID==run else { return }
                if Task.isCancelled { analysisStatus="stopped" }
                else { analysisStatus="failed"; analysisError=error.localizedDescription }
                saveAnalysisHistory()
            }
            if analysisRunID==run { analysisTask=nil }
        }
    }
    func saveAnalysisHistory() {
        guard !analysisText.isEmpty else { return }
        recordHistory(QueryHistory(kind:"analysis",query:analysisQuery,analysis:analysisText,status:analysisStatus,model:analysisModel))
    }
    func stopAnalysis() {
        if analysisTask != nil {
            analysisTask?.cancel(); analysisTask=nil
            analysisStatus="stopped"; saveAnalysisHistory(); analysisRunID=UUID()
        }
    }
    func saveAPIConfiguration(_ configuration: APIConfiguration, newKey: String) throws {
        _ = try configuration.endpoint()
        guard !configuration.model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw LeafError.invalid("请填写模型名称。") }
        try LocalAPIKeyStore(root:root).save(newKey,baseURL:configuration.baseURL)
        try store?.save(configuration,kind:"apiConfiguration",id:"openai")
        apiConfiguration=configuration
    }
    func rememberHighlight(_ item: Annotation) {
        guard ["highlight","underline","strikethrough"].contains(item.kind) else { return }
        highlightStyle.kind=item.kind; highlightStyle.color=item.color
        do { try store?.save(highlightStyle,kind:"highlightStyle",id:"default") }
        catch { self.error=error.localizedDescription }
    }
    func changeHighlight(_ id: UUID, kind: String? = nil, color: String? = nil) {
        guard var item=annotations.first(where: { $0.id==id }) else { return }
        if let kind { item.kind=kind }; if let color { item.color=color }
        persist(item); rememberHighlight(item)
    }
    func bookmarkSelection() {
        guard let selected=selection, let book=currentBook else { return }
        let item=Annotation(bookID:book.id,cfi:selected.cfi,href:selected.href,quote:selected.text,chapter:chapter,kind:"bookmark")
        if !currentAnnotations.contains(where: { $0.kind=="bookmark" && $0.cfi==item.cfi }) { persist(item) }
    }
    func createFreeNote(_ body: [String:Any]) {
        guard let idString=body["id"] as? String, let id=UUID(uuidString:idString), let book=currentBook,
              let cfi=body["cfi"] as? String, !cfi.isEmpty else { return }
        var item=Annotation(bookID:book.id,cfi:cfi,href:body["href"] as? String ?? "",quote:"",chapter:chapter,kind:"freeNote")
        item.id=id; item.placement=NotePlacement(offsetX:body["offsetX"] as? Double ?? 0,offsetY:body["offsetY"] as? Double ?? 0)
        item.noteAppearance=NoteAppearance()
        persist(item)
    }
    func saveFreeNote(_ body: [String:Any]) {
        guard let idString=body["id"] as? String, let id=UUID(uuidString:idString), var item=annotations.first(where: { $0.id==id && $0.kind=="freeNote" }) else { return }
        item.note=String((body["text"] as? String ?? "").prefix(20000))
        if body["final"] as? Bool == true && item.note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { deleteAnnotation(item) }
        else {
            // Draft autosave must not fill Undo with every keystroke or replace the focused editor.
            do {
                try store?.save(item,kind:"annotation",id:item.id.uuidString)
                if let index=annotations.firstIndex(where: { $0.id==item.id }) { annotations[index]=item }
            } catch { self.error=error.localizedDescription }
        }
    }
    func styleFreeNote(_ id: UUID, font: String? = nil, color: String? = nil, size: Double? = nil) {
        guard var item=annotations.first(where: { $0.id==id && $0.kind=="freeNote" }) else { return }
        var style=item.noteAppearance ?? NoteAppearance()
        if let font { style.font=font }; if let color { style.color=color }; if let size { style.size=size }
        item.noteAppearance=style; persist(item)
    }
}
