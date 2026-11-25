import SwiftUI

struct AtlasSidebar: View {
    @ObservedObject var m: Workspace
    @State private var creating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                heading("Projects", color: PageCategory.project.color) { m.dialog = .create }
                ForEach(m.projects) { topic in
                    Button { m.open(topic, at: .overview) } label: {
                        Label { Text(verbatim: topic.info.title).foregroundStyle(ink) } icon: {
                            Image(systemName: "square.fill").foregroundStyle(PageCategory.project.color)
                        }
                    }.buttonStyle(SidebarLinkStyle(color: PageCategory.project.color))
                }
                Divider().padding(.vertical, 10)
                heading("Stocks", color: PageCategory.stock.color) { creating = true }
                ForEach(m.stocks) { company in
                    Button { m.open(company, at: .overview) } label: {
                        Label { Text(verbatim: company.stockLabel).foregroundStyle(ink) } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(PageCategory.stock.color)
                        }
                    }.buttonStyle(SidebarLinkStyle(color: PageCategory.stock.color))
                }
            }.padding(.horizontal, 12)
        }.sheet(isPresented: $creating) { StockChooser(m: m, link: nil, suggested: "") }
    }
    private func heading(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        HStack {
            Text(verbatim: title).font(.headline).foregroundStyle(ink)
            Spacer()
            Button(action: action) { Image(systemName: "plus") }.buttonStyle(.borderless).help(title == "Stocks" ? "新建个股深研" : "新建专题")
        }.foregroundStyle(color).padding(.horizontal, 5)
    }
}
extension ProjectAt {
    var stockDisplayName: String {
        let name = info.title.clean
        let ticker = info.stock?.ticker.clean ?? ""
        guard name.hasSuffix(")"), let start = name.lastIndex(of: "(") else { return name }
        let suffix = String(name[name.index(after: start)..<name.index(before: name.endIndex)]).clean.uppercased()
        let codes = [ticker.uppercased(), ticker.split(whereSeparator: \.isWhitespace).first.map { $0.uppercased() }]
        let base = String(name[..<start]).clean
        return !base.isEmpty && !suffix.isEmpty && codes.contains(suffix) ? base : name
    }
    var stockLabel: String {
        let symbol = info.stock?.ticker ?? ""
        return stockDisplayName + (symbol.isEmpty ? "" : " (\(symbol))")
    }
}

struct EntityStockActions: View {
    @ObservedObject var m: Workspace
    let topic: ProjectAt
    let entity: Entry
    @State private var choosing = false

    var body: some View {
        Group {
            if let stock = m.stock(for: entity) {
                Button("打开个股深研") { m.open(stock, at: .overview) }.help(stock.stockLabel)
                    .accessibilityIdentifier("entity.openStock")
            } else {
                Button("个股深研…") { choosing = true }
                    .help("关联已有公司或新建个股深研")
                    .accessibilityIdentifier("entity.chooseStock")
            }
        }
        .sheet(isPresented: $choosing) {
            StockChooser(m: m, link: StockLink(projectID: topic.id, entityID: entity.id), suggested: entity.title)
        }
    }
}

struct StockChooser: View {
    @ObservedObject var m: Workspace
    let link: StockLink?
    let suggested: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var name: String
    @State private var ticker = ""
    @State private var creating: Bool
    @State private var message = ""

    init(m: Workspace, link: StockLink?, suggested: String) {
        self.m = m
        self.link = link
        self.suggested = suggested
        _name = State(initialValue: suggested)
        _creating = State(initialValue: link == nil)
    }

    private var matches: [ProjectAt] {
        let terms = (creating ? [name, ticker] : [query]).map(\.clean).filter { !$0.isEmpty }
        return m.stocks.filter { stock in
            terms.isEmpty || terms.contains { stock.stockLabel.localizedCaseInsensitiveContains($0) }
        }
    }

    private func select(_ stock: ProjectAt) {
        do {
            if let link {
                guard let root = m.root else { throw Failure("请先选择工作目录。") }
                try Files.updateStock(root, id: stock.id, adding: link)
                m.refreshProjects()
            }
            dismiss()
            if link == nil { m.open(stock, at: .overview) }
        } catch { message = error.localizedDescription }
    }

    private func create() {
        guard let root = m.root, m.finishInlineNote() else { return }
        do {
            let company = try Files.createStock(root, name: name, ticker: ticker, link: link)
            m.refreshProjects()
            dismiss()
            m.open(company, at: .overview)
        } catch { message = error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(creating ? "新建个股深研" : "关联已有个股深研").font(.title2.bold())
            if creating {
                TextField("公司名称", text: $name)
                TextField("股票代码（选填）", text: $ticker)
            } else {
                TextField("搜索公司名称或股票代码", text: $query)
                    .accessibilityIdentifier("stockChooser.search")
            }
            let companies = matches
            if companies.isEmpty {
                Text(m.stocks.isEmpty ? "尚无个股深研。" : "没有匹配的公司。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                List(companies) { stock in
                    Button { select(stock) } label: {
                        HStack {
                            Text(verbatim: stock.stockLabel).foregroundStyle(ink)
                            Spacer()
                            Text(link == nil ? "打开" : "关联").foregroundStyle(PageCategory.stock.color)
                        }.contentShape(Rectangle())
                    }.buttonStyle(SidebarLinkStyle(color: PageCategory.stock.color))
                        .accessibilityIdentifier("stockChooser.company." + stock.id)
                }.frame(height: 186)
            }
            if m.root == nil {
                Button("选择工作目录…") { if let root = m.chooseFolder("选择工作目录") { m.setRoot(root) } }
            }
            if !message.isEmpty { Text(message).foregroundStyle(.red) }
            Divider()
            HStack {
                if creating && link != nil {
                    Button("返回已有公司") { creating = false; message = "" }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                if creating {
                    Button(link == nil ? "新建" : "新建并关联", action: create)
                        .disabled(name.clean.isEmpty || m.root == nil)
                        .accessibilityIdentifier("stockChooser.create")
                } else {
                    Button("新建个股深研…") {
                        name = query.clean.isEmpty ? suggested : query.clean
                        ticker = ""
                        message = ""
                        creating = true
                    }.accessibilityIdentifier("stockChooser.startCreation")
                }
            }
        }.padding(22).frame(width: 450)
            .onAppear { m.refreshProjects() }
    }
}
