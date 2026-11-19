import SwiftUI
import UniformTypeIdentifiers
import Quartz

struct EntryActions: View {
    @ObservedObject var m: Workspace
    let entry: Entry
    var body: some View {
        if entry.kind != .references {
            Button("编辑…") {
                if m.place != .entry(entry.id) { m.go(.entry(entry.id)) }
                if m.place == .entry(entry.id) { m.beginInlineNote(entry.path) }
            }
        }
        Button("关联条目…") { m.dialog = .relate(entry) }
        if entry.kind == .references { ReportLinksMenu(m: m, entry: entry) }
        Button("合并到其他条目…") { m.dialog = .merge(entry) }
        Divider()
        Button("删除…", role: .destructive) { m.dialog = .remove(entry) }
    }
}

private struct ReportLinksMenu: View {
    @ObservedObject var m: Workspace
    let entry: Entry
    var body: some View {
        Menu("关联基础报告") {
            ForEach(m.snapshot.reports, id: \.self) { path in
                Toggle(documentLabel(path), isOn: Binding(get: { entry.reportLinks.contains(path) }, set: { on in
                    m.attempt {
                        guard var live = m.snapshot.resolve(entry.id) else { throw Failure("资料已删除。") }
                        live.reportLinks.removeAll { $0 == path }
                        if on { live.reportLinks.append(path) }
                        try m.store(live)
                    }
                }))
            }
        }.disabled(m.snapshot.reports.isEmpty)
    }
}

struct ReferenceFileDrop: ViewModifier {
    @ObservedObject var m: Workspace
    var enabled = true
    @State private var targeted = false
    func body(content: Content) -> some View {
        if enabled {
            content.contentShape(Rectangle())
                .onDrop(of: DroppedReference.acceptedTypes, isTargeted: $targeted) { providers in
                    guard let project = m.project else { return false }
                    Task { await m.importDroppedReferences(providers, into: project) }
                    return true
                }
                .overlay { if targeted { RoundedRectangle(cornerRadius: 6).strokeBorder(leaf, lineWidth: 2).allowsHitTesting(false) } }
        } else { content }
    }
}

struct AddReferenceActions: View {
    @ObservedObject var m: Workspace
    var body: some View {
        Button("导入文件…") { m.attach(library: false) }
        Button("引用库内文件…") { m.attach(library: true) }
        Button("添加链接…") { m.dialog = .editor(Editor(entry: Entry(kind: .references, title: ""))) }
    }
}

struct ReferenceDirectory: View {
    @ObservedObject var m: Workspace
    var body: some View {
        let entries = m.snapshot.entries.filter { $0.kind == .references }
        let webCount = entries.filter(m.snapshot.isWebReference).count + m.snapshot.unlistedMaterials.filter(MaterialLinks.isWeb).count
        VStack(alignment: .leading, spacing: 0) {
            PageHeading(title: "参考资料", category: .kind(.references),
                        subtitle: "拖入 PDF 链接可下载原件，其他网页收进「网页链接」。也可直接拖入本地文件。") {
                PageActions {
                    AddReferenceActions(m: m)
                }.controlSize(.small)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    fileRow("网页链接（" + String(webCount) + "）", symbol: "link") { m.go(.webLinks) }
                    ForEach(entries.filter { !m.snapshot.isWebReference($0) }) { entry in
                        fileRow(entry.title, symbol: "doc") { m.go(.entry(entry.id)) }
                            .contextMenu { EntryActions(m: m, entry: entry) }
                    }
                    ForEach(m.snapshot.unlistedMaterials.filter { !MaterialLinks.isWeb($0) }, id: \.self) { source in
                        fileRow(materialLabel(source), symbol: "doc") { m.attempt { m.go(.entry(try m.registerMaterial(source).id)) } }
                    }
                }.padding(.horizontal, 16)
            }
        }.modifier(ReferenceFileDrop(m: m))
    }
    private func fileRow(_ title: String, symbol: String, open: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Button(action: open) {
                HStack { Label(title, systemImage: symbol); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                    .padding(.vertical, 10).contentShape(Rectangle())
            }.buttonStyle(SidebarLinkStyle(color: PageCategory.kind(.references).color, verticalInset: 0))
            Divider()
        }
    }
}

