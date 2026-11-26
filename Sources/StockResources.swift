import SwiftUI
import UniformTypeIdentifiers

struct StockModels: View {
    @ObservedObject var m: Workspace
    let company: ProjectAt
    @State private var files: [URL] = []
    @State private var targeted = false

    private func chooseWorkbook() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.allowedContentTypes = StockFiles.workbookTypes.compactMap { UTType(filenameExtension: $0) }
        guard picker.runModal() == .OK else { return }
        for url in picker.urls { m.attempt { try m.importStockDocument(url, companyID: company.id, workbook: true) } }
    }
    var body: some View {
        StockSection(title: "财务模型") {
            if let path = m.stockBook.mainModel {
                let url = company.url.appendingPathComponent(path)
                Button { m.openStockFile(path) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(url.lastPathComponent).fontWeight(.semibold).lineLimit(3)
                            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help("用默认表格应用打开主模型")
                .contextMenu {
                    Button("复制模型链接") { m.copyEvidence(url.lastPathComponent, target: "file:" + path) }
                }
            }
            Button("添加财务模型…") { chooseWorkbook() }.foregroundStyle(ink)
            ForEach(files, id: \.lastPathComponent) { url in
                let path = "documents/" + url.lastPathComponent
                if path != m.stockBook.mainModel {
                    HStack {
                        Button { m.openStockFile(path) } label: {
                            Label(url.lastPathComponent, systemImage: "doc").lineLimit(2)
                        }.buttonStyle(.link).foregroundStyle(ink)
                        .contextMenu {
                            Button("复制文档链接") { m.copyEvidence(url.lastPathComponent, target: "file:" + path) }
                        }
                        Spacer(minLength: 0)
                        Menu { Button("设为主模型") { m.attempt { try m.modifyBook { $0.mainModel = path } } } }
                            label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                    }
                }
            }
        }.overlay(RoundedRectangle(cornerRadius: 8).stroke(.tint.opacity(targeted ? 1 : 0), lineWidth: 2))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            let id = company.id
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    DispatchQueue.main.async {
                        if let url { m.attempt { try m.importStockDocument(url, companyID: id, workbook: true) } }
                        else { m.error = error?.localizedDescription ?? "无法读取拖入的工作簿。" }
                    }
                }
            }
            return !providers.isEmpty
        }
        .task(id: m.revision) {
            m.attempt { files = try StockFiles.documents(in: company).filter { StockFiles.workbookTypes.contains($0.pathExtension.lowercased()) } }
        }
    }
}

struct StockTopics: View {
    @ObservedObject var m: Workspace
    let company: ProjectAt
    @State private var managing = false
    var body: some View {
        StockSection(title: "关联行业专题") {
            let links = company.info.stock?.links ?? []
            if links.isEmpty { Text("尚未关联专题").foregroundStyle(.secondary) }
            ForEach(m.projects.filter { topic in links.contains { $0.projectID == topic.id } }) { topic in
                LinkedTopicRows(m: m, topic: topic, links: links.filter { $0.projectID == topic.id })

            }
            Button("管理关联") { managing = true }
        }.sheet(isPresented: $managing) { StockLinkManager(m: m, companyID: company.id) }
    }
}

private struct LinkedTopicRows: View {
    @ObservedObject var m: Workspace
    let topic: ProjectAt
    let links: [StockLink]
    @State private var names: [String: String] = [:]

    var body: some View {
        ForEach(links, id: \.self) { link in
            Button { m.attempt { try m.openLinkedEntity(link, in: topic) } } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.info.title).fontWeight(.medium)
                        if links.count > 1, let title = names[link.entityID] { Text(title).font(.caption) }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tint)
                }
            }.buttonStyle(SidebarLinkStyle(color: PageCategory.stock.color, verticalInset: 6))
                .foregroundStyle(ink)
                .accessibilityIdentifier("stock.topic." + topic.id + "." + link.entityID)
                .help("打开「" + topic.info.title + "」中的公司实体")
                .contextMenu { Button("打开专题概览") { m.open(topic, at: .overview) } }
        }
        .task(id: links) {
            guard links.count > 1, let snapshot = try? Files.scan(topic.url) else { return }
            for link in links { names[link.entityID] = snapshot.resolve(link.entityID)?.title }
        }
    }
}

private struct StockLinkManager: View {
    @ObservedObject var m: Workspace
    let companyID: String
    @Environment(\.dismiss) var dismiss
    @State private var topicID = ""
    @State private var entities: [Entry] = []
    @State private var query = ""
    @State private var message = ""
    private var links: [StockLink] {
        m.stocks.first { $0.id == companyID }?.info.stock?.links ?? []
    }
    private func modify(adding: StockLink? = nil, removing: Set<StockLink> = []) {
        guard let root = m.root else { return }
        do { try Files.updateStock(root, id: companyID, adding: adding, removing: removing); m.refreshProjects(); message = "" }
        catch { message = error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("管理专题关联").font(.title2.bold())
            ForEach(m.projects.filter { topic in links.contains { $0.projectID == topic.id } }) { topic in
                HStack {
                    Text(topic.info.title); Spacer()
                    Button("解除专题关联") { modify(removing: Set(links.filter { $0.projectID == topic.id })) }
                }
            }
            Divider()
            Picker("专题", selection: $topicID) {
                Text("选择专题").tag("")
                ForEach(m.projects) { topic in Text(topic.info.title).tag(topic.id) }
            }
            TextField("查找公司实体", text: $query)
            List(entities.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { entity in
                let link = StockLink(projectID: topicID, entityID: entity.id)
                HStack {
                    Text(entity.title)
                    Spacer()
                    if links.contains(link) { Button("解除实体关联") { modify(removing: [link]) } }
                    else if let other = m.stocks.first(where: { $0.info.stock?.links.contains(link) == true }) {
                        Text(other.info.title).foregroundStyle(.secondary)
                    } else { Button("关联") { modify(adding: link) } }
                }
            }.frame(height: 180)
            if !message.isEmpty { Text(message).foregroundStyle(.red) }
            HStack { Spacer(); Button("完成") { dismiss() } }
        }.padding(20).frame(width: 450)
        .onChange(of: topicID) { _, id in
            entities = []
            if let topic = m.projects.first(where: { $0.id == id }) {
                do { entities = try Files.scan(topic.url).entries.filter { $0.kind == .entities }; message = "" }
                catch { message = error.localizedDescription }
            }
        }
    }
}
