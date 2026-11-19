import SwiftUI
import AppKit
import Combine
import WebKit

// SimaQ's Tana Light paper and sidebar use neutral sRGB grays.
let paper = Color(.sRGB, white: 244.0 / 255, opacity: 1)
let rail = Color(.sRGB, white: 238.0 / 255, opacity: 1)
let leaf = Color(red: 0.29, green: 0.35, blue: 0.45)
let ink = Color(.sRGB, white: 0.22, opacity: 1)
extension Kind {
    var tint: Color {
        switch self { case .concepts: return Color(red: 0.49,green: 0.39,blue: 0.65)
        case .events: return Color(red: 0.68,green: 0.41,blue: 0.26)
        case .entities: return Color(red: 0.32,green: 0.48,blue: 0.60)
        case .questions: return Color(red: 0.58,green: 0.46,blue: 0.19)
        default: return leaf }
    }
}
struct Tag: View {
    var text: String; var color: Color = leaf
    var body: some View { Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color).padding(.horizontal,6).padding(.vertical,3).background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 4)) }
}
struct Primary: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).padding(.horizontal,14).padding(.vertical,8).foregroundStyle(.white).background(.tint.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 7))
    }
}
@MainActor final class FeynmanDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: Workspace?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspace?.finishInlineNote() == false ? .terminateCancel : .terminateNow
    }
}

@main struct FeynmanApp: App {
    @NSApplicationDelegateAdaptor(FeynmanDelegate.self) private var delegate
    @StateObject var model = Workspace()
    var body: some Scene {
        Window("Feynman", id: "workspace") {
            MainView(model: model).onAppear { delegate.workspace = model }.frame(minWidth: 790, minHeight: 530).preferredColorScheme(.light).tint(leaf)
        }.windowStyle(.hiddenTitleBar).defaultSize(width: 1150, height: 770)
        .commands {
            CommandGroup(replacing: .newItem) { Button("New Project…") { model.dialog = .create }.keyboardShortcut("n") }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { model.dialog = .settings }.keyboardShortcut(",") }
            HistoryCommands(model: model)
            CommandMenu("Research") {
                Button("Project List") { model.home(); model.refreshProjects() }.keyboardShortcut("l", modifiers: [.command,.shift])
                Button("Refresh Files") { model.refresh() }.keyboardShortcut("r")
                Button { model.researchProject() } label: {
                    if model.hasPreflight { Text("Continue Project Research…") } else { Text("Start Preliminary Research") }
                }.disabled(model.project == nil)
            }
        }
    }
}

private struct EditingNavigationKeys: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var editingNavigationKeys: Bool? {
        get { self[EditingNavigationKeys.self] }
        set { self[EditingNavigationKeys.self] = newValue }
    }
}
private struct HistoryCommands: Commands {
    @ObservedObject var model: Workspace
    @FocusedValue(\.editingNavigationKeys) var editing
    var body: some Commands {
        let backEnabled = model.canGoBack && model.dialog == nil
        let forwardEnabled = model.canGoForward && model.dialog == nil
        let usingArrows = editing != true && model.inlineNote == nil
        CommandMenu("History") {
            Button("Back") { model.navigate(.back) }.keyboardShortcut("[").disabled(!backEnabled)
            Button("Forward") { model.navigate(.forward) }.keyboardShortcut("]").disabled(!forwardEnabled)
            Divider()
            Button("Go to First Page") { model.navigate(.first) }.keyboardShortcut(.leftArrow)
                .disabled(!backEnabled || !usingArrows)
            Button("Go to Last Page") { model.navigate(.last) }.keyboardShortcut(.rightArrow)
                .disabled(!forwardEnabled || !usingArrows)
        }
    }
}

