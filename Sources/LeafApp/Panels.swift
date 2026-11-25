import SwiftUI
import LeafCore

struct NavigationPanel: View {
    @ObservedObject var model:AppModel
    @State private var tab="toc"
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if model.searchVisible {
                HStack {
                    TextField("搜索本书",text:$model.searchQuery).textFieldStyle(.roundedBorder).onSubmit(model.search).focused($searchFocused).onAppear { searchFocused = true }.accessibilityLabel("搜索本书")
                    Button(action:model.search) { Image(systemName:"magnifyingglass") }.accessibilityLabel("开始搜索").disabled(model.searching)
                }.padding(.horizontal,12)
                if model.searching { ProgressView().controlSize(.small).padding(.horizontal,12) }
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:0) {
                        ForEach(model.searchResults) { hit in
                            Button { model.go(hit.cfi) } label: { Text(hit.excerpt).font(.callout).foregroundStyle(.primary).multilineTextAlignment(.leading).padding(12).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                Text(model.searchResults.isEmpty ? "输入关键词后按回车" : "\(model.searchResults.count) 个结果，最多显示 300 个").font(.caption).foregroundStyle(.secondary).padding(12)
                Button("返回目录") { model.searchVisible=false }.padding(.horizontal,12)
            } else {
                Picker("导航",selection:$tab) { Text("目录").tag("toc"); Text("书签").tag("bookmarks") }.pickerStyle(.segmented).labelsHidden().padding(.horizontal,12)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:0) {
                        if tab=="toc" {
                            ForEach(model.toc) { item in
                                Button { model.go(item.href) } label: {
                                    Text(item.label).font(.callout).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                        .padding(.vertical,10).padding(.leading,14+CGFloat(min(5,item.depth))*12).padding(.trailing,12).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            if model.toc.isEmpty { Text("这本书没有目录").font(.callout).foregroundStyle(.secondary).padding(14) }
                        } else {
                            let bookmarks=model.currentAnnotations.filter { $0.kind=="bookmark" }
                            ForEach(bookmarks) { item in
                                Button { model.go(item.cfi) } label: {
                                    Label(item.quote,systemImage:"bookmark").font(.callout).multilineTextAlignment(.leading).padding(14).frame(maxWidth:.infinity,alignment:.leading)
                                }.buttonStyle(.plain).contextMenu { Button("删除书签",role:.destructive) { model.deleteAnnotation(item) } }
                            }
                            if bookmarks.isEmpty { Text("按 ⌘D 保存当前阅读位置").font(.callout).foregroundStyle(.secondary).padding(14) }
                        }
                    }
                }
            }
        }.padding(.vertical,16).background(Color(nsColor:.controlBackgroundColor))
    }
}

