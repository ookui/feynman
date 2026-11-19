import SwiftUI

struct ProjectDetail: View {
    @ObservedObject var m: Workspace
    var p: ProjectAt
    func jump(_ title: String,_ image:String,_ dest:Place, _ subtitle:String = "") -> some View {
        Button { m.go(dest) } label: {
            HStack(spacing:10) { Image(systemName:image).foregroundStyle(leaf).frame(width:20); Text(title).lineLimit(2); Spacer(); if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }; Image(systemName:"chevron.right").font(.caption2).foregroundStyle(.secondary) }.padding(.vertical,7).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    @ViewBuilder var body: some View {
        switch m.place {
        case .overview: overview
        case .group(.references): ReferenceDirectory(m: m)
        case .webLinks: ReferencePage(m: m)
        case .group(let k): group(k)
        case .entry(let id):
            if let e = m.snapshot.resolve(id) {
                if e.kind == .references { ReferenceFilePage(m: m, entry: e).id(e.id) }
                else { entry(e) }
            } else if let note = m.inlineNote { NoteBody(m: m, path: note.path, text: note.text) }
            else { overview }
        case .doc(let path):
            if let ref = m.referenceDocument(path) { ReferenceFilePage(m: m, entry: ref, document: path).id(path) }
            else { MarkdownPage(m: m, path: path) }
        }
    }
    var overview: some View {
        ScrollView { VStack(alignment:.leading,spacing:18) {
            PageHeading(title: p.info.title, category: .project,
                        metadata: m.snapshot.completed ? "预研已完成" : m.snapshot.reports.isEmpty ? "待预研" : "已有报告",
                        subtitle: p.info.intent) {
                PageActions {
                    Button { m.researchProject() } label: {
                        Label(m.hasPreflight ? "继续研究此项目…" : "开始预研", systemImage: "terminal")
                    }
                    .buttonStyle(ResearchActionStyle())
                    if let report = m.snapshot.reports.last { Button("阅读最新报告") { m.go(.doc(report)) } }
                }
            }
            VStack(alignment: .leading, spacing: 18) {
                let questions = m.snapshot.entries.filter { $0.kind == .questions }
                HStack { Text("待回答的问题").font(.headline); Spacer(); Button { m.dialog = .editor(Editor(entry:Entry(kind:.questions,title:""))) } label:{ Image(systemName:"plus") }.buttonStyle(.plain) }
                if questions.filter({ !$0.answered }).isEmpty { Text(questions.isEmpty ? "可在预研时提取问题，也可以在这里先记下一题。" : "当前问题均已回答。").foregroundStyle(.secondary) }
                ForEach(questions.filter { !$0.answered }) { e in jump(e.title,"questionmark.circle",.entry(e.id)) }
                Divider().padding(.vertical,5)
                Text("项目文档").font(.headline)
                ForEach(m.snapshot.documents + ["memo.md","log.md"],id:\.self) { path in jump(documentLabel(path),"doc.text",.doc(path)) }
            }.padding(.horizontal,24).padding(.bottom,24).frame(maxWidth:850,alignment:.leading)
        }.frame(maxWidth:.infinity,alignment:.leading) }
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
                            jump(e.title, k.symbol, .entry(e.id), e.origin)
                            if k == .questions { QuestionStatusButton(m: m, question: e) }
                        }
                        Divider()
                    }
                }
            }.padding(.horizontal,24).padding(.bottom,24)
        }.frame(maxWidth: .infinity, alignment: .leading) }
    }
    func entry(_ e: Entry) -> some View {
        return VStack(alignment:.leading,spacing:0) {
            let header = PageHeading(title: e.title, category: .kind(e.kind), metadata: e.origin,
                                     status: e.kind == .questions ? QuestionStatusButton(m: m, question: e) : nil,
                                     editing: m.inlineNote.flatMap { $0.path == e.path && $0.editsMetadata ? $0 : nil }) {
                PageActions {
                    if e.kind == .questions {
                        Button("继续研究此问题") { m.launch(.question, context: e.path) }
                            .buttonStyle(ResearchActionStyle())
                    }
                    Button("关联…") { m.dialog = .relate(e) }
                    Menu("更多") {
                        if e.kind != .questions { Button("用 Codex 修订正文") { m.launch(.revise, context:e.path) } }
                        if e.kind == .questions {
                            Button("添加子问题…") {
                                var question = Entry(kind:.questions,title:"")
                                question.links = [e.id]
                                m.dialog = .editor(Editor(entry:question))
                            }
                            Button(e.answered ? "重新打开问题" : "标为已回答") { m.toggleQuestionStatus(e.id) } }
                        Button("引用到我的 Memo") { m.editDoc("memo.md",append:"[" + e.title + "](feynman:" + e.id + ")") }
                        Button("关联知识库资料…") { m.attach(library:true,to:e) }
                        Button("添加参考资料…") { m.attach(library:false,to:e) }
                        Button("回写到知识库…") { m.dialog = .cite(e) }
                        Divider()
                        Button("合并到其他条目…") { m.dialog = .merge(e) }
                        Button("删除条目…") { m.dialog = .remove(e) }
                    }.fixedSize()
                }
            }
            ViewThatFits(in:.vertical) {
                header.fixedSize(horizontal:false,vertical:true)
                ScrollView { header }.frame(height: 405)
            }.frame(maxHeight:405,alignment:.topLeading).fixedSize(horizontal:false,vertical:true)
            Divider()
            NoteBody(m: m, path: e.path, text: e.body, history: e.kind == .questions ? e.questionHistory : nil)

        }
    }
}

