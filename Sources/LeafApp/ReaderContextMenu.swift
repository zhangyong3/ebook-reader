import AppKit
import LeafCore

@MainActor private final class ReaderMenuAction: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block=block }
    @objc func invoke(_ sender: Any?) { block() }
}

@MainActor enum ReaderContextMenu {
    static func show(model: AppModel, body: [String: Any], view: NSView) {
        guard let raw=body["id"] as? String, let id=UUID(uuidString:raw), let annotation=model.annotations.first(where: { $0.id==id }) else { return }
        let menu=NSMenu()
        func item(_ title: String, checked: Bool = false, action: @escaping () -> Void) -> NSMenuItem {
            let handler=ReaderMenuAction(action)
            let entry=NSMenuItem(title:title,action:#selector(ReaderMenuAction.invoke(_:)),keyEquivalent:"")
            entry.target=handler; entry.representedObject=handler; entry.state=checked ? .on:.off; return entry
        }
        menu.addItem(item(annotation.kind=="bookmark" ? "删除书签" : annotation.kind=="freeNote" ? "删除笔记" : "删除高亮") { model.deleteAnnotation(annotation) })
        if annotation.kind=="freeNote" {
            menu.addItem(item("编辑文字") { model.bridge.send(["action":"focusNote","id":raw]) })
            let fontMenu=NSMenu()
            for (name,value) in [("系统字体","system"),("宋体 / 衬线","serif"),("等宽字体","mono")] {
                fontMenu.addItem(item(name,checked:annotation.noteAppearance?.font==value) { model.styleFreeNote(id,font:value) })
            }
            let font=NSMenuItem(title:"字体",action:nil,keyEquivalent:"");font.submenu=fontMenu;menu.addItem(font)
            let colors=NSMenu()
            for (name,value) in [("墨色","#292d28"),("绿色","#426653"),("红色","#9d2b38"),("蓝色","#1e5d9d"),("棕色","#7d4e10")] {
                colors.addItem(item(name,checked:annotation.noteAppearance?.color==value) { model.styleFreeNote(id,color:value) })
            }
            let color=NSMenuItem(title:"文字颜色",action:nil,keyEquivalent:"");color.submenu=colors;menu.addItem(color)
            let sizes=NSMenu()
            for size: Double in [12,14,15,16,18,22,26] { sizes.addItem(item("\(Int(size)) 点",checked:annotation.noteAppearance?.size==size) { model.styleFreeNote(id,size:size) }) }
            let size=NSMenuItem(title:"字号",action:nil,keyEquivalent:"");size.submenu=sizes;menu.addItem(size)
        } else if annotation.kind != "bookmark" {
            let styles=NSMenu(), colors=NSMenu(), kinds=NSMenu()
            for (name,value) in [("黄色","yellow"),("绿色","green"),("粉色","pink"),("蓝色","blue")] {
                colors.addItem(item(name,checked:annotation.color==value) { model.changeHighlight(id,color:value) })
            }
            for (name,value) in [("透明色块","highlight"),("下划线","underline"),("删除线","strikethrough")] {
                kinds.addItem(item(name,checked:annotation.kind==value) { model.changeHighlight(id,kind:value) })
            }
            let color=NSMenuItem(title:"颜色",action:nil,keyEquivalent:"");color.submenu=colors;styles.addItem(color)
            let kind=NSMenuItem(title:"高亮方式",action:nil,keyEquivalent:"");kind.submenu=kinds;styles.addItem(kind)
            let style=NSMenuItem(title:"修改样式",action:nil,keyEquivalent:"");style.submenu=styles;menu.addItem(style)
            if !annotation.note.isEmpty { menu.addItem(item("编辑文字笔记") { model.edit(annotation) }) }
        }
        let x=body["x"] as? Double ?? 20, y=body["y"] as? Double ?? 20
        menu.popUp(positioning:nil,at:NSPoint(x:x,y:view.isFlipped ? y:view.bounds.height-y),in:view)
    }
}
