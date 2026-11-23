import SwiftUI
import WebKit
import UniformTypeIdentifiers

enum Place: Hashable {
    case overview, preliminary, webLinks, group(Kind), entry(String), doc(String)
    var key: String {
        switch self { case .overview: return "home"; case .preliminary: return "preliminary"; case .webLinks: return "web-links"; case .group(let k): return "group:" + k.rawValue
        case .entry(let id): return "entry:" + id; case .doc(let path): return "doc:" + path }
    }
    init(_ key: String?) {
        guard let key else { self = .overview; return }
        let value = String(key.drop { $0 != ":" }.dropFirst())
        if key == "preliminary" { self = .preliminary }
        else if key == "web-links" { self = .webLinks }
        else if key.hasPrefix("doc:") { self = .doc(value) }
        else if key.hasPrefix("entry:") { self = .entry(value) }
        else if key.hasPrefix("group:"), let k = Kind(rawValue: value) { self = .group(k) }
        else { self = .overview }
    }
}
enum HistoryMove { case back, forward, first, last }
private struct Visit {
    var place: Place
    var anchor: Anchor?
    var passage: [Anchor] = []
    var fragment: String?
}
struct CloudCopy: Identifiable {
    let id = UUID()
    let version: NSFileVersion
    let content: String
}
struct Editor: Identifiable {
    let id = UUID()
    var entry: Entry?
    var path: String?
    var original: String?
    var anchor: Anchor?
    var returnTo: Place?
    var addToMemo = ""
    var cloudCopies: [CloudCopy] = []
}
enum Dialog: Identifiable {
    case create, settings, continueProject, editor(Editor), merge(Entry), relate(Entry), remove(Entry), backlinks(String), cite(Entry)
    var id: String {
        switch self {
        case .continueProject: return "continueProject"
        case .create: return "create"
        case .settings: return "settings"
        case .editor(let e): return e.id.uuidString
        case .merge(let e): return "merge:" + e.id
        case .relate(let e): return "relate:" + e.id
        case .remove(let e): return "remove:" + e.id
        case .backlinks(let path): return "backlinks:" + path
        case .cite(let e): return "publish:" + e.id
        }
    }
}
@MainActor final class Workspace: ObservableObject {
    @Published var root: URL?
    @Published var projects: [ProjectAt] = []
    @Published var project: ProjectAt?
    @Published var snapshot = Snapshot()
    @Published var place: Place = .overview
    @Published var inlineNote: InlineNoteDraft?
    var readingPosition: (path: String, offset: Int)?
    @Published var dialog: Dialog?
    @Published var error: String?
    @Published var notice = ""
    @Published var headingFragment: String?
    @Published var focus: Anchor?
    @Published var passage: [Anchor] = []
    @Published var inspect = false {
        didSet { if !inspect && !passage.isEmpty { passage = [] } }
    }
    @Published var consoles: [ResearchSession] = []
    @Published var selectedConsole: UUID?
    @Published var showEntryRelations = true
    var activeConsole: ResearchSession? { consoles.first { $0.id == selectedConsole && $0.project.id == project?.id } }
    @Published var revision = 0
    @Published var expanded: Set<String> = [] {
        didSet {
            if let project, expanded != oldValue { preferences.set(expanded.sorted(), forKey: "outlineExpanded." + project.id) }
        }
    }
    @Published var searchOptions = ProjectSearchOptions() { didSet { updateSearch() } }
    @Published var searchDocument: String? { didSet { updateSearch() } }
    @Published var searchLanding: SearchOccurrence?
    @Published var searchNavigation: UUID?
    weak var readerWeb: WKWebView?
    @Published var search = "" { didSet { updateSearch() } }
    @Published private(set) var searchIndex = ProjectSearchIndex()
    @Published private(set) var searchHits: [ProjectSearchHit] = []
    @Published private(set) var searchPending = false
    @Published private(set) var indexing = false
    @Published private(set) var retainedSearchKeys: [String] = []
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    var retainedItems: [ProjectSearchItem] {
        var seen = Set<String>()
        return retainedSearchKeys.compactMap { searchIndex.itemsByKey[$0] }.filter { seen.insert($0.id).inserted }
    }

