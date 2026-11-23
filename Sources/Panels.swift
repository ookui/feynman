import SwiftUI

struct Panels: View {
    @ObservedObject var m: Workspace
    let dialog: Dialog
    @State private var title = ""
    @State private var intent = ""
    @State private var picked = ""
    @State private var query = ""
    @State private var hits: [ProjectSearchHit] = []
    @State private var finishedQuery: String?
    private struct SearchRequest: Equatable {
        let query: String
        let indexing: Bool
        let revision: Int
    }

    private func options(from entries: [Entry]) -> [Entry] {
        guard !query.clean.isEmpty else { return entries }
        guard finishedQuery == query else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return hits.compactMap { hit in
            guard case .entry(let id) = hit.item.target else { return nil }
            return byID[id]
        }
    }
    @State private var loadedBacklinks: [Backlink] = []
    @State private var backlinkStatus = "正在查找…"
    struct Backlink: Identifiable { var project: ProjectAt; var entry: Entry; var id: String { project.id + "/" + entry.id } }
    var body: some View {
        Group {
            switch dialog {
            case .editor(let editor): EditorPanel(m:m,draft:editor)
            case .settings: SettingsPanel(m:m)
            default: VStack(alignment:.leading,spacing:16) { contents }.padding(24).frame(width:510)
            }
        }.background(paper)
        .task(id: SearchRequest(query: query, indexing: m.indexing, revision: m.revision)) {
            finishedQuery = nil
            guard !query.clean.isEmpty, !m.indexing else { return }
            let worker = Task.detached(priority: .userInitiated) { [query, index = m.searchIndex] in
                index.results(query, entriesOnly: true)
            }
            let matches = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            hits = matches
            finishedQuery = query
        }
    }
    func cancel() -> some View { Button("取消") { m.dialog=nil }.keyboardShortcut(.cancelAction) }
    @ViewBuilder var contents: some View {
        switch dialog {
        case .create:
            Text("新建研究项目").font(.title2.bold())
            TextField("项目名称，例如 AI 医疗",text:$title)
            TextField("你想弄清什么？（选填）",text:$intent,axis:.vertical).lineLimit(2...5)
            if let root = m.root { Text("保存到 " + root.appendingPathComponent("Feynman").path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            else { Button("选择工作目录…") { if let url = m.chooseFolder("选择知识库或其他工作目录") { m.setRoot(url) } } }
            HStack { Spacer(); cancel(); Button("创建项目") { m.create(title,intent:intent) }.keyboardShortcut(.defaultAction).disabled(title.clean.isEmpty || m.root == nil) }
        case .continueProject:
            Text("继续研究此项目").font(.title2.bold())
            let questions = m.snapshot.entries.filter { $0.kind == .questions }
            TextField("查找要继续研究的问题", text:$query)
            let options = self.options(from: questions)
            List(options, selection:$picked) { item in
                HStack { Text(item.title); Spacer(); Text(item.answered ? "已回答" : "待回答").font(.caption).foregroundStyle(.secondary) }.tag(item.id)
            }.frame(height:185)
            HStack {
                if let report = m.snapshot.reports.last {
                    Button("修订最新报告") { m.dialog=nil; m.go(.doc(report)); m.launch(.revise, context:report) }
                }
                Spacer(); cancel()
                Button("研究所选问题") {
                    guard let item = m.snapshot.resolve(picked) else { return }
                    m.dialog=nil; m.go(.entry(item.id)); m.launch(.question, context:item.path)
                }.keyboardShortcut(.defaultAction).disabled(!options.contains { $0.id == picked })
            }
        case .merge(let e), .relate(let e):
            let merging: Bool = { if case .merge = dialog { return true }; return false }()
            let current = m.snapshot.resolve(e.id)
            let linked = Set(current.map { m.snapshot.related(to: $0).map(\.id) } ?? [])
            Text((merging ? "合并「" : "关联「") + (current?.title ?? e.title) + "」").font(.title3.bold())
            Text(merging ? "选择要保留的同类条目。正文、出处和旧引用会一起保留。" : "选择要关联的条目。两个条目均可查看这个关联。").foregroundStyle(.secondary)
            TextField("搜索条目",text:$query)
            let options = self.options(from: m.snapshot.entries.filter { $0.id != current?.id && (!merging || $0.kind == e.kind) })
            if options.isEmpty { Text(finishedQuery == query || query.clean.isEmpty ? "没有匹配的条目。" : "正在搜索…").foregroundStyle(.secondary) }
            List(options,selection:$picked) { item in HStack { Tag(text:item.kind.label,color:item.kind.tint); Text(item.title); if linked.contains(item.id) { Image(systemName:"link") } }.tag(item.id) }.frame(height:175)
            HStack { Spacer(); cancel(); Button(merging ? "合并" : linked.contains(picked) ? "移除此关联" : "关联") {
                guard let t=m.snapshot.resolve(picked), let p=m.project else { return }
                m.attempt {
                    if merging { try Files.merge(e,into:t,at:p.url); m.refresh(); m.go(.entry(t.id)) }
                    else { try m.setRelation(from: e.id, to: t.id, present: !linked.contains(t.id)) }
                    m.dialog=nil
                }
            }.disabled(current == nil || !options.contains { $0.id == picked }).keyboardShortcut(.defaultAction) }
        case .remove(let e):
            Text("删除「" + e.title + "」？").font(.title3.bold())
            Text("同时移除项目中指向此条目的关联。报告和 Memo 保留原文，指向已删条目的链接将显示为普通文字。")
            HStack { Spacer(); cancel(); Button("删除",role:.destructive) { m.attempt { var item=e; item.deleted=true; try m.store(item); m.dialog=nil; m.go(.group(e.kind)) } } }
        case .cite(let e):
            Text("回写到知识库").font(.title3.bold()); Text("在工作台终端中交给研究终端整理「" + e.title + "」，按当前知识库规范写入并记录反向引用。")
            HStack { Spacer(); cancel(); Button("打开终端") { m.dialog=nil; m.launch(.publish,context:e.path) }.keyboardShortcut(.defaultAction) }
        case .backlinks(let asset):
            Text("引用这份资料的项目").font(.title3.bold()); Text(String(asset.dropFirst(8))).font(.caption).foregroundStyle(.secondary)
            if loadedBacklinks.isEmpty { Text(backlinkStatus) }
            ScrollView { VStack(alignment:.leading) { ForEach(loadedBacklinks) { hit in Button(hit.project.info.title + " › " + hit.entry.title) { m.dialog=nil; m.open(hit.project); m.go(.entry(hit.entry.id)) }.buttonStyle(.link) } } }.frame(maxHeight:230)
                .task {
                    let projects = m.projects
                    do {
                        loadedBacklinks = try await Task.detached {
                            var results: [Backlink] = []
                            for p in projects { for e in try Files.scan(p.url).entries where e.assets.contains(asset) { results.append(Backlink(project:p,entry:e)) } }
                            return results
                        }.value
                        backlinkStatus = "未找到引用。"
                    } catch { backlinkStatus = error.localizedDescription }
                }
            HStack { Spacer(); Button("关闭") { m.dialog=nil }.keyboardShortcut(.cancelAction) }
        default: EmptyView()
        }
    }
}

struct EditorPanel: View {
    @ObservedObject var m: Workspace
    let draft: Editor
    @State var title: String
    @State private var sourceURL = ""
    @State var content: String
    @State var target = ""
    @State var expected: String?
    @State var compare = false
    @State var latest: String?
    @State var latestEntry: Entry?
    @State var status = ""
    init(m:Workspace,draft:Editor) {
        self.m=m; self.draft=draft
        _title=State(initialValue:draft.entry?.title ?? "")
        let body = draft.entry?.body ?? Document(draft.original ?? "").body
        _content=State(initialValue:body + (draft.addToMemo.isEmpty ? "" : (body.isEmpty ? "" : "\n\n") + draft.addToMemo + "\n"))
        _expected=State(initialValue:draft.entry?.original ?? draft.original)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(draft.path.map(documentLabel) ?? ((draft.entry?.original == nil ? "添加" : "编辑") + (draft.entry?.kind.label ?? "条目"))).font(.title2.bold())
            if let a=draft.anchor, let e=draft.entry {
                Text("“" + a.quote + "”").lineLimit(3).foregroundStyle(.secondary)
                Picker("保存为",selection:$target) { Text("新建" + e.kind.label).tag(""); ForEach(m.snapshot.entries.filter { $0.kind == e.kind }) { item in Text("关联到 " + item.title).tag(item.id) } }
            }
            if target.isEmpty {
                if draft.entry != nil { TextField("标题",text:$title) }
                if draft.entry?.kind == .references { TextField("添加来源网址（选填）", text: $sourceURL) }
                Text(draft.entry?.kind == .questions ? "回答与证据（Markdown）" : "正文（Markdown）").font(.caption).foregroundStyle(.secondary)
                if let path = draft.entry?.path ?? draft.path, let url = try? m.documentURL(path) {
                    MarkdownSourceView(url: url, initialText: content, changed: { value, _ in content = value },
                                       pasteError: { status = $0.localizedDescription })
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.25))).frame(minHeight: 150)
                }
            }
            if !draft.cloudCopies.isEmpty {
                Text("iCloud 同步返回了其他版本，请对照后合并到上方正文。").font(.headline)
                ScrollView {
                    ForEach(draft.cloudCopies) { copy in
                        VStack(alignment:.leading) {
                            Text(copy.version.localizedNameOfSavingComputer ?? "其他 Mac").font(.caption.bold())
                            Text(Document(copy.content).body).textSelection(.enabled)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }
                }.frame(height:100)
            }
            if compare {
                Text("磁盘上的最新版本").font(.headline)
                ScrollView { Text(latest ?? "（文件已删除）").textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(height:95)
            }
            if !status.isEmpty { Text(status).foregroundStyle(.orange).font(.caption) }
            HStack { Spacer(); Button("取消") { m.dialog=nil }.keyboardShortcut(.cancelAction)
                Button(!draft.cloudCopies.isEmpty ? "合并并保存" : compare ? "保存已核对的草稿" : "保存") { save() }.keyboardShortcut("s").buttonStyle(Primary()).disabled(target.isEmpty && draft.entry != nil && title.clean.isEmpty)
            }
        }.padding(22).frame(width:570,height:target.isEmpty ? (compare ? 590:445) : 205)
    }
    func save() {
        guard m.project != nil else { return }
        do {
            if var e=draft.entry {
                if !target.isEmpty {
                    guard let existing=m.snapshot.resolve(target), let a=draft.anchor else { throw Failure("关联目标已变更。") }
                    e=existing
                    if !e.anchors.contains(a) { e.anchors.append(a) }
                } else {
                    if let latestEntry { e=latestEntry }
                    e.title=title.clean; e.body=content; e.original=expected
                    if e.kind == .references, !sourceURL.clean.isEmpty {
                        guard let url = URL(string: sourceURL.clean), ["https","http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw Failure("请输入完整的 http 或 https 网址。") }
                        if !e.assets.contains(url.absoluteString) { e.assets.append(url.absoluteString) }
                    }
                    if let a=draft.anchor, !e.anchors.contains(a) { e.anchors.append(a) }
                }
                try m.store(e); m.go(.entry(e.id))
            } else if let path=draft.path {
                let header=Document(expected ?? "").header
                try Files.save(m.documentURL(path), header + content, expected: expected)
                for copy in draft.cloudCopies { copy.version.isResolved = true }
                m.refresh(); m.go(draft.returnTo ?? .doc(path))
            }
            m.dialog=nil
        } catch {
            status=error.localizedDescription
            if target.isEmpty, let path=draft.path ?? draft.entry?.path {
                do {
                    let disk=try m.text(path)
                    if disk != expected {
                        compare=true; latest=disk; expected=disk
                        if let k=draft.entry?.kind, let disk { latestEntry=Entry(kind:k,path:path,raw:disk) }
                    }
                } catch { status=error.localizedDescription }
            }
        }
    }
}

private enum MenuLanguage: String, CaseIterable {
    case system, english = "en", simplified = "zh-Hans", traditional = "zh-Hant"

