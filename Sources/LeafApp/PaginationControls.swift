import SwiftUI

struct PageNavigator: View {
    @ObservedObject var model: AppModel
    @State private var page=""
    @FocusState private var editing: Bool
    var body: some View {
        Group {
            if model.paginating {
                Text("正在分页…").foregroundStyle(.secondary)
            } else if let error=model.paginationError {
                Text("页数暂不可用").foregroundStyle(.secondary).help(error)
            } else if model.totalPages>0 {
                HStack(spacing:5) {
                    TextField("页码",text:$page).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                        .frame(width:max(42,CGFloat(String(model.totalPages).count)*8+18)).focused($editing)
                        .accessibilityLabel("当前页码").help("输入 1–\(model.totalPages) 后按回车跳转")
                        .onSubmit {
                            if let number=Int(page),number>=1,number<=model.totalPages { model.goToPage(number) }
                            else { page=String(model.currentPage) }
                            editing=false
                        }
                    Text("/ \(model.totalPages) 页").foregroundStyle(.secondary).accessibilityLabel("全书共 \(model.totalPages) 页")
                }
            }
        }.font(.caption.monospacedDigit())
            .onAppear { page=String(model.currentPage) }
            .onChange(of:model.currentPage) { _,value in if !editing { page=String(value) } }
            .onChange(of:editing) { _,value in if !value { page=String(model.currentPage) } }
    }
}