struct ReferencePage: View {
    @ObservedObject var m: Workspace
    var body: some View {
        let links = m.snapshot.entries.filter(m.snapshot.isWebReference)
        let unlisted = m.snapshot.unlistedMaterials.filter(MaterialLinks.isWeb)
        VStack(alignment: .leading, spacing: 0) {
            PageHeading(title: "网页链接", category: .webLinks) {
                Button("添加链接…") { m.dialog = .editor(Editor(entry: Entry(kind: .references, title: ""))) }
            }
            Divider()
            List {
                ForEach(links) { entry in
                    Button { m.go(.entry(entry.id)) } label: { Label(entry.title, systemImage: "link") }
                        .buttonStyle(SidebarLinkStyle(color: PageCategory.webLinks.color)).contextMenu { EntryActions(m: m, entry: entry) }
                }
                ForEach(unlisted, id: \.self) { source in
                    Button(materialLabel(source)) { m.attempt { m.go(.entry(try m.registerMaterial(source).id)) } }
                        .buttonStyle(SidebarLinkStyle(color: PageCategory.webLinks.color))
                }
                if links.isEmpty && unlisted.isEmpty { Text("尚未添加网页链接。").foregroundStyle(.secondary) }
            }
        }.modifier(ReferenceFileDrop(m: m))
    }
}

struct ReferenceFilePage: View {
    @ObservedObject var m: Workspace
    let entry: Entry
    var document: String?
    @State private var selection: String?

    var body: some View {
        let sources = m.snapshot.sources(for: entry)
        let initial = document.map { $0.contains(":") ? $0 : "project:" + $0 }
        let source = [selection, initial].compactMap { $0 }.first(where: sources.contains)
            ?? sources.first(where: { !MaterialLinks.isWeb($0) }) ?? sources.first
        let file = source.flatMap { MaterialLinks.isWeb($0) ? nil : try? m.assetURL($0) }
        VStack(alignment: .leading, spacing: 0) {
            PageHeading(title: entry.title, category: m.snapshot.isWebReference(entry) ? .webLinks : .kind(.references)) {
                PageActions {
                    if sources.count > 1 {
                        Menu("选择来源") {
                            ForEach(sources, id: \.self) { item in Button(materialLabel(item)) { selection = item } }
                        }.fixedSize()
                    }
                    Button("关联…") { m.dialog = .relate(entry) }
                    Button("引用到 Memo") { m.editDoc("memo.md", append: "[" + entry.title + "](feynman:" + entry.id + ")") }
                    Menu("更多") {
                        ReportLinksMenu(m: m, entry: entry)
                        if let file { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
                        let targets = m.snapshot.archiveSources(for: entry)
                        if targets.count == 1, let item = targets.first {
                            Button("保存到知识库 Library") { m.archive(entry, source: item) }
                        } else if !targets.isEmpty {
                            Menu("保存到知识库 Library") {
                                ForEach(targets, id: \.self) { item in Button(materialLabel(item)) { m.archive(entry, source: item) } }
                            }
                        }
                        Button("合并到其他条目…") { m.dialog = .merge(entry) }
                        Button("删除…", role: .destructive) { m.dialog = .remove(entry) }
                    }.fixedSize()
                }
            }
            Divider()
            if let source, MaterialLinks.isWeb(source) {
                Button("打开原网页") { m.attempt { try m.openMaterial(source) } }.buttonStyle(.link).padding()
                Reader(model: m, path: entry.path, bodyText: entry.body, allowsEditing: false)
            } else if let file, fm.fileExists(atPath: file.path) {
                if Workspace.isMarkdown(file), let path = try? m.documentKey(for: file) {
                    if let raw = try? m.text(path) {
                        Reader(model: m, path: path, bodyText: Document(raw).body, allowsEditing: false)
                    } else { Text("无法读取这份 Markdown 文件。").padding() }
                } else if ["json", "txt", "csv"].contains(file.pathExtension.lowercased()),
                          let raw = try? String(contentsOf: file, encoding: .utf8) {
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: raw).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding()
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    FilePreview(url: file).id(file).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if source != nil { Text("文件尚未同步或已移走。").padding() }
            else { Reader(model: m, path: entry.path, bodyText: entry.body, allowsEditing: false) }
        }.frame(maxHeight: .infinity, alignment: .top).modifier(ReferenceFileDrop(m: m))
    }
}

private struct FilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let preview = QLPreviewView(frame: .zero, style: .normal)!
        preview.previewItem = url as NSURL
        return preview
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {}
}

extension Workspace {
    func openMaterial(_ original: String) throws {
        let source = snapshot.archivedDestinations[original] ?? original
        if let url = URL(string: source), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            guard NSWorkspace.shared.open(url) else { throw Failure("无法打开来源网址。") }
        } else { try openAsset(assetURL(source)) }
    }
}
