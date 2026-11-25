import SwiftUI
import UniformTypeIdentifiers

struct StockHomeLayout: Codable, Equatable {
    private var order: [String] = []
    private var orderVersion: Int?
    private var heights: [String: Double] = [:]

    var modules: [StockModule] {
        guard orderVersion == 3 else { return StockModule.allCases }
        var seen = Set<StockModule>()
        return (order.compactMap(StockModule.init(rawValue:)) + StockModule.allCases)
            .filter { seen.insert($0).inserted }
    }

    mutating func move(_ module: StockModule, to target: StockModule) {
        guard module != target else { return }
        var result = modules
        guard let from = result.firstIndex(of: module), let to = result.firstIndex(of: target) else { return }
        result.remove(at: from)
        result.insert(module, at: to)
        order = result.map(\.rawValue)
        orderVersion = 3
    }

    static func boundedHeight(_ height: CGFloat) -> CGFloat { min(1100, max(100, height)) }
    func height(_ module: StockModule) -> CGFloat? { heights[module.rawValue].map { Self.boundedHeight(CGFloat($0)) } }
    mutating func resize(_ module: StockModule, height: CGFloat?) { heights[module.rawValue] = height.map { Double(Self.boundedHeight($0)) } }
}

struct StockCardSection: Codable, Equatable {
    var path: String
    var title = ""
    var markdown = ""
    var lines: [String] = []
    var workbook: String?
}

private struct CardTransfer: Codable, Transferable {
    var company: String
    var module: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "local.feynman.research.home-card"))
            .visibility(.ownProcess)
    }
}

struct StockHome: View {
    @ObservedObject var m: Workspace
    let company: ProjectAt
    @State private var identityEditor = false
    @State private var previews: [StockModule: [StockCardSection]] = [:]
    private var layout: StockHomeLayout { m.stockBook.homeLayout ?? StockHomeLayout() }

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = geometry.size.width < 520 ? 8 : 16
            let topicsWidth = min(232, geometry.size.width * 0.24)
            VStack(spacing: 0) {
                PageHeading(title: "Home", category: .stock, metadata: company.stockLabel) {
                    PageActions {
                        StockResearchButton(m: m, module: nil)
                        Button("编辑公司资料") { identityEditor = true }
                    }
                }
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(layout.modules, id: \.self) { module in
                                StockHomeCard(m: m, module: module, companyID: company.id,
                                              sections: sections(for: module), manualHeight: layout.height(module),
                                              automaticLimit: max(280, min(840, geometry.size.height * 0.8)),
                                              open: { m.openStockModule(module) },
                                              move: { source in save { $0.move(source, to: module) } },
                                              resize: { height in save { $0.resize(module, height: height) } })
                            }
                        }.padding(inset)
                    }.frame(maxWidth: .infinity)
                    ScrollView {
                        StockTopics(m: m, company: company)
                            .padding(.top, inset).padding(.trailing, inset).padding(.bottom, inset)
                    }.frame(width: topicsWidth)
                }
            }
        }
        .sheet(isPresented: $identityEditor) { StockIdentityEditor(m: m, company: company) }
        .task(id: m.revision) { loadPreviews() }
    }

    private func save(_ edit: (inout StockHomeLayout) -> Void) {
        guard m.project?.id == company.id else { return }
        var updated = layout
        edit(&updated)
        guard updated != layout else { return }
        m.attempt { try m.modifyBook { $0.homeLayout = updated } }
    }

    private func loadPreviews() {
        var result: [StockModule: [StockCardSection]] = [:]
        func appendNote(_ path: String, title: String = "", to module: StockModule) {
            let body = (try? m.text(path)).map { Document($0).body } ?? ""
            if !title.isEmpty || !body.clean.isEmpty {
                result[module, default: []].append(StockCardSection(path: path, title: title, markdown: body))
            }
        }
        for module in StockModule.allCases {
            if let path = module.note { appendNote(path, to: module) }
        }
        let documents = (try? StockFiles.documents(in: company)) ?? []
        for url in documents {
            let name = url.lastPathComponent
            let image = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            result[.references, default: []].append(StockCardSection(path: "documents/" + name, title: name,
                markdown: image ? NotePaste.imageMarkdown(name, name) : ""))
        }
        let reports = (try? StockFiles.legacyReports(in: company)) ?? []
        let titles = reports.map(documentLabel) + m.snapshot.entries.filter { $0.kind == .references }.map(\.title)
            + m.snapshot.unlistedMaterials.map(materialLabel)
        if !titles.isEmpty { result[.references, default: []].append(StockCardSection(path: "", lines: titles)) }
        previews = result
    }

    private func sections(for module: StockModule) -> [StockCardSection] {
        var sections = previews[module] ?? []
        if let job = m.stockRun, job.company.id == company.id, let path = module.note,
           let live = job.liveText(module: module, original: sections.first(where: { $0.path == path })?.markdown ?? "") {
            sections.removeAll { $0.path == path }
            sections.insert(StockCardSection(path: path, markdown: live), at: 0)
        }
        if module == .thesis, let latest = m.stockBook.history.first {
            sections.append(StockCardSection(path: ".current-" + latest.id.uuidString + ".md",
                title: latest.conclusion, markdown: latest.body,
                lines: [latest.date.formatted(date: .abbreviated, time: .omitted), latest.reason]))
        }
        if module == .earnings {
            let forecast = m.stockBook.forecast
            var lines = forecast.metrics.flatMap { metric in
                forecast.years.sorted().compactMap { year in
                    metric.values[year].map { [metric.name, metric.basis, year, $0, metric.unit].filter { !$0.isEmpty }.joined(separator: " · ") }
                }
            }
            if !forecast.price.isEmpty { lines.append("估值采用股价　" + forecast.price + "　" + forecast.priceDate) }
            if !lines.isEmpty || m.stockBook.mainModel != nil {
                sections.insert(StockCardSection(path: "", lines: lines, workbook: m.stockBook.mainModel.map { ($0 as NSString).lastPathComponent }), at: 0)
            }
        }
        return sections
    }
}