    static var selected: Self {
        guard let id = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String],
              let first = languages.first else { return .system }
        let language = Locale.Language(identifier: first)
        switch language.languageCode?.identifier {
        case "en": return .english
        case "zh": return language.script?.identifier == "Hant" ? .traditional : .simplified
        default: return .system
        }
    }

    func save() {
        // AppKit reads the bundle's preferred language when it creates the standard menus.
        if self == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([rawValue], forKey: "AppleLanguages") }
    }
}

struct SettingsPanel: View {
    @ObservedObject var m: Workspace
    @AppStorage("researchProvider") var provider = ResearchProvider.codex
    @State var cli = UserDefaults.standard.string(forKey: ResearchProvider.selected.pathKey) ?? ""
    @State var action = Action.preflight
    @State var skill = Terminal.skill(.preflight)
    @State var prompt = Terminal.instruction(.preflight)
    @State var test = ""
    @State var detected = ""
    @State private var menuLanguage = MenuLanguage.selected
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("本机设置").font(.title2.bold())
            HStack {
                Picker("Menu Bar Language", selection: $menuLanguage) {
                    Text("Follow System").tag(MenuLanguage.system)
                    Text(verbatim: "English").tag(MenuLanguage.english)
                    Text(verbatim: "简体中文").tag(MenuLanguage.simplified)
                    Text(verbatim: "繁體中文").tag(MenuLanguage.traditional)
                }.fixedSize()
                Text("Applies after restarting Feynman.").font(.caption).foregroundStyle(.secondary)
            }.onChange(of: menuLanguage) { _, choice in choice.save() }
            Text("工作目录").font(.headline)
            HStack { Text(m.root?.path ?? "尚未选择").lineLimit(2).textSelection(.enabled); Spacer(); Button("选择…") { if let url=m.chooseFolder("选择知识库或工作目录，新项目将保存在其中的 Feynman 目录") { m.setRoot(url) } } }
            Divider()
            OverviewShortcutSetting()
            Picker("研究终端", selection: $provider) {
                ForEach(ResearchProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).onChange(of: provider) { _, next in
                cli = UserDefaults.standard.string(forKey: next.pathKey) ?? ""
                test = ""
                detect()
            }
            HStack { TextField("自动检测，或输入可执行文件路径",text:$cli); Button("浏览…") { let panel=NSOpenPanel(); if panel.runModal() == .OK, let url=panel.url { cli=url.path } } }
            Text(detected).lineLimit(2).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack { Button("检测 CLI 版本") {
                Task {
                    do {
                        let url = try Terminal.executable(cli, provider: provider)
                        test = try await Task.detached { try Terminal.version(url) }.value
                    } catch { test = error.localizedDescription }
                }
            }; Text(test).font(.caption) }
            Divider()
            Picker("研究动作",selection:$action) { ForEach(Action.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if action == .question { Text("由当前研究终端直接回答问题").foregroundStyle(.secondary) }
            else { TextField("Skill 名称（可留空）",text:$skill) }
            Text("默认指令").font(.caption).foregroundStyle(.secondary)
            TextEditor(text:$prompt).frame(height:64).border(.gray.opacity(0.25))
            HStack { Spacer(); Button("完成") { persist(); m.dialog=nil }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width:565).onAppear { detect() }
        .onChange(of:cli) { UserDefaults.standard.set(cli, forKey: provider.pathKey); detect() }
        .onChange(of:action) { _, new in skill=Terminal.skill(new); prompt=Terminal.instruction(new) }
        .onChange(of:skill) { persist() }.onChange(of:prompt) { persist() }
    }
    func persist() { UserDefaults.standard.set(skill.clean,forKey:"skill." + action.rawValue); UserDefaults.standard.set(prompt,forKey:"prompt." + action.rawValue) }
    func detect() { do { detected=try Terminal.executable(cli, provider: provider).path } catch { detected=error.localizedDescription } }
}
