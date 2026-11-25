import SwiftUI
import AppKit

@main
struct LeafApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(LeafDelegate.self) private var delegate
    var body: some Scene {
        Window("页间", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 920, minHeight: 600)
                .onOpenURL { model.importBooks([$0]) }
                .onAppear {
                    delegate.model = model
                    NSApp.setActivationPolicy(.regular)
                    #if DEBUG
                    if let index = CommandLine.arguments.firstIndex(of: "--check-report"), CommandLine.arguments.count > index+1, !delegate.startedChecks {
                        delegate.startedChecks = true
                        Task { await DebugChecks.run(model: model, reportURL: URL(fileURLWithPath: CommandLine.arguments[index+1])) }
                    }
                    #endif
                    if let index = CommandLine.arguments.firstIndex(of: "--open"), CommandLine.arguments.count > index+1, !delegate.openedArguments {
                        delegate.openedArguments = true
                        model.importBooks([URL(fileURLWithPath: CommandLine.arguments[index+1])])
                    }
                }
        }
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { Button("导入 EPUB…", action: model.pickBooks).keyboardShortcut("o").disabled(model.busy) }
            CommandMenu("阅读") {
                Button("返回书库", action: model.closeBook).keyboardShortcut("l").disabled(model.currentID == nil)
                Divider()
                Button("上一页") { model.bridge.send(["action": "previous"]) }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(!model.readerReady)
                Button("下一页") { model.bridge.send(["action": "next"]) }.keyboardShortcut(.rightArrow, modifiers: .command).disabled(!model.readerReady)
                Button("搜索本书") { model.searchVisible = true; model.showTOC = true }.keyboardShortcut("f").disabled(model.currentID == nil)
                Button("添加书签", action: model.bookmark).keyboardShortcut("d").disabled(!model.readerReady)
                Button("高亮选区") { model.annotate(kind: model.highlightStyle.kind, color: model.highlightStyle.color) }.keyboardShortcut("h", modifiers: [.command,.shift]).disabled(model.selection == nil)
                Button("为选区添加笔记") { model.annotate(kind: "highlight", withNote: true) }.keyboardShortcut("n", modifiers: [.command,.shift]).disabled(model.selection == nil)
            }
            CommandMenu("笔记") {
                Button("导出本书 Markdown…", action: model.exportMarkdown).keyboardShortcut("e", modifiers: [.command,.shift]).disabled(model.currentID == nil)
                Button("备份全部笔记…", action: model.exportBackup)
                Button("恢复笔记备份…", action: model.restoreBackup)
            }
            CommandGroup(replacing: .appSettings) { Button("软件设置…") { model.showSettings = true }.keyboardShortcut(",") }
        }
    }
}

@MainActor final class LeafDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var openedArguments = false
    var startedChecks = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { model?.stopAnalysis(); model?.flushProgress(); return .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