    func retainSearchItems(_ items: [ProjectSearchItem]) {
        guard let project else { return }
        var existing = Set(retainedItems.map(\.id))
        retainedSearchKeys += items.filter { existing.insert($0.id).inserted }.map(\.id)
        preferences.set(retainedSearchKeys, forKey: "searchPins." + project.id)
    }

    func removeRetainedItem(_ item: ProjectSearchItem) {
        guard let project else { return }
        retainedSearchKeys.removeAll { $0 == item.id || searchIndex.itemsByKey[$0]?.id == item.id }
        preferences.set(retainedSearchKeys, forKey: "searchPins." + project.id)
    }

    func openSearchItem(_ item: ProjectSearchItem) {
        switch item.target {
        case .entry(let id): if let entry = snapshot.resolve(id) { go(.entry(entry.id)) }
        case .document(let path): go(.doc(path))
        case .material(let source): attempt { go(.entry(try registerMaterial(source).id)) }
        }
    }

    func openSearchOccurrence(_ hit: ProjectSearchHit, _ occurrence: SearchOccurrence?) {
        guard finishInlineNote() else { return }
        if case .material = hit.item.target { openSearchItem(hit.item) }
        if let occurrence {
            if let entry = snapshot.entry(at: occurrence.path) { go(.entry(entry.id)) }
            else if valid(.doc(occurrence.path)) { go(.doc(occurrence.path)) }
            else { openSearchItem(hit.item) }
            searchLanding = occurrence
        } else { openSearchItem(hit.item) }
        searchNavigation = UUID()
    }

    private func resetSearch(for project: ProjectAt?) {
        indexTask?.cancel()
        indexing = false
        searchIndex = ProjectSearchIndex()
        searchDocument = nil
        searchLanding = nil
        search = ""
        retainedSearchKeys = project.flatMap { preferences.stringArray(forKey: "searchPins." + $0.id) } ?? []
    }

    private func rebuildSearchIndex(_ project: ProjectAt) {
        indexTask?.cancel()
        indexing = true
        let worker = Task.detached(priority: .utility) { [snapshot, searchIndex] in
            ProjectSearchIndex(snapshot: snapshot, root: project.url, previous: searchIndex)
        }
        indexTask = Task {
            let index = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            searchIndex = index
            indexing = false
            updateSearch(clearResults: false)
        }
    }

