import SwiftUI
import LeafCore

private let forest = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedRed: 0.60, green: 0.78, blue: 0.67, alpha: 1)
        : NSColor(calibratedRed: 0.26, green: 0.40, blue: 0.33, alpha: 1)
})

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Group {
            if let book = model.currentBook { ReadingView(model: model, book: book) }
            else { LibraryView(model: model) }
        }
        .tint(forest)
        .overlay(alignment: .bottom) {
            if model.busy {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在导入…").font(.callout) }
                    .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 8)).padding(20)
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.showSettings) { SoftwareSettings(model: model) }
        .sheet(isPresented: $model.showDictionaries) { DictionaryManager(model: model) }
        .sheet(item: $model.editingAnnotation) { item in NoteEditor(model: model, item: item) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !model.busy else { return false }
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url, url.pathExtension.lowercased() == "epub" { urls.append(url) }
                }
                if !urls.isEmpty { model.importBooks(urls) }
            }
            return true
        }
    }
}

struct LibraryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("书库").font(.system(size: 30, weight: .semibold))
                Text("\(model.books.count) 本书").font(.callout).foregroundStyle(.secondary)
                Spacer()
                TextField("搜索书名或作者", text: $model.libraryQuery).textFieldStyle(.roundedBorder).frame(width: 240).accessibilityLabel("搜索书库")
            }.padding(.horizontal,40).padding(.top,30).padding(.bottom,24)
            Divider()
            if model.books.isEmpty {
                HStack {
                    VStack(alignment: .leading, spacing: 18) {
                        Image(systemName: "book.closed").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(forest).accessibilityHidden(true)
                        Text("从一本书开始").font(.system(size: 25, weight: .medium))
                        Text("拖入 EPUB，或从电脑中选择。\n阅读位置、摘录和笔记都会保存在本机。")
                            .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
                        HStack(spacing: 14) {
                            Button("导入 EPUB…", action: model.pickBooks).buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
                            Button("打开使用指南") {
                                if let url = Bundle.module.url(forResource: "Guide", withExtension: "epub") { model.importBooks([url]) }
                            }.buttonStyle(.borderless).disabled(model.busy)
                        }.padding(.top,8)
                        Label("离线查词 · 文字批注 · Markdown 导出", systemImage: "externaldrive").font(.caption).foregroundStyle(.secondary).padding(.top,20)
                    }.padding(.leading,80)
                    Spacer()
                }.frame(maxHeight: .infinity)
            } else if model.visibleBooks.isEmpty {
                ContentUnavailableView.search(text: model.libraryQuery)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleBooks) { book in
                            Button { model.open(book) } label: {
                                HStack(spacing: 20) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 4).fill(forest.opacity(0.10)).frame(width: 52,height: 68)
                                        Image(systemName: "book.closed").font(.system(size: 24,weight: .light)).foregroundStyle(forest)
                                    }
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(book.title).font(.system(size: 17,weight: .medium)).foregroundStyle(.primary).lineLimit(2)
                                        Text(book.author).font(.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 24)
                                    VStack(alignment: .trailing, spacing: 8) {
                                        Text(book.progression > 0 ? "已读 \(Int(book.progression*100))%" : "开始阅读").font(.callout).foregroundStyle(forest)
                                        Text(book.lastOpened, style: .date).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }.padding(.vertical,20).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .contextMenu { Button("打开") { model.open(book) }; Button("从书库移除…",role: .destructive) { model.removeBook(book) } }
                            Divider()
                        }
                    }.padding(.horizontal,40)
                }
            }
        }
        .navigationTitle("页间")
        .toolbar {
            ToolbarItem { Button(action: model.pickBooks) { Label("导入 EPUB",systemImage: "plus") }.help("导入 EPUB（⌘O）").disabled(model.busy) }
            ToolbarItem { Button { model.showDictionaries = true } label: { Label("管理词典", systemImage: "character.book.closed") }.help("管理离线词典") }
        }
    }
}