struct MarkdownPage: View {
    @ObservedObject var m: Workspace
    let path: String
    var body: some View {
        let result = Result { guard let text = try m.text(path) else { throw Failure("文件尚未同步或已移走。") }; return text }
        let body = (try? result.get()).map { Document($0).body } ?? ""
        return VStack(alignment:.leading,spacing:0) {
            PageHeading(title: documentLabel(path), category: PageCategory(document: path)) { actions(body) }
            Divider()
            if case .failure(let err) = result, m.inlineNote?.path != path { Text(err.localizedDescription).padding() }
            else { NoteBody(m: m, path: path, text: body, extract: path.hasPrefix("reports/") || path == "questions.md") }
        }
    }

    private func actions(_ body: String) -> some View {
        PageActions {
            if path == "memo.md", !body.clean.isEmpty { Button("回写到知识库…") { m.launch(.publish,context:path) } }
            if path.hasPrefix("reports/") {
                Button("用 Codex 修订报告") { m.launch(.revise, context:path) }
                Button("查看出处") { m.inspect.toggle() }
            }
        }
    }

}
struct Inspector: View {
    @ObservedObject var m: Workspace
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
                        QuestionStatusButton(m: m, question: question)
                    }
                }
                let others = owners.filter { $0.kind != .questions }
                if !others.isEmpty {
                    Divider()
                    Text("原文关联条目").font(.headline)
                    ForEach(others) { entry in
                        Button { m.go(.entry(entry.id)) } label: { Label(entry.title,systemImage:entry.kind.symbol) }.buttonStyle(SidebarLinkStyle())
                    }
                }
                Divider()
                Button("查看整篇报告的出处") { m.passage = [] }.buttonStyle(SidebarLinkStyle())
            } else if case .doc(let path) = m.place {
                let entries = m.snapshot.entries.filter { e in e.anchors.contains { $0.report == path } || e.reportLinks.contains(path) || m.snapshot.citations[e.id]?.contains(path) == true }
                if entries.isEmpty { Text("此文档尚无关联条目。").foregroundStyle(.secondary) }
                ForEach(entries) { e in
                    Button { m.go(.entry(e.id)) } label:{ Label(e.title,systemImage:e.kind.symbol).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(SidebarLinkStyle())
                    ForEach(e.anchors.filter { $0.report == path },id:\.self) { a in Button(a.quote) { m.go(.doc(path),anchor:a) }.lineLimit(2).buttonStyle(SidebarLinkStyle()).foregroundStyle(.secondary) }
                }
            } else if case .entry(let id)=m.place, let e=m.snapshot.resolve(id) {
                Button("关联条目…") { m.dialog = .relate(e) }
                ForEach(m.snapshot.related(to: e)) { a in Button(a.title) { m.go(.entry(a.id)) }.buttonStyle(SidebarLinkStyle()) }
                ForEach(e.anchors,id:\.self) { a in Button(a.quote) { if m.valid(.doc(a.report)) { m.go(.doc(a.report),anchor:a) } }.buttonStyle(SidebarLinkStyle()) }
            } else { Text("打开报告或条目以查看关联。").foregroundStyle(.secondary) }
        }.font(.system(size:12)).padding(15).frame(maxWidth:.infinity,alignment:.leading) }
    }
}
