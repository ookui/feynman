import SwiftUI

private struct ActiveStockModuleKey: EnvironmentKey {
    static let defaultValue: StockModule? = nil
}

extension EnvironmentValues {
    var activeStockModule: StockModule? {
        get { self[ActiveStockModuleKey.self] }
        set { self[ActiveStockModuleKey.self] = newValue }
    }
}

extension Workspace {
    func openStockModule(_ module: StockModule) {
        go(module.destination)
    }

    func stockModule(for destination: Place) -> StockModule? {
        guard project?.info.stock != nil else { return nil }
        switch destination {
        case .judgments, .judgmentEditor: return .thesis
        case .stock(let module): return module
        case .group(.references), .webLinks: return .references
        case .entry(let id): return snapshot.resolve(id)?.kind == .references ? .references : nil
        case .doc(let path):
            if let module = StockModule.allCases.first(where: { $0.note == path }) { return module }
            return path.hasPrefix("reports/") || referenceDocument(path) != nil ? .references : nil
        default: return nil
        }
    }

    func editStockNote(_ path: String) throws {
        guard let company = project, company.info.stock != nil else { return }
        if StockModule.allCases.contains(where: { $0.note == path }) {
            let file = try Files.child(company.url, path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: file.path) { try Files.save(file, "", expected: nil) }
        }
        beginInlineNote(path, mode: .rich)
    }

    func openLinkedEntity(_ link: StockLink, in topic: ProjectAt) throws {
        guard link.projectID == topic.id, project?.info.stock?.links.contains(link) == true,
              let entity = try Files.scan(topic.url).resolve(link.entityID), entity.kind == .entities else {
            throw Failure("找不到这个专题关联的公司实体。")
        }
        open(topic, at: .entry(entity.id))
    }
}

struct StockModulePage: View {
    @ObservedObject var m: Workspace
    let company: ProjectAt
    let module: StockModule
    @State private var addingRecord = false
    @State private var record = ""
    private var path: String? { module.note }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeading(title: module.heading, category: .stock, metadata: company.stockLabel + " · " + module.cadence) {
                PageActions {
                    StockResearchButton(m: m, module: module)
                    if module == .thesis { Button("已发布判断与历史") { m.go(.judgments) } }
                    if module == .references { Button("资料文件与导入") { m.go(.group(.references)) } }
                    if module.appendOnly {
                        Button("追加记录") { record = ""; addingRecord = true }
                    } else if let path { Button("编辑正文") { m.attempt { try m.editStockNote(path) } } }
                }
            }
            if module == .earnings {
                ScrollView { StockModels(m: m, company: company).padding(10) }.frame(maxHeight: 164)
            }
            Divider()
            if let path {
                let raw = try? m.text(path)
                let body = Document(raw ?? "").body
                if let job = m.stockRun, job.company.id == company.id,
                   let live = job.liveText(module: module, original: body) {
                    Reader(model: m, path: path, bodyText: live, allowsEditing: false)
                } else if module.appendOnly {
                    Reader(model: m, path: path, bodyText: body, allowsEditing: false)
                } else if raw != nil {
                    NoteBody(m: m, path: path, text: body).id(path)
                } else {
                    Button("点击此处开始撰写") { m.attempt { try m.editStockNote(path) } }.buttonStyle(.link).padding()
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $addingRecord) {
            VStack(alignment: .leading, spacing: 12) {
                Text("追加记录 · " + module.title).font(.headline)
                TextEditor(text: $record).border(.secondary.opacity(0.3))
                HStack { Spacer(); Button("取消") { addingRecord = false }
                    Button("追加") { m.attempt {
                        guard let path else { return }
                        let url = try Files.child(company.url, path)
                        let old = try Files.contents(url)
                        try Files.save(url, (old ?? "") + (old?.isEmpty == false ? "\n\n" : "") + record.clean + "\n", expected: old)
                        addingRecord = false; m.refresh()
                    } }.disabled(record.clean.isEmpty)
                }
            }.padding(18).frame(width: 470, height: 300)
        }
    }
}