struct ReadingView: View {
    @ObservedObject var model: AppModel
    let book: Book
    @State private var showTypography = false
    var paper: Color { book.settings.theme == "dark" ? Color(red: 0.126,green: 0.138,blue: 0.126) : book.settings.theme == "light" ? .white : Color(red: 0.969,green: 0.957,blue: 0.925) }
    var body: some View {
        VStack(spacing:0) {
            HSplitView {
                HStack(spacing:0) {
                    if model.showTOC { NavigationPanel(model:model).frame(width:210); Divider() }
                    ZStack(alignment:.bottom) {
                        paper
                        ReaderWebView(model:model).id(model.sessionID)
                        if !model.readerReady && model.readingError == nil { ProgressView("正在打开书籍…").padding(24).background(paper) }
                        if let message = model.readingError {
                            VStack(spacing:12) {
                                Label("无法完成阅读操作",systemImage:"exclamationmark.triangle").font(.headline)
                                Text(message).font(.callout).textSelection(.enabled).multilineTextAlignment(.center)
                                HStack { Button("返回书库",action:model.closeBook); Button("重新打开") { model.open(book) } }
                            }.padding(32).frame(maxWidth:460).background(.background,in:RoundedRectangle(cornerRadius:8)).frame(maxHeight:.infinity)
                        }
                        }.frame(maxWidth:.infinity,maxHeight:.infinity)
                }.frame(minWidth: model.showTOC ? 571 : 360)
                if model.showInspector {
                    InspectorPanel(model:model)
                        .frame(minWidth:280, idealWidth:360, maxWidth:640)
                }
            }
            Divider()
            HStack(spacing:16) {
                Button { model.bridge.send(["action":"back"]) } label: { Image(systemName:"arrow.uturn.backward") }.help("返回跳转前的位置").accessibilityLabel("返回跳转前的位置")
                Text(model.chapter.isEmpty ? book.title : model.chapter).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                PageNavigator(model:model)
                Text("\(Int(book.progression*100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityLabel("阅读进度 \(Int(book.progression*100))%")
                Button { model.bridge.send(["action":"previous"]) } label: { Image(systemName:"chevron.left") }.help("上一页（←）").accessibilityLabel("上一页")
                Button { model.bridge.send(["action":"next"]) } label: { Image(systemName:"chevron.right") }.help("下一页（→）").accessibilityLabel("下一页")
            }.buttonStyle(.borderless).padding(.horizontal,20).frame(height:40).disabled(!model.readerReady)
        }
        .navigationTitle(book.title)
        .toolbar {
            ToolbarItem(placement:.navigation) { Button(action:model.closeBook) { Label("书库",systemImage:"chevron.left") }.help("返回书库（⌘L）") }
            ToolbarItem(placement:.navigation) { Button { model.showTOC.toggle() } label: { Label("目录",systemImage:"sidebar.left") }.help("目录和书签") }
            ToolbarItem { Button { model.showTOC = true; model.searchVisible.toggle() } label: { Label("搜索",systemImage:"magnifyingglass") }.help("搜索本书（⌘F）") }
            ToolbarItem { Button(action:model.bookmark) { Label("书签",systemImage:"bookmark") }.disabled(!model.readerReady).help("添加书签（⌘D）") }
            ToolbarItem {
                Button { showTypography.toggle() } label: { Label("排版",systemImage:"textformat.size") }.help("阅读排版")
                    .popover(isPresented:$showTypography) { TypographyPanel(model:model,settings:book.settings).padding(20).frame(width:290) }
            }
            ToolbarItem { Button { model.showInspector.toggle() } label: { Label("查词与笔记",systemImage:"sidebar.right") }.help("查词与笔记") }
        }
    }
}

struct TypographyPanel: View {
    @ObservedObject var model:AppModel
    let settings:ReadingSettings
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("阅读排版").font(.headline)
            HStack { Text("字号"); Spacer(); Text("\(Int(settings.fontSize))").monospacedDigit(); Button("−") { model.settings { $0.fontSize=max(14,$0.fontSize-2) } }; Button("＋") { model.settings { $0.fontSize=min(36,$0.fontSize+2) } } }
            Picker("字体",selection:Binding(get:{settings.font},set:{ value in model.settings { $0.font=value } })) { Text("宋体 / 衬线").tag("serif"); Text("系统黑体").tag("sans") }
            Picker("行距",selection:Binding(get:{settings.lineHeight},set:{value in model.settings { $0.lineHeight=value } })) { Text("紧凑").tag(1.5); Text("舒适").tag(1.8); Text("宽松").tag(2.1) }
            Picker("宽度",selection:Binding(get:{settings.width},set:{value in model.settings { $0.width=value } })) { Text("窄").tag(520.0); Text("适中").tag(680.0); Text("宽").tag(840.0) }
            Picker("主题",selection:Binding(get:{settings.theme},set:{value in model.settings { $0.theme=value } })) { Text("白昼").tag("light"); Text("纸色").tag("paper"); Text("夜读").tag("dark") }.pickerStyle(.segmented)
            Toggle("连续滚动",isOn:Binding(get:{settings.scrolling},set:{value in model.settings { $0.scrolling=value } }))
        }.font(.callout)
    }
}