struct MainView: View {
    @ObservedObject var model: Workspace
    @State private var sidebar = true
    @State private var historyKeyMonitor: Any?
    @AppStorage("outlineWidth") private var outlineWidth = 236.0
    @AppStorage("relationsWidth") private var relationsWidth = 0.0
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        GeometryReader { geometry in
            let maxOutline = max(155, min(490, geometry.size.width - 555))
            let outline = max(155, min(outlineWidth, maxOutline))
            let available = geometry.size.width - (sidebar ? outline + 9 : 0)
            let maxRelations = max(220, available - 303)
            let preferred = relationsWidth > 0 ? relationsWidth : min(780, max(465, available * 0.49))
            let relations = max(220, min(preferred, maxRelations))
            HStack(spacing: 0) {
            if sidebar {
                Sidebar(m: model).frame(width: outline).background(rail)
                PaneDivider(label: "大纲宽度", width: outline, direction: 1) {
                    outlineWidth = max(155, min($0, maxOutline))
                }
            }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { sidebar.toggle() } label: { Image(systemName:"sidebar.left") }.help("切换大纲")
                    if model.project != nil {
                        Button { if model.canGoBack { model.navigate(.back) } else { model.home() } } label: { Image(systemName:"chevron.left") }.help(model.canGoBack ? "返回上一页" : "返回项目列表")
                        Button { model.navigate(.forward) } label: { Image(systemName:"chevron.right") }.help("前进").disabled(!model.canGoForward)
                    }
                    Text(model.project?.info.title ?? "项目空间").lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    if let p = model.project {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([p.url]) } label: { Image(systemName:"folder") }.help("在 Finder 中显示项目")
                        if let recent = model.consoles.last(where: { $0.project.id == p.id }) {
                            Button { model.selectedConsole = model.activeConsole == nil ? recent.id : nil } label: { Image(systemName:"terminal") }.help("显示或收起研究终端")
                        }
                        Button { if model.displayedEntry != nil { model.showEntryRelations.toggle() } else { model.inspect.toggle() } } label: { Image(systemName:"sidebar.right") }.help("显示关联与出处")
                    }
                    Button { model.dialog = .settings } label: { Image(systemName:"gearshape") }.help("本机设置")
                }.buttonStyle(.plain).foregroundStyle(leaf).padding(.horizontal,20).frame(height:48)
                 .background(WindowTitleSurface())

                Divider()
                VSplitView {
                    HStack(spacing: 0) {
                        Group {
                            if let p = model.project { ProjectDetail(m:model,p:p) } else { LibraryView(m:model) }
                        }.frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                        if model.showEntryRelations, let entry = model.displayedEntry, model.project != nil {
                            PaneDivider(label: "关系图宽度", width: relations, direction: -1) {
                                relationsWidth = max(220, min($0, maxRelations))
                            }
                            ScrollView {
                                EntryRelations(model: model, entry: entry, graphWidth: relations - 32).padding(16)
                            }.frame(width: relations)
                        } else if model.inspect, model.project != nil {
                            PaneDivider(label: "出处栏宽度", width: relations, direction: -1) {
                                relationsWidth = max(220, min($0, maxRelations))
                            }
                            Inspector(m:model).frame(width: relations)
                        }
                    }.frame(minHeight:170)
                    if let session = model.activeConsole {
                        ResearchPanel(model:model, session:session).frame(minHeight: geometry.size.height / 3).focusedValue(\.editingNavigationKeys, true)
                    }
                }
                if !model.notice.isEmpty || !model.snapshot.issues.isEmpty {
                    HStack { Text(model.notice.isEmpty ? model.snapshot.issues.joined(separator:" · ") : model.notice).font(.caption); Spacer(); Button("关闭") { model.notice = ""; model.snapshot.issues = [] }.buttonStyle(.plain) }.padding(8).background(rail)
                }
            }.background(paper)
            }
        }.foregroundStyle(ink).onReceive(timer) { _ in model.poll() }
        .onAppear {
            guard historyKeyMonitor == nil else { return }
            historyKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard let window = event.window, window === NSApp.mainWindow, window.isKeyWindow,
                      window.attachedSheet == nil, NSApp.modalWindow == nil, model.dialog == nil,
                      model.project != nil else { return event }
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                if event.keyCode == 53, modifiers.isEmpty, let session = model.activeConsole,
                   session.handlesEscape {
                    if model.inlineNote != nil || window.firstResponder is NoteTextView || (window.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return event }
                    if !event.isARepeat { model.escapeConsole(session) }
                    return nil
                }
                guard modifiers == .command else { return event }
                let move: HistoryMove
                switch event.charactersIgnoringModifiers {
                case "[": move = .back
                case "]": move = .forward
                default:
                    guard event.specialKey == .leftArrow || event.specialKey == .rightArrow else { return event }
                    if model.inlineNote != nil { return event }
                    if let editor = window.firstResponder as? NSTextView, editor.isEditable { return event }
                    if let view = window.firstResponder as? NSView, let console = model.activeConsole?.web,
                       view === console || view.isDescendant(of: console) { return event }
                    move = event.specialKey == .leftArrow ? .first : .last
                }
                model.navigate(move)
                return nil
            }
        }
        .onDisappear {
            if let historyKeyMonitor { NSEvent.removeMonitor(historyKeyMonitor); self.historyKeyMonitor = nil }
        }
        .sheet(item: $model.dialog) { dialog in Panels(m:model,dialog:dialog).preferredColorScheme(.light).tint(leaf) }
        .onChange(of:model.error) { _, msg in
            if let msg { DispatchQueue.main.async { let alert = NSAlert(); alert.messageText = "未能完成操作"; alert.informativeText = msg; alert.addButton(withTitle:"好"); alert.runModal(); model.error = nil } }
        }
    }
}
// The toolbar handles its empty space. AppKit owns the separate title strip above it.
struct WindowTitleSurface: NSViewRepresentable {
    var pageTitle = false
    class Surface: NSView {
        private var titleMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let titleMonitor { NSEvent.removeMonitor(titleMonitor); self.titleMonitor = nil }
            guard let window else { return }
            titleMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak window] event in
                guard let self, let window, event.window === window, event.clickCount == 2,
                      window.attachedSheet == nil, !window.styleMask.contains(.fullScreen) else { return event }
                if self is PageTitle {
                    guard !self.isHiddenOrHasHiddenAncestor, self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                } else if event.locationInWindow.y < window.contentLayoutRect.maxY { return event }
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    if let button = window.standardWindowButton(kind), !button.isHidden,
                       button.bounds.contains(button.convert(event.locationInWindow, from: nil)) { return event }
                }
                window.performZoom(nil)
                return nil
            }
        }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 { window.performZoom(nil) }
            else { window.performDrag(with: event) }
        }
    }
    // Text selection and scrolling still receive the original single click and drag.
    final class NavigationBar: Surface {}
    final class PageTitle: Surface {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Surface { pageTitle ? PageTitle() : NavigationBar() }
    func updateNSView(_ view: Surface, context: Context) {}
}
private struct PaneDivider: View {
    let label: String
    let width: CGFloat
    let direction: CGFloat
    let change: (CGFloat) -> Void
    @State private var origin: CGFloat?
    @State private var hovered = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.28)).frame(width: 1)
            if hovered || origin != nil {
                Capsule().fill(leaf.opacity(0.65)).frame(width: 3, height: 32)
            }
        }.frame(width: 9).frame(maxHeight: .infinity)
        .background(paper).contentShape(Rectangle())
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { drag in
                let start = origin ?? width
                if origin == nil { origin = start }
                change(start + direction * drag.translation.width)
            }
            .onEnded { _ in origin = nil })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label).accessibilityValue("\(Int(width)) 点")
        .accessibilityAdjustableAction { step in change(width + (step == .increment ? 24 : -24)) }
        .help("拖动调整" + label)
    }
}