private struct StockHomeCard: View {
    @ObservedObject var m: Workspace
    let module: StockModule
    let companyID: String
    let sections: [StockCardSection]
    let manualHeight: CGFloat?
    let automaticLimit: CGFloat
    let open: () -> Void
    let move: (StockModule) -> Void
    let resize: (CGFloat?) -> Void
    @State private var bodyHeight: CGFloat = 32
    private var height: CGFloat {
        manualHeight ?? min(automaticLimit, max(100, (sections.isEmpty ? 20 : bodyHeight) + 81))
    }
    private var emptyText: String {
        switch module {
        case .thesis: return m.stockBook.draft == nil ? "尚未发布投资判断" : "有一份待发布的判断草稿"
        case .references: return "尚未添加资料"
        case .updates: return "尚未记录重要更新"
        case .earnings: return "尚未填写盈利预测"
        default: return "尚未填写分析"
        }
    }
    @GestureState private var heightChange: CGFloat = 0
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 8) {
                        Image(systemName: module.symbol).foregroundStyle(module.category.color)
                        Text(verbatim: module.heading).font(.headline)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(SidebarLinkStyle(color: module.category.color, horizontalInset: 2, verticalInset: 2))
                Image(systemName: "circle.grid.2x3.fill").foregroundStyle(.secondary)
                    .frame(width: 22, height: 24).contentShape(Rectangle())
                    .draggable(CardTransfer(company: companyID, module: module.rawValue)) {
                        Label(module.title, systemImage: module.symbol).padding(10).background(.regularMaterial)
                    }
                    .accessibilityLabel("拖动" + module.title).help("拖到另一张卡片以调整位置")
            }
            Divider()
            if sections.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Reader(model: m, path: "", bodyText: "", allowsEditing: false, cardSections: sections,
                       onCardHeight: { bodyHeight = ceil($0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(14).padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .frame(height: StockHomeLayout.boundedHeight(height + heightChange), alignment: .top)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(targeted ? module.category.color : .secondary.opacity(0.18), lineWidth: targeted ? 2 : 1).allowsHitTesting(false) }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.and.down").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 26, height: 22).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .updating($heightChange) { value, delta, _ in delta = value.translation.height }
                        .onEnded { value in resize(height + value.translation.height) })
                    .contextMenu { Button("恢复自动高度") { resize(nil) }.disabled(manualHeight == nil) }
                    .help("拖动调整高度；右键恢复自动高度")
            }
            .dropDestination(for: CardTransfer.self) { items, _ in
                guard let card = items.first, card.company == companyID,
                      let source = StockModule(rawValue: card.module), source != module else { return false }
                move(source)
                return true
            } isTargeted: { targeted = $0 }
    }
}
