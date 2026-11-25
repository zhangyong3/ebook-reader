import SwiftUI
import LeafCore

struct AnalysisPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text("语句解析").font(.headline)
                Spacer()
                Button { model.showSettings=true } label: { Image(systemName:"gearshape") }.help("OpenAI 设置").accessibilityLabel("OpenAI 设置")
            }.padding(.horizontal,14).padding(.bottom,10)
            if model.analysisQuery.isEmpty {
                Text("选中一句话，点击鼠标旁的翻译图标，可查看翻译、语法、短语和词汇讲解。")
                    .font(.callout).foregroundStyle(.secondary).padding(16)
                Button("配置 OpenAI…") { model.showSettings=true }.padding(.horizontal,16)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        Text(model.analysisQuery).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Divider()
                        if model.analysisStatus=="loading" { HStack { ProgressView().controlSize(.small); Text("正在连接模型…").font(.callout) } }
                        if !model.analysisText.isEmpty { AnalysisText(text:model.analysisText) }
                        if let error=model.analysisError { Label(error,systemImage:"exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                        if ["loading","streaming"].contains(model.analysisStatus) { Text("正在逐步生成…").font(.caption).foregroundStyle(.secondary) }
                        else if model.analysisStatus=="stopped" { Text("已停止，已收到的内容已保留。") .font(.caption).foregroundStyle(.secondary) }
                        else if model.analysisStatus=="length" { Text("达到模型输出长度限制，已保存当前内容。") .font(.caption).foregroundStyle(.secondary) }
                        else if model.analysisStatus=="filtered" { Text("模型服务中止了部分内容，已保存收到的解析。") .font(.caption).foregroundStyle(.secondary) }
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                }
                Divider()
                HStack {
                    Text(model.analysisModel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if ["loading","streaming"].contains(model.analysisStatus) { Button("停止",action:model.stopAnalysis) }
                    else { Button("重新解析") { model.analyze(model.analysisQuery) } }
                }.padding(12)
            }
        }
    }
}
struct AnalysisText: View {
    let text: String
    private var blocks: [String] {
        var result: [String] = [], paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { result.append(paragraph.joined(separator:"\n")); paragraph.removeAll() } }
        for line in text.replacingOccurrences(of:"\r\n",with:"\n").components(separatedBy:"\n") {
            if line.hasPrefix("#") { flush(); result.append(line) }
            else if line.trimmingCharacters(in:.whitespaces).isEmpty { flush() }
            else { paragraph.append(line) }
        }
        flush(); return result
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            ForEach(Array(blocks.enumerated()),id:\.offset) { _, block in
                if block.hasPrefix("#") {
                    Text(String(block.drop(while: { $0 == "#" || $0 == " " }))).font(.headline)
                } else {
                    Text((try? AttributedString(markdown:block,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(block))
                        .font(.system(size:15)).lineSpacing(5).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                }
            }
        }
    }
}
struct HistoryPanel: View {
    @ObservedObject var model: AppModel
    @State private var query=""
    var body: some View {
        VStack(spacing:0) {
            TextField("搜索查询历史",text:$query).textFieldStyle(.roundedBorder).padding(.horizontal,14).padding(.bottom,12).accessibilityLabel("搜索查询历史")
            let items=model.queryHistory.filter { query.isEmpty || $0.query.localizedCaseInsensitiveContains(query) }
            if items.isEmpty { Text("查词和语句解析的结果会保存在这里。相同内容只保留最近一次。") .font(.callout).foregroundStyle(.secondary).padding(16); Spacer() }
            else {
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:0) {
                        ForEach(items) { item in
                            Button { model.openHistory(item) } label: {
                                VStack(alignment:.leading,spacing:7) {
                                    Label(item.kind=="dictionary" ? "离线查词" : "语句解析",systemImage:item.kind=="dictionary" ? "character.book.closed" : "text.bubble").font(.caption).foregroundStyle(.secondary)
                                    Text(item.query).font(.callout).foregroundStyle(.primary).lineLimit(3).multilineTextAlignment(.leading)
                                    Text(item.updatedAt,style:.date).font(.caption2).foregroundStyle(.secondary)
                                }.padding(14).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).contextMenu { Button("删除这条历史",role:.destructive) { model.deleteHistory(item) } }
                            Divider()
                        }
                    }
                }
            }
        }
    }
}
struct SoftwareSettings: View {
    @ObservedObject var model: AppModel
    @State private var configuration=APIConfiguration()
    @State private var key=""
    @State private var message: String?
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("软件设置").font(.title2.weight(.semibold))
            Text("OpenAI 语句解析").font(.headline)
            Form {
                TextField("Base URL",text:$configuration.baseURL).textFieldStyle(.roundedBorder)
                SecureField("API Key",text:$key,prompt:Text("填写 API Key")).textFieldStyle(.roundedBorder)
                TextField("模型",text:$configuration.model,prompt:Text("填写服务端支持的模型名称")).textFieldStyle(.roundedBorder)
            }
            Text("使用 OpenAI 兼容 Chat Completions 流式接口。Base URL 通常以 /v1 结尾；Key 保存在本机，清空后保存即可删除。点击解析后，只发送选中的语句。") .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.callout).foregroundStyle(.orange) }
            Divider()
            HStack {
                Text("离线词典").font(.headline)
                Spacer()
                Button("管理词典…") { model.showSettings=false; DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { model.showDictionaries=true } }
            }
            Spacer(minLength:0)
            HStack {
                Spacer()
                Button("取消") { model.showSettings=false }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try model.saveAPIConfiguration(configuration,newKey:key); key=""; model.showSettings=false }
                    catch { message=error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:530).frame(minHeight:350)
            .onAppear { configuration=model.apiConfiguration; loadKey() }
            .onChange(of:configuration.baseURL) { _, _ in loadKey() }
    }
    private func loadKey() {
        do { key=try LocalAPIKeyStore(root:model.root).read(baseURL:configuration.baseURL) ?? ""; message=nil }
        catch { key=""; message=error.localizedDescription }
    }
}