struct SidebarLinkStyle: ButtonStyle {
    var selected = false
    var color = leaf
    var fullWidth = true
    var horizontalInset: CGFloat = 6
    var verticalInset: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, verticalInset)
            .contentShape(Rectangle())
            .modifier(SidebarLinkFeedback(selected: selected, color: color, pressed: configuration.isPressed))
    }
}

private struct SidebarLinkFeedback: ViewModifier {
    var selected: Bool
    var color: Color
    var pressed: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        let opacity = pressed ? 0.32 : selected ? (hovered ? 0.28 : 0.18) : (hovered ? 0.12 : 0)
        content.background(color.opacity(opacity), in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovered = $0 }
    }
}

struct Sidebar: View {
    @ObservedObject var m: Workspace
    func row(_ label:String,_ category:PageCategory?,_ place:Place, hover: PageCategory? = nil) -> some View {
        Button { m.go(place) } label: {
            HStack {
                if let category { CategoryTag(category: category, compact: true) }
                Text(label).lineLimit(1)
                Spacer()
            }
        }.buttonStyle(SidebarLinkStyle(selected: m.place == place, color: (hover ?? category)?.color ?? leaf, horizontalInset: 8, verticalInset: 6))
    }
    func toggle(_ name: String) {
        if m.expanded.contains(name) { m.expanded.remove(name) } else { m.expanded.insert(name) }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:9) { Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width:32,height:32); Text("Feynman").font(.system(size:23,weight:.medium,design:.serif)).lineLimit(1).minimumScaleFactor(0.8) }.padding(.leading,18).padding(.top,17).padding(.bottom,20)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { m.home(); m.refreshProjects() } label: { Label { Text("所有项目") } icon: { CategoryTag(category: .project, compact: true) } }.buttonStyle(SidebarLinkStyle(selected: m.project == nil, horizontalInset: 8, verticalInset: 8)).padding(.horizontal,10)
            Divider().padding(.vertical,8)
            if m.project != nil {
                HStack(spacing: 4) {
                    TextField("搜索标题和正文", text: $m.search).focusedValue(\.editingNavigationKeys, true)
                        .textFieldStyle(.roundedBorder)
                    if !m.search.isEmpty {
                        Button { m.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("清空搜索")
                    }
                }.padding(.horizontal,12).padding(.bottom,8)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let retained = m.retainedItems
                        let pinned = Set(retained.map(\.id))
                        if m.search.clean.isEmpty {
                            if !retained.isEmpty {
                                Text("已保留").font(.caption.bold()).foregroundStyle(.secondary)
                                ForEach(retained) { item in searchRow(item, snippet: nil, pinned: true) }
                                Divider().padding(.vertical, 6)
                            }
                            outline
                        } else {
                            HStack {
                                if m.searchPending || m.indexing { Text("正在搜索…") }
                                else { Text("搜索结果（\(m.searchHits.count)）") }
                                Spacer()
                                if m.searchHits.contains(where: { !pinned.contains($0.id) }) {
                                    Button("保留全部") { m.retainSearchItems(m.searchHits.map(\.item)) }
                                }
                            }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                            if m.searchHits.isEmpty && !m.searchPending && !m.indexing {
                                Text("没有匹配的条目").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                            }
                            ForEach(m.searchHits) { hit in
                                searchRow(hit.item, snippet: hit.snippet, pinned: pinned.contains(hit.id))
                            }
                        }
                    }.padding(.horizontal,10)
                }
            } else {
                Text("项目").font(.caption).foregroundStyle(.secondary).padding(.horizontal,18).padding(.vertical,8)
                ScrollView { VStack(alignment:.leading) { ForEach(m.projects) { p in Button { m.open(p) } label:{ Text(p.info.title) }.buttonStyle(SidebarLinkStyle()) } }.padding(.horizontal,12) }
            }
            Spacer(minLength:4)
            Divider()
            Button { m.dialog = .settings } label: { Label { Text(m.root?.lastPathComponent ?? "选择工作目录") } icon: { Image(systemName: "folder") }.lineLimit(1) }.buttonStyle(SidebarLinkStyle()).foregroundStyle(.secondary).padding(8)
        }.font(.system(size:13))
    }
    @ViewBuilder private var outline: some View {
        row("项目概览",.project,.overview)
        HStack(spacing: 2) {
            Button { toggle("reports") } label: {
                Image(systemName: m.expanded.contains("reports") ? "chevron.down" : "chevron.right").frame(width: 12)
            }.buttonStyle(SidebarLinkStyle(fullWidth: false, horizontalInset: 2))
            Button { if let report = m.snapshot.reports.last { m.go(.doc(report)) } else { m.go(.overview) } } label: {
                HStack {
                    Label { Text("预研报告") } icon: { CategoryTag(category: .report, compact: true) }
                    Spacer()
                    Text("\(m.snapshot.reports.count)").foregroundStyle(.secondary)
                }
            }.buttonStyle(SidebarLinkStyle())
        }
        if m.expanded.contains("reports") { ForEach(m.snapshot.reports,id:\.self) { r in row(documentLabel(r),nil,.doc(r), hover: .report).padding(.leading,40).contextMenu { Button("编辑报告…") { m.editDoc(r) } } } }
        ForEach(Kind.allCases) { k in
            let entries = m.snapshot.entries.filter { $0.kind == k }
            HStack(spacing:3) {
                Button { toggle(k.rawValue) } label:{ Image(systemName:m.expanded.contains(k.rawValue) ? "chevron.down":"chevron.right").frame(width:13) }.buttonStyle(SidebarLinkStyle(fullWidth: false, horizontalInset: 2))
                Button { m.go(.group(k)); m.expanded.insert(k.rawValue) } label: {
                    HStack(spacing: 3) { CategoryTag(category: .kind(k), compact: true); Text(k.englishLabel).lineLimit(1).minimumScaleFactor(0.85); Spacer(minLength: 1); Text("\(entries.count + (k == .references ? m.snapshot.unlistedMaterials.count : 0))").font(.caption).foregroundStyle(.secondary) }
                }.buttonStyle(SidebarLinkStyle(selected: m.place == .group(k), color: PageCategory.kind(k).color, horizontalInset: 2))
                if k == .references {
                    Menu { AddReferenceActions(m: m) } label: { Image(systemName: "plus").font(.caption) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("添加参考资料")
                } else {
                    Button { m.dialog = .editor(Editor(entry:Entry(kind:k,title:""))) } label:{ Image(systemName:"plus").font(.caption) }.buttonStyle(SidebarLinkStyle(fullWidth: false, horizontalInset: 3)).help("添加 " + k.englishLabel)
                }
            }
            .modifier(ReferenceFileDrop(m: m, enabled: k == .references))
            if m.expanded.contains(k.rawValue) {
                if k == .references {
                    row("网页链接", .webLinks, .webLinks).padding(.leading, 27).modifier(ReferenceFileDrop(m: m))
                    ForEach(m.snapshot.unlistedMaterials.filter { !MaterialLinks.isWeb($0) },id:\.self) { path in
                        Button { m.attempt { m.go(.entry(try m.registerMaterial(path).id)) } } label: { Text((path as NSString).lastPathComponent).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(SidebarLinkStyle(color: PageCategory.kind(k).color)).padding(.leading,42)
                    }
                }
                ForEach(entries.filter { !m.snapshot.isWebReference($0) }) { e in
                    Button { m.go(.entry(e.id)) } label: {
                        HStack(spacing:6) {
                            Text(e.title).lineLimit(1); Spacer(minLength:0)
                            if e.origin == "预研提取" { Tag(text:e.origin,color:Color(white: 0.42)) }
                        }
                    }.buttonStyle(SidebarLinkStyle(selected: m.place == .entry(e.id), color: PageCategory.kind(k).color)).padding(.leading,42).help(e.title).contextMenu { EntryActions(m: m, entry: e) }
                }
            }
        }
        Divider().padding(.vertical,7)
        row("过程日志",.log,.doc("log.md")); row("我的 Memo",.memo,.doc("memo.md"))
    }

    private func searchRow(_ item: ProjectSearchItem, snippet: String?, pinned: Bool) -> some View {
        let selected: Bool = {
            switch item.target {
            case .entry(let id): return m.place == .entry(id)
            case .document(let path): return m.place == .doc(path)
            case .material: return false
            }
        }()
        return HStack(alignment: .top, spacing: 4) {
            Button { m.openSearchItem(item) } label: {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).lineLimit(2)
                        if let snippet { Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(SidebarLinkStyle(selected: selected)).help(item.title)
            Button {
                if pinned { m.removeRetainedItem(item) } else { m.retainSearchItems([item]) }
            } label: { Image(systemName: pinned ? "pin.fill" : "pin") }
                .buttonStyle(SidebarLinkStyle(fullWidth: false, horizontalInset: 3)).foregroundStyle(pinned ? leaf : .secondary)
                .help(pinned ? "取消保留" : "保留在左侧")
        }
        .contextMenu {
            if case .entry(let id) = item.target, let entry = m.snapshot.resolve(id) {
                EntryActions(m: m, entry: entry)
            } else if case .document(let path) = item.target, m.canEditNote(path) {
                Button("编辑文档…") { m.editDoc(path) }
            }
        }
    }

}
struct LibraryView: View {
    @ObservedObject var m: Workspace
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                PageHeading(title: "研究项目", category: .project) {
                    Button { m.dialog = .create } label:{ Label("新建项目",systemImage:"plus") }.buttonStyle(Primary())
                }
                VStack(alignment: .leading, spacing: 20) {
                    if m.projects.isEmpty {
                        VStack(alignment:.leading,spacing:12) {
                            Image(systemName:"folder.badge.plus").font(.system(size:30)).foregroundStyle(leaf)
                            Text("创建第一个研究项目").font(.title3.weight(.medium))
                            Text("为专题命名后，即可在项目工作台开始预研。").foregroundStyle(.secondary)
                        }.padding(24).frame(maxWidth:.infinity,alignment:.leading).background(rail.opacity(0.65),in:RoundedRectangle(cornerRadius:12))
                    } else {
                        ForEach(m.projects) { p in
                            Button { m.open(p) } label: {
                                HStack(spacing:15) { Image(systemName:"folder").foregroundStyle(leaf).font(.title3)
                                    VStack(alignment:.leading,spacing:5) { Text(p.info.title).font(.title3.weight(.medium)); if !p.info.intent.isEmpty { Text(p.info.intent).foregroundStyle(.secondary).lineLimit(2) } }; Spacer(); Image(systemName:"chevron.right").foregroundStyle(.secondary)
                                }.padding(.vertical,12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}