struct InspectorPanel: View {
    @ObservedObject var model:AppModel
    @State private var selectedDictionary:UUID?
    @State private var noteQuery=""
    var body: some View {
        VStack(spacing:0) {
            Picker("检查器",selection:$model.inspector) { Text("查词").tag("dictionary"); Text("语句解析").tag("analysis"); Text("历史").tag("history"); Text("笔记").tag("notes") }.pickerStyle(.segmented).labelsHidden().controlSize(.small).padding(12)
            if model.inspector=="dictionary" {
                HStack {
                    TextField("输入单词",text:$model.lookupWord).textFieldStyle(.roundedBorder).onSubmit { model.lookup(model.lookupWord) }.accessibilityLabel("查询离线词典")
                    Button { model.lookup(model.lookupWord) } label: { Image(systemName:"magnifyingglass") }.accessibilityLabel("查词").disabled(model.lookupWord.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }.padding(.horizontal,14).padding(.bottom,12)
                if model.lookingUp { ProgressView("正在查询…").padding() }
                if model.dictionaries.isEmpty && model.lookupResults.isEmpty {
                    VStack(alignment:.leading,spacing:12) {
                        Text("添加你的离线词典").font(.headline)
                        Text("导入 MDX 词库，配套 MDD 放在同一文件夹。选中文字后点击浮动工具栏的查词图标。") .font(.callout).foregroundStyle(.secondary)
                        Button("导入词典…",action:model.pickDictionaries).disabled(model.busy)
                    }.padding(18)
                    Spacer()
                } else if !model.lookupResults.isEmpty {
                    Picker("词典",selection:Binding(get:{selectedDictionary ?? model.lookupResults[0].0},set:{selectedDictionary=$0})) {
                        ForEach(model.lookupResults,id:\.0) { result in Text(result.1).tag(result.0) }
                    }.labelsHidden().padding(.horizontal,14).padding(.bottom,8)
                    if let result=model.lookupResults.first(where: { $0.0==selectedDictionary }) ?? model.lookupResults.first {
                        DictionaryWebView(id:result.0,html:result.2,model:model).id(result.0)
                    }
                } else if model.lookingUp { Spacer() }
                else {
                    Text("选中文字后点击查词图标，或在上方输入。") .font(.callout).foregroundStyle(.secondary).padding(18)
                    Spacer()
                }
                Divider()
                Button("管理词典…") { model.showDictionaries=true }.buttonStyle(.borderless).padding(12)
            } else if model.inspector == "analysis" {
                AnalysisPanel(model:model)
            } else if model.inspector == "history" {
                HistoryPanel(model:model)
            } else {
                HStack {
                    TextField("搜索摘录和笔记",text:$noteQuery).textFieldStyle(.roundedBorder).accessibilityLabel("搜索本书笔记")
                    Button(action:model.exportMarkdown) { Image(systemName:"square.and.arrow.up") }.accessibilityLabel("导出本书笔记").help("导出 Markdown")
                }.padding(.horizontal,14).padding(.bottom,12)
                let notes=model.currentAnnotations.filter { $0.kind != "bookmark" && (noteQuery.isEmpty || ($0.quote+" "+$0.note).localizedCaseInsensitiveContains(noteQuery)) }
                if notes.isEmpty { Text("选中文字可高亮；双击正文空白处可创建即时笔记。") .font(.callout).foregroundStyle(.secondary).padding(18); Spacer() }
                else {
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:0) {
                            ForEach(notes) { item in
                                VStack(alignment:.leading,spacing:9) {
                                    HStack(alignment:.top) {
                                        Image(systemName:item.kind=="underline" ? "underline" : "highlighter").foregroundStyle(.secondary)
                                        Text(item.chapter.isEmpty ? "摘录" : item.chapter).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        Spacer(minLength:0)
                                    }
                                    Button { model.go(item.cfi) } label: { Text(item.kind == "freeNote" ? (item.note.isEmpty ? "即时笔记" : item.note) : item.quote).font(.system(size:14)).foregroundStyle(.primary).multilineTextAlignment(.leading).lineLimit(7) }.buttonStyle(.plain)
                                    if !item.note.isEmpty && item.kind != "freeNote" { Text(item.note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                                    if model.unresolved.contains(item.id.uuidString) { Label("原文位置待确认",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                                    HStack {
                                        Button("编辑") { model.edit(item) }
                                        Spacer()
                                        Button { model.deleteAnnotation(item) } label: { Image(systemName:"trash") }.accessibilityLabel("删除这条笔记")
                                    }.buttonStyle(.borderless).font(.caption)
                                }.padding(16)
                                .contextMenu {
                                    Button("跳转原文") { model.go(item.cfi) }
                                    Button("编辑笔记") { model.edit(item) }
                                    Button("删除",role:.destructive) { model.deleteAnnotation(item) }
                                }
                                Divider()
                            }
                        }
                    }
                }
            }
        }.background(Color(nsColor:.controlBackgroundColor))
    }
}

struct NoteEditor: View {
    @ObservedObject var model:AppModel
    let item:Annotation
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("编辑笔记").font(.title2.weight(.semibold))
            ScrollView { Text(item.quote).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(maxHeight:120)
            Divider()
            TextEditor(text:$model.noteText).font(.body).frame(minHeight:160).overlay(RoundedRectangle(cornerRadius:4).stroke(.separator,lineWidth:0.5)).accessibilityLabel("笔记内容")
            HStack {
                Picker("样式",selection:Binding(get:{model.editingAnnotation?.kind ?? item.kind},set:{model.editingAnnotation?.kind=$0})) { Text("高亮").tag("highlight"); Text("下划线").tag("underline"); Text("删除线").tag("strikethrough") }.frame(width:170)
                Picker("颜色",selection:Binding(get:{model.editingAnnotation?.color ?? item.color},set:{model.editingAnnotation?.color=$0})) { Text("黄色").tag("yellow"); Text("绿色").tag("green"); Text("粉色").tag("pink") }.frame(width:150)
                Spacer()
            }
            HStack { Spacer(); Button("取消") { model.editingAnnotation=nil }.keyboardShortcut(.cancelAction); Button("保存",action:model.saveNote).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width:510)
    }
}

struct DictionaryManager: View {
    @ObservedObject var model:AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { Text("离线词典").font(.title2.weight(.semibold)); Spacer(); Button("导入 MDX…",action:model.pickDictionaries).disabled(model.busy) }
            Text("词库保留在原位置。请将同名 MDD、CSS 和音频资源放在同一文件夹，避免导入后移动文件。") .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(model.dictionaries) { item in
                    HStack {
                        VStack(alignment:.leading,spacing:5) { Text(item.name); Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
                        Spacer()
                        Button { model.moveDictionary(item,by:-1) } label: { Image(systemName:"arrow.up") }.buttonStyle(.borderless).accessibilityLabel("提高词典优先级")
                        Button { model.moveDictionary(item,by:1) } label: { Image(systemName:"arrow.down") }.buttonStyle(.borderless).accessibilityLabel("降低词典优先级")
                        Button { model.removeDictionary(item) } label: { Image(systemName:"minus.circle") }.buttonStyle(.borderless).accessibilityLabel("移除词典 \(item.name)")
                    }.padding(.vertical,6)
                }
                if model.dictionaries.isEmpty && model.lookupResults.isEmpty { Text("尚未导入词典").foregroundStyle(.secondary) }
            }.frame(height:230)
            Text("支持 MDX/MDD 2.x 的常见编码与索引混淆。不支持需要注册密码、非空 Compact 样式模板和 1.x/3.x 词库。") .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("完成") { model.showDictionaries=false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width:560)
    }
}