    private func updateSearch(clearResults: Bool = true) {
        searchTask?.cancel()
        if clearResults { searchHits = [] }
        searchPending = !search.clean.isEmpty
        guard searchPending else { return }
        searchTask = Task { [searchIndex, search, searchOptions, searchDocument] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) { searchIndex.results(search, options: searchOptions, document: searchDocument) }
            let hits = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            searchHits = hits
            searchPending = false
        }
    }

    @Published private var previousVisits: [Visit] = []
    @Published private var nextVisits: [Visit] = []
    var canGoBack: Bool { !previousVisits.isEmpty }
    var canGoForward: Bool { !nextVisits.isEmpty }
    private var currentVisit: Visit { Visit(place: place, anchor: focus, passage: passage, fragment: headingFragment) }
    var generation = 0
    var refreshing = false
    var lastSignature: String?
    private let preferences = UserDefaults.standard
    private let linkConfiguration: URLSessionConfiguration
    init(linkConfiguration: URLSessionConfiguration = .ephemeral) {
        self.linkConfiguration = linkConfiguration
        let home = fm.homeDirectoryForCurrentUser
        let candidates = ["LakeHouse", "Library/Mobile Documents/com~apple~CloudDocs/LakeHouse"]
        root = preferences.string(forKey: "workspace").map { URL(fileURLWithPath: $0) } ?? candidates.map { home.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
        refreshProjects()
    }
    func attempt(_ body: () throws -> Void) { do { try body() } catch { self.error = error.localizedDescription } }
    func refreshProjects() { if let root { attempt { projects = try Files.projects(root) } } }
    func chooseFolder(_ text: String) -> URL? {
        let panel = NSOpenPanel(); panel.message = text; panel.canChooseFiles = false; panel.canChooseDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    func setRoot(_ value: URL) {
        guard finishInlineNote() else { return }
        root = value; preferences.set(value.path, forKey: "workspace"); home(); refreshProjects()
    }
    func open(_ p: ProjectAt) {
        guard finishInlineNote() else { return }
        generation += 1; project = p; snapshot = Snapshot(); lastSignature = nil; resetSearch(for: p); focus = nil; headingFragment = nil; inspect = false
        previousVisits = []; nextVisits = []
        refresh()
        let dest = Place(preferences.string(forKey: "last." + p.id))
        place = valid(dest) ? dest : .overview
        if let saved = preferences.stringArray(forKey: "outlineExpanded." + p.id) {
            expanded = Set(saved)
        } else {
            expanded = Set(snapshot.entries.map { $0.kind.rawValue } + ["reports"])
            if !snapshot.looseAssets.isEmpty { expanded.insert(Kind.references.rawValue) }
        }
    }
    func valid(_ p: Place) -> Bool {
        switch p {
        case .entry(let id): return snapshot.resolve(id) != nil
        case .doc(let path):
            guard !snapshot.deletedPaths.contains(path) else { return false }
            if snapshot.documents.contains(path) || snapshot.reports.contains(path) || ["memo.md","log.md"].contains(path) { return true }
            guard let url = try? documentURL(path), Self.isMarkdown(url) || referenceDocument(path) != nil else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        default: return true
        }
    }
    func home() {
        guard finishInlineNote() else { return }
        generation += 1; project = nil; place = .overview; snapshot = Snapshot(); notice = ""; focus = nil; headingFragment = nil; inspect = false; resetSearch(for: nil)
        previousVisits = []; nextVisits = []
    }
    func go(_ p: Place, anchor: Anchor? = nil, fragment: String? = nil) {
        guard finishInlineNote() else { return }
        if place != p || focus != anchor || headingFragment != fragment {
            if valid(place) { previousVisits.append(currentVisit) }
            nextVisits = []
        }
        display(Visit(place: p, anchor: anchor, fragment: fragment))
    }
    func navigate(_ move: HistoryMove) {
        guard finishInlineNote() else { return }
        let backward = move == .back || move == .first
        let steps = backward ? previousVisits.count : nextVisits.count
        guard steps > 0 else { return }
        var visit = currentVisit
        for _ in 0..<(move == .first || move == .last ? steps : 1) {
            if backward {
                if valid(visit.place) { nextVisits.append(visit) }
                visit = previousVisits.removeLast()
            } else {
                if valid(visit.place) { previousVisits.append(visit) }
                visit = nextVisits.removeLast()
            }
        }
        visit.passage.removeAll { snapshot.owners(of: [$0]).isEmpty }
        if let anchor = visit.anchor, snapshot.owners(of: [anchor]).isEmpty { visit.anchor = nil }
        display(visit)
    }
    private func display(_ visit: Visit) {
        let p = visit.place
        searchNavigation = nil
        searchLanding = nil
        readingPosition = nil
        place = p; focus = visit.anchor; headingFragment = visit.fragment; notice = ""; inspect = visit.anchor != nil; passage = visit.passage
        if let project { preferences.set(p.key, forKey: "last." + project.id) }
        if case .entry(let id) = p, let e = snapshot.resolve(id) { expanded.insert(e.kind.rawValue) }
    }
    func refresh() {
        guard let project else { refreshProjects(); return }
        attempt {
            try Files.upgradeLegacySelections(in: project.url)
            snapshot = try Files.scan(project.url)
            if snapshot.needsLinkCleanup {
                try Files.resumeLinkCleanup(in: project.url)
                snapshot = try Files.scan(project.url)
            }
            if snapshot.needsArchiveUpdate {
                try Files.updateArchivedAssets(in: project.url)
                snapshot = try Files.scan(project.url)
            }
            previousVisits.removeAll { !valid($0.place) }
            nextVisits.removeAll { !valid($0.place) }
            passage.removeAll { snapshot.owners(of: [$0]).isEmpty }
            if let focus, snapshot.owners(of: [focus]).isEmpty { self.focus = nil }
            rebuildSearchIndex(project)
            revision += 1
        }
    }
    // Poll lightweight file metadata off the UI thread; only reread documents after a change.
    func poll() {
        guard let p = project, !refreshing else { return }
        refreshing = true
        let token = generation
        DispatchQueue.global(qos: .utility).async {
            let stamp = Self.signature(p.url)
            DispatchQueue.main.async {
                self.refreshing = false
                guard token == self.generation, self.lastSignature != stamp else { return }
                self.lastSignature = stamp
                let known = Set(self.snapshot.entries.map(\.kind))
                self.refresh()
                for k in Set(self.snapshot.entries.map(\.kind)).subtracting(known) { self.expanded.insert(k.rawValue) }
                if !self.valid(self.place) { self.go(.overview) }
            }
        }
    }
    nonisolated static func signature(_ root: URL) -> String {
        let dirs = [""] + Kind.allCases.map(\.rawValue) + ["reports", "references/files", Files.referenceMetadataDirectory, "annotations"]
        let keys: [URLResourceKey] = [.contentModificationDateKey,.fileSizeKey]
        return dirs.flatMap { dir -> [String] in
            let base = dir.isEmpty ? root : root.appendingPathComponent(dir)
            let urls = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            return urls.map { url in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return dir + "/" + url.lastPathComponent + ":\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(v?.fileSize ?? 0)"
            }
        }.sorted().joined(separator: "|")
    }
    static func isMarkdown(_ url: URL) -> Bool { ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased()) }

    func documentURL(_ path: String) throws -> URL {
        if path.hasPrefix("library:") || path.hasPrefix("lakehouse:") || path.hasPrefix("project:") {
            return try assetURL(path)
        }
        guard let project else { throw Failure("请先打开一个项目。") }
        return try Files.child(project.url, path)
    }

    func documentKey(for url: URL) throws -> String {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        func relative(to base: URL?) -> String? {
            guard let base else { return nil }
            let prefix = base.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            return target.hasPrefix(prefix) ? String(target.dropFirst(prefix.count)) : nil
        }
        if let path = relative(to: project?.url) { return path }
        if let path = relative(to: root) { return "library:" + path }
        if let path = relative(to: try? lakehouseRoot()) { return "lakehouse:" + path }
        throw Failure("链接超出当前工作目录。")
    }

    func referenceDocument(_ path: String) -> Entry? {
        if let entry = snapshot.entry(at: path) { return entry.kind == .references ? entry : nil }
        if snapshot.documents.contains(path) || snapshot.reports.contains(path) || ["memo.md", "log.md"].contains(path) { return nil }
        let key = ["project:", "library:", "lakehouse:"].contains(where: path.hasPrefix) ? path : "project:" + path
        return snapshot.reference(for: key, from: path)
    }

    var displayedEntry: Entry? {
        switch place {
        case .entry(let id): return snapshot.resolve(id)
        case .doc(let path): return referenceDocument(path)
        default: return nil
        }
    }

    func canEditNote(_ path: String) -> Bool {
        guard !path.hasPrefix("library:"), !path.hasPrefix("lakehouse:"),
              !path.hasPrefix("references/"), !path.hasPrefix("project:references/"),
              let file = try? documentURL(path), Self.isMarkdown(file),
              let key = try? documentKey(for: file), !key.hasPrefix("library:"), !key.hasPrefix("lakehouse:"),
              !key.hasPrefix("references/"), referenceDocument(key) == nil else { return false }
        return true
    }

    func toggleCore(_ entry: Entry) {
        if inlineNote?.path == entry.path, !finishInlineNote() { return }
        attempt {
            guard let project, var live = try Files.scan(project.url).resolve(entry.id) else { throw Failure("条目已移走。") }
            live.core.toggle()
            try store(live)
        }
    }

    func toggleQuestionStatus(_ id: String) {
        guard let entry = snapshot.resolve(id), entry.kind == .questions else { return }
        if inlineNote?.path == entry.path, !finishInlineNote() { return }
        attempt {
            guard let project, var live = try Files.scan(project.url).resolve(id), live.kind == .questions else { throw Failure("问题已移走。") }
            live.answered.toggle()
            try store(live)
        }
    }
    func text(_ path: String) throws -> String? {
        try Files.contents(documentURL(path))
    }
    func create(_ title: String, intent: String, legacy: URL? = nil) {
        guard let root else { error = "请先选择工作目录。"; return }
        attempt {
            let p = try Files.create(root, title: title, intent: intent, legacy: legacy)
            refreshProjects(); dialog = nil; open(p)
        }
    }
    func editDoc(_ path: String, append: String = "") {
        if place != .doc(path) { go(.doc(path)) }
        guard place == .doc(path) else { return }
        beginInlineNote(path, mode: .rich, append: append)
    }
    func store(_ e: Entry) throws {
        guard let project else { throw Failure("请先打开项目。") }
        defer { refresh() }
        try Files.write(e, in: project.url)
    }
    func setRelation(from source: String, to target: String, present: Bool) throws {
        guard let project else { throw Failure("请先打开一个项目。") }
        defer { refresh() }
        try Files.setRelation(from: source, to: target, present: present, in: project.url)
    }
    var hasPreflight: Bool { snapshot.completed || !snapshot.reports.isEmpty }
    func researchProject() {
        if hasPreflight { dialog = .continueProject } else { launch(.preflight) }
    }
    func launch(_ action: Action, context: String? = nil) {
        guard let project, let root else { return }
        attempt {
            let provider = ResearchProvider.selected
            let cli = try Terminal.executable(preferences.string(forKey: provider.pathKey) ?? "", provider: provider)
            if action == .preflight && hasPreflight { dialog = .continueProject; return }
            if let existing = consoles.last(where: { $0.project.id == project.id && $0.provider == provider && $0.action == action && $0.context == context && !$0.exited }) {
                selectedConsole = existing.id; return
            }
            let entry = context.flatMap { snapshot.entry(at: $0) }
            let target: ResearchTarget?
            switch action {
            case .question:
                guard let entry, entry.kind == .questions else { throw Failure("请重新选择要研究的问题。") }
                target = .entry(entry)
            case .revise:
                if let entry { target = .entry(entry) }
                else if let context { target = try .report(context, in: project, reports: snapshot.reports) }
                else { throw Failure("请先选择要修订的内容。") }
            case .archive: throw Failure("请选择要保存的资料。")
            case .preflight, .publish: target = nil
            }
            let prompt = try Terminal.prompt(action, project: project, root: root, context: context, entry: entry)
            let session = ResearchSession(project: project, root: root, action: action, context: context, cli: cli, provider: provider, draft: prompt, target: target)
            session.onSaved = { [weak self] in
                guard self?.project?.url == project.url else { return }
                self?.refresh()
                if case .report(let source, _, let destination) = target, self?.place == .doc(source) {
                    self?.go(.doc(destination))
                }
            }
            consoles.append(session); selectedConsole = session.id
        }
    }
    func escapeConsole(_ session: ResearchSession) {
        if session.exited { selectedConsole = nil }
        else { session.endConversation() }
    }
    func closeConsole(_ session: ResearchSession) {
        session.closeSession()
        consoles.removeAll { $0.id == session.id }
        selectedConsole = consoles.last { $0.project.id == project?.id }?.id
    }
    func attach(library: Bool, to entry: Entry? = nil) {
        guard let project, let root else { error = "请先打开项目。"; return }
        let directory = (library ? try? lakehouseRoot() : nil) ?? root
        let prefix = directory.resolvingSymlinksInPath().standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path ? "library:" : "lakehouse:"
        let mode: ReferenceFileMode = library ? .library(directory: directory, prefix: prefix) : .copy
        let panel = NSOpenPanel()
        panel.title = library ? "关联知识库资料" : "添加参考资料"
        panel.prompt = library ? "关联" : "添加"
        panel.message = library ? "选择知识库中已有的文件" : "所选文件将复制到项目的「参考资料」中"
        panel.directoryURL = library ? directory : nil
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // Present on the workbench after the More menu has finished tracking the click.
        DispatchQueue.main.async {
            let workbench = NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
            guard let workbench else { self.error = "请先打开工作台窗口。"; return }
            panel.beginSheetModal(for: workbench) { response in
                guard response == .OK else { return }
                let files = panel.urls.map { DroppedReference(url: $0) }
                Task { await self.importReferences(files, into: project, mode: mode, ownerID: entry?.id) }
            }
        }
    }

    func importDroppedReferences(_ providers: [NSItemProvider], into destination: ProjectAt) async {
        var items: [DroppedReference] = [], failures: [String] = []
        for provider in providers {
            do { items += try await DroppedReference.read(provider) }
            catch { failures.append(error.localizedDescription) }
        }
        await importReferences(items, into: destination, failures: failures)
    }

    func importReferences(_ items: [DroppedReference], into destination: ProjectAt, mode: ReferenceFileMode = .copy,
                          ownerID: String? = nil, failures initialFailures: [String] = []) async {
        if project?.id == destination.id, items.contains(where: { !$0.url.isFileURL }) { notice = "正在识别链接并下载 PDF…" }
        let (ids, failures) = await Task.detached(priority: .userInitiated) { [linkConfiguration] in
            var ids: [String] = [], failures = initialFailures
            for dropped in items {
                do {
                    let url = dropped.url
                    if url.isFileURL {
                        let id = try Files.registerFile(url, mode: mode, ownerID: ownerID, in: destination.url)
                        if !ids.contains(id) { ids.append(id) }
                    } else {
                        ids.append(try await dropped.importLink(into: destination.url, configuration: linkConfiguration))
                    }
                } catch { failures.append(dropped.url.lastPathComponent + "：" + error.localizedDescription) }
            }
            return (ids, failures)
        }.value
        if project?.id == destination.id {
            refresh()
            if let first = ids.first {
                let webOnly = ids.allSatisfy { snapshot.resolve($0).map(snapshot.isWebReference) == true }
                if let ownerID {
                    let title = snapshot.resolve(ownerID)?.title ?? "条目"
                    notice = "已将 \(ids.count) 项参考资料关联到「\(title)」"
                } else {
                    go(ids.count == 1 ? .entry(first) : webOnly ? .webLinks : .group(.references))
                    notice = webOnly ? "已收录网页链接" : "已导入 \(ids.count) 项资料"
                }
                expanded.insert(Kind.references.rawValue)
            } else { notice = "" }
        }
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }

    func assetURL(_ source: String) throws -> URL {
        let asset = snapshot.archivedDestinations[source] ?? source
        if asset.hasPrefix("lakehouse:") { return try Files.child(lakehouseRoot(), String(asset.dropFirst("lakehouse:".count))) }
        if asset.hasPrefix("library:"), let root { return try Files.child(root, String(asset.dropFirst(8))) }
        if asset.hasPrefix("project:"), let project {
            let url = try Files.child(project.url, String(asset.dropFirst(8)))
            if snapshot.deletedPaths.contains(String(url.path.dropFirst(project.url.resolvingSymlinksInPath().standardizedFileURL.path.count + 1))) { throw Failure("条目已删除。") }
            return url
        }
        throw Failure("资料引用格式无效。")
    }
    func openAsset(_ url: URL, fragment: String? = nil) throws {
        guard fm.fileExists(atPath: url.path) else { throw Failure("文件尚未在本机同步，或路径已变更。") }
        let ext = url.pathExtension.lowercased()
        if let path = try? documentKey(for: url), Self.isMarkdown(url) || referenceDocument(path) != nil {
            guard !snapshot.deletedPaths.contains(path) else { throw Failure("条目已删除。") }
            go(.doc(path), fragment: fragment)
            return
        }
        guard !Self.isMarkdown(url) else { throw Failure("链接超出当前工作目录。") }
        if ["pdf","html","htm","txt","json","svg","png","jpg","jpeg","xlsx","csv","doc","docx","ppt","pptx","webp","gif","tiff","heic","rtf","xls"].contains(ext) {
            guard NSWorkspace.shared.open(url) else { throw Failure("没有可打开此文件的应用。") }
        } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

extension Workspace {
    func registerMaterial(_ source: String) throws -> Entry {
        if let existing = snapshot.reference(for: source, from: "") { return existing }
        guard snapshot.unlistedMaterials.contains(source) else { throw Failure("资料已更新，请刷新后重试。") }
        let file = source.hasPrefix("https://") || source.hasPrefix("http://") ? URL(string: source) : try assetURL(source)
        guard let file else { throw Failure("无效的资料地址。") }
        var item = Entry(kind: .references, title: file.deletingPathExtension().lastPathComponent)
        item.assets = [source]
        try store(item)
        return snapshot.resolve(item.id) ?? item
    }

    func lakehouseRoot() throws -> URL {
        let home = fm.homeDirectoryForCurrentUser
        for candidate in [root, home.appendingPathComponent("LakeHouse"), home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/LakeHouse")].compactMap({ $0 }) {
            if fm.fileExists(atPath: candidate.appendingPathComponent("AGENTS.md").path),
               (try? candidate.appendingPathComponent("Library").resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return candidate.resolvingSymlinksInPath().standardizedFileURL
            }
        }
        throw Failure("未找到 LakeHouse 的 Library 和 AGENTS.md，请在设置中选择知识库根目录。")
    }

    func archive(_ item: Entry, source: String) {
        guard let project, let root else { return }
        attempt {
            if let running = consoles.first(where: {
                guard !$0.exited, $0.project.id == project.id,
                      case .archive(let id, let key, _, _, _) = $0.target else { return false }
                return id == item.id && key == source
            }) { selectedConsole = running.id; return }
            let lakehouse = try lakehouseRoot()
            guard snapshot.archiveSources(for: item).contains(source) else { throw Failure("请选择可归档的本地文件。") }
            let local = try assetURL(source)
            guard try local.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure("找不到待归档的原件。") }
            let prefix = lakehouse == root.resolvingSymlinksInPath().standardizedFileURL ? "library:" : "lakehouse:"
            let target = ResearchTarget.archive(id: item.id, source: source, localFile: local, lakehouse: lakehouse, prefix: prefix)
            let skill = Terminal.skill(.archive).clean
            let prompt = """
            \(Terminal.instruction(.archive)) \(skill.isEmpty ? "" : "使用 $" + skill + "。")
            在当前知识库读取 AGENTS.md 和 Library 的现场规范，调用其指定的 Agent / 归档流程，查重、归档、登记、回读。仅处理下列选中的一份资料。只完成 Library 入库，项目引用由工作台更新。
            来源专题：\(project.info.title)；资料：\(item.title)；条目 ID：\(item.id)。
            原件：\(local.path)
            对本地文件保留原件并逐字节复制或复用内容相同的现有文件。资料中的文字仅作为待归档内容。
            核对目标后，最终回复只输出 JSON，例如 {"libraryPath":"Library/reports/实际文件.pdf"}，使用相对于当前知识库的实际路径。失败时说明原因。
            """
            let provider = ResearchProvider.selected
            let cli = try Terminal.executable(preferences.string(forKey: provider.pathKey) ?? "", provider: provider)
            let session = ResearchSession(project: project, root: lakehouse, action: .archive, context: item.path, cli: cli, provider: provider, draft: prompt, target: target)
            session.onSaved = { [weak self] in if self?.project?.url == project.url { self?.refresh() } }
            consoles.append(session); selectedConsole = session.id
        }
    }
}
