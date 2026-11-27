import SwiftUI

struct ProjectDetail: View {
    @ObservedObject var m: Workspace
    var p: ProjectAt
    func jump(_ title: String,_ image:String,_ dest:Place, _ subtitle:String = "", color: Color = leaf, core: Bool = false) -> some View {
        Button { m.go(dest) } label: {
            HStack(spacing:10) { Image(systemName:image).foregroundStyle(leaf).frame(width:20); Text(title).fontWeight(core ? .bold : .regular).lineLimit(2); Spacer(); if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }; Image(systemName:"chevron.right").font(.caption2).foregroundStyle(.secondary) }.padding(.vertical,7).contentShape(Rectangle())
        }.buttonStyle(SidebarLinkStyle(color: color, horizontalInset: 4, verticalInset: 0))
    }
    @ViewBuilder var body: some View {
        switch m.place {
        case .judgments: StockThesis(m: m, company: p).id(p.id)
        case .company(let page): CompanyPageView(m: m, company: p, page: page).id(p.id + page.rawValue)
        case .judgmentEditor: StockJudgmentEditor(m: m, company: p)
        case .overview:
            if p.info.stock != nil { CompanyHome(m: m, company: p).id(p.id) }
            else { overview }
        case .preliminary: preliminary
        case .group(.references): ReferenceDirectory(m: m)
        case .webLinks: ReferencePage(m: m)
        case .group(let k): group(k)
        case .entry, .doc:
            let item = m.displayedEntry
            let document: String? = { if case .doc(let path) = m.place { return path }; return nil }()
            if let item, item.kind == .references {
                ReferenceFilePage(m: m, entry: item, document: document).id(document ?? item.id)
            } else if let path = document ?? item?.path {
                notePage(path: path, entry: item)
            } else if let note = m.inlineNote { NoteBody(m: m, path: note.path, text: note.text) }
            else { overview }
        }
    }
    var overview: some View {
        VStack(spacing: 0) {
            PageHeading(title: "Project Overview", category: .project) { EmptyView() }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    overviewButton("Preliminary", .report)
                    ForEach(Kind.allCases) { kind in
                        overviewButton(kind.englishLabel, .kind(kind))
                    }
                    overviewButton("Images", .images)
                    overviewButton("Log", .log)
                    overviewButton("Memo", .memo)
                    if !m.snapshot.documents.isEmpty { overviewButton("Documents", .documents) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            ProjectGraph(model: m)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func overviewButton(_ title: String, _ category: PageCategory) -> some View {
        let visible = !m.hiddenGraphFilters.contains(category.graphFilterKey)
        return Button { m.toggleGraphFilter(category) } label: {
            Text(title).font(.system(size: 12, weight: .medium)).fixedSize()
        }
        .buttonStyle(.bordered)
        .tint(visible ? category.color : .gray)
        .foregroundStyle(visible ? category.color : .secondary)
        .accessibilityAddTraits(visible ? .isSelected : [])
        .help((visible ? "隐藏" : "显示") + title + " 节点和连线")
    }

    private var preliminary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeading(title: "Preliminary", category: .report,
                            metadata: m.snapshot.completed ? "预研已完成" : m.snapshot.reports.isEmpty ? "待预研" : "已有报告",
                            subtitle: p.info.intent) {
                    Button { m.researchProject() } label: {
                        Label(m.hasPreflight ? "继续研究此项目…" : "开始预研", systemImage: "sparkles")
                    }
                    .buttonStyle(ResearchActionStyle())
                }
                VStack(alignment: .leading, spacing: 8) {
                    if m.snapshot.reports.isEmpty {
                        Text("本项目尚无预研报告。").foregroundStyle(.secondary)
                    }
                    ForEach(m.snapshot.reports.reversed(), id: \.self) { path in
                        jump(documentLabel(path), "doc.text", .doc(path), color: PageCategory.report.color)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func group(_ k: Kind) -> some View {
        ScrollView { VStack(alignment:.leading,spacing:14) {
            PageHeading(title: k.label, category: .kind(k)) {
                Button { m.dialog = .editor(Editor(entry:Entry(kind:k,title:""))) } label:{ Label("添加",systemImage:"plus") }
            }
            VStack(alignment: .leading, spacing: 14) {
                let entries = m.snapshot.entries.filter { $0.kind == k }
                if entries.isEmpty { Text("本项目尚无" + k.label + "。").foregroundStyle(.secondary).padding(.vertical,12) }
                ForEach(entries) { e in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            jump(e.title, k.symbol, .entry(e.id), e.origin, color: PageCategory.kind(k).color, core: e.core).contextMenu { EntryActions(m: m, entry: e) }
                            if k == .questions { QuestionStatusButton(m: m, question: e) }
                        }
                        Divider()
                    }
                }
            }.padding(.horizontal,24).padding(.bottom,24)
        }.frame(maxWidth: .infinity, alignment: .leading) }
    }
    // One reader stays mounted when history moves between a report and an entry.
    // Only its data and heading change, retaining the already-loaded WebKit scripts.
    private func notePage(path: String, entry: Entry?) -> some View {
        let result = Result {
            if let entry { return entry.body }
            guard let text = try m.text(path) else { throw Failure("文件尚未同步或已移走。") }
            return Document(text).body
        }
        let body = (try? result.get()) ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            if let entry { entryHeading(entry) }
            else { PageHeading(title: documentLabel(path), category: PageCategory(document: path)) { documentActions(path, body) } }
            if let entry, p.info.stock != nil {
                if entry.kind == .questions && !m.showEntryRelations { Divider(); CruxSummaryBar(m: m, question: entry).id(entry.id) }
                if entry.kind == .events { EventPanel(m: m, event: entry).id(entry.id) }
            }
            if let entry, p.info.stock == nil, entry.kind == .entities, let stock = m.stock(for: entry) {
                LinkedStockCard(m: m, stock: stock).id(stock.id)
            }
            Divider()
            if case .failure(let err) = result, m.inlineNote?.path != path { Text(err.localizedDescription).padding() }
            else {
                NoteBody(m: m, path: path, text: body,
                         extract: entry == nil && (path.hasPrefix("reports/") || (p.info.stock == nil && path == "questions.md")),
                         history: entry?.kind == .questions ? entry?.questionHistory : nil)
            }
        }
    }

    private func entryHeading(_ e: Entry) -> some View {
        let header = PageHeading(title: e.title, category: .kind(e.kind), metadata: e.origin,
                                 status: e.kind == .questions ? QuestionStatusButton(m: m, question: e) : nil,
                                 editableTitle: EntryPageTitle(model: m, entry: e)) {
            PageActions {
                if e.kind == .questions {
                    Button { m.launch(.question, context: e.path) } label: { Label("AI 研究", systemImage: "sparkles") }
                        .buttonStyle(ResearchActionStyle())
                }
                Button("关联…") { m.dialog = .relate(e) }
                if e.kind == .entities, p.info.stock == nil {
                    EntityStockActions(m: m, topic: p, entity: e).id(e.id)
                }
                Menu("更多") {
                    Button(e.core ? "取消核心标记" : "标为核心条目") { m.toggleCore(e) }
                    if e.kind != .questions { Button("用 AI 修订正文") { m.launch(.revise, context:e.path) } }
                    if e.kind == .questions {
                        Button("添加子问题…") { m.newSubQuestion(of: e) }
                        Button(e.answered ? "重新打开问题" : "标为已回答") { m.toggleQuestionStatus(e.id) }
                        if p.info.stock != nil {
                            if e.role == "crux" { Button("移出关键问题") { m.attempt { try m.updateEntry(e.id) { $0.role = ""; $0.candidate = false } } } }
                            else { Button("设为关键问题") { m.attempt { try m.updateEntry(e.id) { $0.role = "crux"; $0.candidate = false; $0.parent = "" } } } }
                            Button("关联行业依据…") { m.dialog = .dependency(e) }
                            Button("新建行业问题…") { m.dialog = .submit(e) }
                        }
                    }
                    if p.info.stock != nil && e.kind == .events {
                        Button("提交到专题…") { m.dialog = .submit(e) }
                    }
                    if p.info.stock == nil { Button("引用到我的 Memo") { m.editDoc("memo.md",append:"[" + e.title + "](feynman:" + e.id + ")") } }
                    Button("关联知识库资料…") { m.attach(library:true,to:e) }
                    Button("添加参考资料…") { m.attach(library:false,to:e) }
                    Button("回写到知识库…") { m.dialog = .cite(e) }
                    Divider()
                    Button("合并到其他条目…") { m.dialog = .merge(e) }
                    Button("删除条目…") { m.dialog = .remove(e) }
                }.fixedSize()
            }
        }
        return ViewThatFits(in:.vertical) {
            header.fixedSize(horizontal:false,vertical:true)
            ScrollView { header }.frame(height: 405)
        }.frame(maxHeight:405,alignment:.topLeading).fixedSize(horizontal:false,vertical:true)
    }

    private func documentActions(_ path: String, _ body: String) -> some View {
        PageActions {
            if path == "memo.md", !body.clean.isEmpty { Button("回写到知识库…") { m.launch(.publish,context:path) } }
            if path.hasPrefix("reports/") {
                Button("用 AI 修订报告") { m.launch(.revise, context:path) }
                Button("查看出处") { m.inspect.toggle() }
            }
        }
    }

}
struct Inspector: View {
    @ObservedObject var m: Workspace
    @ViewBuilder private func passageMenu(_ entry: Entry) -> some View {
        let anchors = entry.anchors.filter { m.passage.contains($0) }
        if anchors.count == 1, let anchor = anchors.first {
            RelationMenu(model: m, entry: entry, target: .quote(anchor))
        } else {
            ForEach(anchors, id: \.self) { anchor in
                Menu(anchor.quote) { RelationMenu(model: m, entry: entry, target: .quote(anchor)) }
            }
        }
    }

    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:14) {
            HStack { Text(m.passage.isEmpty ? "关联与出处" : "所选原文").font(.headline); Spacer(); Button { m.inspect=false } label:{ Image(systemName:"xmark") }.buttonStyle(.plain) }
            if case .doc = m.place, let anchor = m.passage.first {
                Text(anchor.quote)
                    .lineLimit(4).padding(.leading, 9)
                    .overlay(alignment: .leading) { Rectangle().fill(leaf.opacity(0.4)).frame(width: 2) }
                Divider()
                Text("这段原文的相关问题").font(.headline)
                let owners = m.snapshot.owners(of: m.passage)
                let questions = m.snapshot.questions(for: owners)
                if questions.isEmpty { Text("暂无关联问题").foregroundStyle(.secondary) }
                ForEach(questions) { question in
                    VStack(alignment: .leading, spacing: 5) {
                        Button(question.title) { m.go(.entry(question.id)) }.buttonStyle(SidebarLinkStyle())
                            .contextMenu { passageMenu(question) }
                        QuestionStatusButton(m: m, question: question)
                    }
                }
                let others = owners.filter { $0.kind != .questions }
                if !others.isEmpty {
                    Divider()
                    Text("原文关联条目").font(.headline)
                    ForEach(others) { entry in
                        Button { m.go(.entry(entry.id)) } label: { Label(entry.title,systemImage:entry.kind.symbol) }.buttonStyle(SidebarLinkStyle())
                            .contextMenu { passageMenu(entry) }
                    }
                }
                Divider()
                Button("查看整篇报告的出处") { m.passage = [] }.buttonStyle(SidebarLinkStyle())
            } else if case .doc(let path) = m.place {
                let entries = m.snapshot.entries.filter { e in e.anchors.contains { $0.report == path } || e.reportLinks.contains(path) || m.snapshot.citations[e.id]?.contains(path) == true }
                if entries.isEmpty { Text("此文档尚无关联条目。").foregroundStyle(.secondary) }
                ForEach(entries) { e in
                    Button { m.go(.entry(e.id)) } label:{ Label(e.title,systemImage:e.kind.symbol).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(SidebarLinkStyle())
                        .contextMenu { RelationMenu(model: m, entry: e, target: .document(path)) }
                    ForEach(e.anchors.filter { $0.report == path },id:\.self) { a in
                        Button(a.quote) { m.go(.doc(path),anchor:a) }.lineLimit(2).buttonStyle(SidebarLinkStyle()).foregroundStyle(.secondary)
                            .contextMenu { RelationMenu(model: m, entry: e, target: .quote(a)) }
                    }
                }
            } else if case .entry(let id)=m.place, let e=m.snapshot.resolve(id) {
                Button("关联条目…") { m.dialog = .relate(e) }
                ForEach(m.snapshot.related(to: e)) { a in
                    Button(a.title) { m.go(.entry(a.id)) }.buttonStyle(SidebarLinkStyle())
                        .contextMenu { RelationMenu(model: m, entry: e, target: .entry(a.id)) }
                }
                ForEach(e.anchors,id:\.self) { a in
                    Button(a.quote) { if m.valid(.doc(a.report)) { m.go(.doc(a.report),anchor:a) } }.buttonStyle(SidebarLinkStyle())
                        .contextMenu { RelationMenu(model: m, entry: e, target: .quote(a)) }
                }
            } else { Text("打开报告或条目以查看关联。").foregroundStyle(.secondary) }
        }.font(.system(size:12)).padding(15).frame(maxWidth:.infinity,alignment:.leading) }
    }
}
