import Foundation
import CryptoKit

let fm = FileManager.default
struct Failure: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
extension String {
    var clean: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
enum Kind: String, CaseIterable, Codable, Identifiable {
    case questions, concepts, entities, events, references
    var id: String { rawValue }
    var label: String {
        switch self { case .questions: return "关键问题"; case .concepts: return "概念"; case .entities: return "实体"; case .events: return "事件"; case .references: return "参考资料" }
    }
    var englishLabel: String {
        switch self {
        case .questions: return "Key Qs"
        case .concepts: return "Concepts"
        case .entities: return "Entities"
        case .events: return "Events"
        case .references: return "References"
        }
    }
    var symbol: String {
        switch self {
        case .questions: return "questionmark.bubble"
        case .concepts: return "lightbulb"
        case .entities: return "person.text.rectangle"
        case .events: return "calendar"
        case .references: return "doc.text"
        }
    }
}
struct Anchor: Codable, Hashable {
    var report: String
    var section = ""
    var quote: String
    var prefix = ""
    var suffix = ""
}
func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
func decode<T: Decodable>(_ type: T.Type, _ value: String?) -> T? {
    value.flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
}
struct Document {
    var fields: [String: String] = [:]
    var body: String
    var header = ""
    init(_ raw: String) {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        body = text
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else { return }
        header = String(text[..<end.upperBound])
        body = String(text[end.upperBound...])
        for line in header.split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { fields[String(pair[0]).clean] = String(pair[1]).clean }
        }
    }
    func string(_ key: String) -> String? { decode(String.self, fields[key]) ?? fields[key] }
    var heading: String? { body.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).clean } }
}

struct ResearchTurn: Codable, Hashable, Identifiable {
    var id = UUID().uuidString
    var date = ISO8601DateFormatter().string(from: Date())
    var question: String
    var answer: String
}

struct Entry: Identifiable, Hashable {
    var id: String
    var kind: Kind
    var title: String
    var body: String
    var origin: String
    var anchors: [Anchor] = []
    var links: [String] = []
    var assets: [String] = []
    var standaloneMarkdown = false
    var referenceMetadata: String?
    var reportLinks: [String] = []
    var archivedSources: [String: String] = [:]
    var downloadedPDFs: [String: String] = [:]
    var retiredAssets: [String] = []
    var aliases: [String] = []
    var deleted = false
    var answered = false
    var questionHistory: [ResearchTurn] = []
    var path: String
    var original: String?
    init(kind: Kind, title: String, body: String = "", origin: String = "手工添加", id: String = UUID().uuidString.lowercased()) {
        self.id = id; self.kind = kind; self.title = title; self.body = body; self.origin = origin
        path = "\(kind.rawValue)/\(id).md"
    }
    init(kind: Kind, path: String, raw: String) {
        let doc = Document(raw)
        let filename = (path as NSString).lastPathComponent
        let name = (filename as NSString).deletingPathExtension
        id = doc.string("id") ?? name
        self.kind = kind
        title = doc.string("title") ?? doc.heading ?? name
        body = doc.body
        origin = doc.string("origin") ?? "预研提取"
        anchors = decode([Anchor].self, doc.fields["anchors"]) ?? []
        if doc.fields["anchors"] == nil, let report = doc.string("report"), let quote = doc.string("quote") {
            anchors = [Anchor(report: report, section: doc.string("section") ?? "", quote: quote, prefix: doc.string("prefix") ?? "", suffix: doc.string("suffix") ?? "")]
        }
        links = decode([String].self, doc.fields["links"]) ?? []
        assets = decode([String].self, doc.fields["assets"]) ?? []
        standaloneMarkdown = kind == .references && (doc.string("standalone_markdown") == "true" ||
            ["id", "origin", "assets", "anchors", "links"].allSatisfy { doc.fields[$0] == nil })
        reportLinks = decode([String].self, doc.fields["report_links"]) ?? []
        retiredAssets = decode([String].self, doc.fields["retired_assets"]) ?? []
        downloadedPDFs = decode([String: String].self, doc.fields["downloaded_pdfs"]) ?? [:]
        archivedSources = decode([String: String].self, doc.fields["archived_sources"]) ?? [:]
        aliases = decode([String].self, doc.fields["aliases"]) ?? []
        deleted = doc.string("deleted") == "true"
        answered = doc.string("answered") == "true"
        questionHistory = decode([ResearchTurn].self, doc.fields["question_history"]) ?? []
        self.path = path; original = raw
    }
    func clearingLinks(to ids: Set<String>, paths: Set<String>) -> Entry {
        var item = self
        if deleted || ids.contains(id) {
            if kind == .references { item.retiredAssets = Array(Set(retiredAssets + assets.filter { $0.hasPrefix("project:") })).sorted() }
            item.links = []; item.assets = []; item.anchors = []; item.reportLinks = []
        } else {
            item.links.removeAll { ids.contains($0) }
            item.anchors.removeAll { paths.contains($0.report) }
            item.reportLinks.removeAll { paths.contains($0) }
            item.assets.removeAll { $0.hasPrefix("project:") && paths.contains(String($0.dropFirst(8))) }
        }
        return item
    }
    func encoded() throws -> String {
        var fields = original.map { Document($0).fields } ?? [:]
        fields["id"] = try json(id); fields["title"] = try json(title); fields["origin"] = try json(origin)
        fields["anchors"] = try json(anchors); fields["links"] = try json(links); fields["assets"] = try json(assets)
        if standaloneMarkdown { fields["standalone_markdown"] = "true" }
        if !reportLinks.isEmpty || fields["report_links"] != nil { fields["report_links"] = try json(reportLinks) }
        if !retiredAssets.isEmpty { fields["retired_assets"] = try json(retiredAssets) }
        if !downloadedPDFs.isEmpty { fields["downloaded_pdfs"] = try json(downloadedPDFs) }
        if !archivedSources.isEmpty || fields["archived_sources"] != nil { fields["archived_sources"] = try json(archivedSources) }
        if !questionHistory.isEmpty || fields["question_history"] != nil { fields["question_history"] = try json(questionHistory) }
        fields["aliases"] = try json(aliases); fields["deleted"] = String(deleted); fields["answered"] = String(answered)
        return "---\n" + fields.keys.sorted().map { "\($0): \(fields[$0]!)" }.joined(separator: "\n") + "\n---\n" + body
    }
}

struct Project: Codable, Identifiable, Hashable {
    var id = UUID().uuidString.lowercased()
    var title: String
    var intent: String
    var legacyDirectory: String?
}
struct ProjectAt: Identifiable, Hashable {
    var info: Project
    var url: URL
    var id: String { info.id }
}
struct Snapshot {
    var all: [Entry] = []
    var reports: [String] = []
    var documents: [String] = []
    var issues: [String] = []
    var completed = false
    var archivedDestinations: [String: String] = [:]
    var materialSources: [String: [String]] = [:]
    var referenceIDs: [String: [String]] = [:]
    var citations: [String: Set<String>] = [:]
    var unlistedMaterials: [String] = []
    var looseAssets: [String] = []
    var entries: [Entry] {
        let displaced = Set(all.flatMap(\.aliases))
        return all.filter { !$0.deleted && !displaced.contains($0.id) }
    }
    func related(to item: Entry) -> [Entry] {
        let outgoing = Set(item.links)
        let identifiers = Set([item.id] + item.aliases)
        return entries.filter { other in
            other.id != item.id && (
                outgoing.contains(other.id) ||
                !outgoing.isDisjoint(with: other.aliases) ||
                !identifiers.isDisjoint(with: other.links)
            )
        }
    }
    func owners(of anchors: [Anchor]) -> [Entry] {
        let selected = Set(anchors)
        return entries.filter { !selected.isDisjoint(with: $0.anchors) }
    }
    func questions(for owners: [Entry]) -> [Entry] {
        let direct = owners.filter { $0.kind == .questions }
        let linked = owners.filter { $0.kind != .questions }.flatMap { related(to: $0).filter { $0.kind == .questions } }
        var seen = Set<String>()
        return (direct + linked).filter { seen.insert($0.id).inserted }
    }
    func resolve(_ id: String) -> Entry? { entries.first { $0.id == id || $0.aliases.contains(id) } }
    var deletedIDs: Set<String> {
        let dead = all.filter(\.deleted).flatMap { [$0.id] + $0.aliases }
        return Set(dead).subtracting(entries.flatMap { [$0.id] + $0.aliases })
    }
    var deletedPaths: Set<String> {
        let dead = deletedIDs
        return Set(all.filter { dead.contains($0.id) }.flatMap { item in
            [item.path, item.original.flatMap { Document($0).string("legacy_path") }].compactMap { $0 }
        })
    }
    var needsLinkCleanup: Bool {
        let dead = deletedIDs, paths = deletedPaths
        guard !dead.isEmpty else { return false }
        return all.contains { $0.clearingLinks(to: dead, paths: paths) != $0 }
    }
}

enum ReferenceFileMode {
    case copy
    case library(directory: URL, prefix: String)
}

enum Files {
    static func child(_ root: URL, _ path: String) throws -> URL {
        let parts = path.components(separatedBy: "/")
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }) else { throw Failure("文件路径无效。") }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var url = base
        for part in parts {
            url = url.appendingPathComponent(part)
            if let link = try? fm.destinationOfSymbolicLink(atPath: url.path) {
                let target = URL(fileURLWithPath: link, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
                guard fm.fileExists(atPath: target.path) else { throw Failure("资料链接失效。") }
                url = target.resolvingSymlinksInPath()
            }
            guard url.path.hasPrefix(base.path + "/") else { throw Failure("链接指向所选目录之外。") }
        }
        return url
    }
    static func contents(_ url: URL) throws -> String? {
        do { return try String(contentsOf: url, encoding: .utf8) }
        catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError { return nil }
    }
    static func save(_ url: URL, _ value: String, expected: String?) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                guard try contents(target) == expected else { throw Failure("文件刚刚在其他位置修改。你的草稿仍在编辑框中，请对照最新文件后保存。") }
                if expected == nil { try Data(value.utf8).write(to: target, options: .withoutOverwriting) }
                else { try Data(value.utf8).write(to: target, options: .atomic) }
            } catch { failure = error }
        }
        if let err = failure ?? coordinationError { throw err }
    }
    static func list(_ root: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    static func projects(_ root: URL) throws -> [ProjectAt] {
        let base = try child(root, "Feynman")
        guard fm.fileExists(atPath: base.path) else { return [] }
        return try list(base).compactMap { folder in
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return nil }
            let file = try child(base, folder.lastPathComponent + "/project.json")
            guard let raw = try contents(file) else { return nil }
            guard let project = decode(Project.self, raw) else { throw Failure("\(folder.lastPathComponent) 的 project.json 无法读取。") }
            return ProjectAt(info: project, url: folder)
        }
    }
    static func create(_ root: URL, title: String, intent: String, legacy: URL? = nil) throws -> ProjectAt {
        guard !title.clean.isEmpty, !title.contains("/"), !title.hasPrefix("."), title.utf8.count < 180 else { throw Failure("请输入有效的项目名称（不可包含斜线）。") }
        let base = try child(root, "Feynman")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = try child(base, title.clean)
        guard !fm.fileExists(atPath: destination.path) else { throw Failure("已存在同名项目。") }
        let stage = base.appendingPathComponent(".new-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { if fm.fileExists(atPath: stage.path) { try? fm.removeItem(at: stage) } }
        var project = Project(title: title.clean, intent: intent.clean)
        if let legacy {
            let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            let path = legacy.standardizedFileURL.resolvingSymlinksInPath().path
            if path.hasPrefix(prefix) { project.legacyDirectory = String(path.dropFirst(prefix.count)) }
        }
        for dir in Kind.allCases.map(\.rawValue) + ["reports", "references/files"] {
            try fm.createDirectory(at: try child(stage, dir), withIntermediateDirectories: true)
        }
        if let legacy { try importLegacy(legacy, into: stage) }
        for (name, value) in [("project.json", try json(project)), ("memo.md", ""), ("log.md", ""), ("README.md", "# " + project.title + "\n\n" + project.intent)] {
            let url = try child(stage, name)
            if !fm.fileExists(atPath: url.path) { try Data(value.utf8).write(to: url, options: .withoutOverwriting) }
        }
        try fm.moveItem(at: stage, to: destination)
        return ProjectAt(info: project, url: destination)
    }
    static func importLegacy(_ source: URL, into stage: URL) throws {
        guard let questions = try contents(child(source, "questions.md")) else { throw Failure("请选择含 questions.md 的 Market Cockpit 专题目录。") }
        for file in ["README.md","questions.md","companies.md","challenge.md","log.md","memo.md"] {
            let src = try child(source, file)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: child(stage, file)) }
        }
        let reports = try child(source, "reports")
        if fm.fileExists(atPath: reports.path) {
            for file in try list(reports) where file.pathExtension.lowercased() == "md" {
                let path = "reports/" + file.lastPathComponent
                try fm.copyItem(at: child(source, path), to: child(stage, path))
            }
        }
        try importSelections(from: source, into: stage)
        let text = Document(questions).body as NSString
        let headings = try NSRegularExpression(pattern: #"(?m)^##\s+(Q[0-9]+[^\n]*)$"#).matches(in: text as String, range: NSRange(location: 0, length: text.length))
        for (i, match) in headings.enumerated() {
            let heading = text.substring(with: match.range(at: 1))
            let end = i + 1 < headings.count ? headings[i+1].range.location : text.length
            let start = NSMaxRange(match.range)
            var e = Entry(kind: .questions, title: heading, body: text.substring(with: NSRange(location: start, length: end-start)).clean, origin: "旧版导入")
            e.anchors = [Anchor(report: "questions.md", section: heading, quote: heading)]
            try write(e, in: stage)
        }
    }
    // A loose Markdown reference is itself the source. Keep its project metadata in a sibling directory.
    static let referenceMetadataDirectory = "references/.metadata"

    private static func metadataURL(_ entry: Entry, in root: URL) throws -> URL {
        try child(root, referenceMetadataDirectory + "/" + (entry.path as NSString).lastPathComponent)
    }

    @discardableResult private static func persist(_ entry: Entry, in root: URL) throws -> String {
        let encoded = try entry.encoded()
        if entry.standaloneMarkdown {
            let destination = try metadataURL(entry, in: root)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let raw = try contents(child(root, entry.path)) else { throw Failure("引用文件已移走。") }
            let originalBody = Document(raw).body
            guard entry.body.hasPrefix(originalBody) else { throw Failure("引用文件已有变化，请刷新后重试。") }
            let extra = entry.body.dropFirst(originalBody.count)
            try save(destination, Document(encoded).header + extra, expected: entry.referenceMetadata)
        } else {
            try save(child(root, entry.path), encoded, expected: entry.original)
        }
        return encoded
    }
    @discardableResult static func write(_ entry: Entry, in root: URL) throws -> String {
        var written = ""
        try locked(root) {
            let snapshot = try scan(root)
            if entry.original != nil {
                let live = snapshot.resolve(entry.id)
                guard live?.id == entry.id else { throw Failure("条目已合并或删除，请重新选择当前条目。") }
            } else if snapshot.all.contains(where: { $0.id == entry.id || $0.aliases.contains(entry.id) }) {
                throw Failure("条目编号已使用，请重新创建条目。")
            }
            let item = entry.clearingLinks(to: snapshot.deletedIDs, paths: snapshot.deletedPaths)
            written = try persist(item, in: root)
            if item.deleted { try pruneLinks(in: root, snapshot: scan(root)) }
        }
        return written
    }
    private static func pruneLinks(in root: URL, snapshot: Snapshot) throws {
        let dead = snapshot.deletedIDs
        let paths = snapshot.deletedPaths
        for original in snapshot.all {
            let item = original.clearingLinks(to: dead, paths: paths)
            guard item != original else { continue }
            try persist(item, in: root)
        }
    }
    static func resumeLinkCleanup(in root: URL) throws {
        try locked(root) { try pruneLinks(in: root, snapshot: scan(root)) }
    }
    static func setRelation(from sourceID: String, to targetID: String, present: Bool, in root: URL) throws {
        try locked(root) {
            let snapshot = try scan(root)
            guard var source = snapshot.resolve(sourceID), let target = snapshot.resolve(targetID),
                  source.id != target.id else { throw Failure("条目已合并或删除，请重新选择。") }
            if present {
                guard !snapshot.related(to: source).contains(where: { $0.id == target.id }) else { return }
                source.links.append(target.id)
                try persist(source, in: root)
            } else {
                // Older projects can store the same edge on either or both endpoints, using aliases.
                for (var owner, neighbor) in [(source, target), (target, source)] {
                    let ids = Set([neighbor.id] + neighbor.aliases)
                    guard !ids.isDisjoint(with: owner.links) else { continue }
                    owner.links.removeAll { ids.contains($0) }
                    try persist(owner, in: root)
                }
            }
        }
    }
    static func scan(_ root: URL) throws -> Snapshot {
        var result = Snapshot()
        for k in Kind.allCases {
            let dir = try child(root, k.rawValue)
            guard fm.fileExists(atPath: dir.path) else { continue }
            for f in try list(dir) where f.pathExtension.lowercased() == "md" {
                let path = k.rawValue + "/" + f.lastPathComponent
                do {
                    if let data = try contents(child(root, path)) {
                        var entry = Entry(kind: k, path: path, raw: data)
                        if entry.standaloneMarkdown, let metadata = try contents(metadataURL(entry, in: root)) {
                            let overlay = Document(metadata)
                            entry = Entry(kind: k, path: path, raw: overlay.header + entry.body + overlay.body)
                            entry.referenceMetadata = metadata
                        }
                        if result.all.contains(where: { $0.id == entry.id }) { result.issues.append("编号重复：" + path) }
                        else { result.all.append(entry) }
                    }
                } catch { result.issues.append(path + "：" + error.localizedDescription) }
            }
        }
        result.reports = try list(child(root, "reports")).filter { $0.pathExtension.lowercased() == "md" }.map { "reports/" + $0.lastPathComponent }
        result.documents = ["README.md","questions.md","companies.md","challenge.md"].filter { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        let registered = Set(result.all.flatMap { $0.assets + $0.retiredAssets + Array($0.archivedSources.keys) })
        for folder in ["references", "references/files"] {
            let dir = try child(root, folder)
            guard fm.fileExists(atPath: dir.path) else { continue }
            for item in try list(dir) {
                if folder == "references" && item.pathExtension.lowercased() == "md" { continue }
                let relative = folder + "/" + item.lastPathComponent
                let url = try child(root, relative)
                if (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true, !registered.contains("project:" + relative) { result.looseAssets.append(relative) }
            }
        }
        try result.indexMaterials(in: root)
        result.completed = fm.fileExists(atPath: try child(root, "preflight.done").path) && !result.reports.isEmpty
        return result
    }
    private static func locked(_ root: URL, _ body: () throws -> Void) throws {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw Failure("项目目录无法读取。") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Failure("项目正在被修改，请稍后重试。") }
        defer { flock(fd, LOCK_UN) }
        try body()
    }
    static func merge(_ source: Entry, into target: Entry, at root: URL) throws {
        guard source.kind == target.kind, source.id != target.id else { throw Failure("请选择同类的其他条目。") }
        try locked(root) {
            let snapshot = try scan(root)
            guard snapshot.resolve(source.id)?.id == source.id,
                  snapshot.resolve(target.id)?.id == target.id,
                  snapshot.resolve(source.id)?.original == source.original else { throw Failure("条目已更新、合并或删除，请重新选择。") }
            try saveMerged(source, into: target, at: root)
        }
    }
    private static func saveMerged(_ source: Entry, into target: Entry, at root: URL) throws {
        var e = target
        e.aliases += ([source.id] + source.aliases).filter { !e.aliases.contains($0) }
        e.anchors += source.anchors.filter { !e.anchors.contains($0) }
        e.links += source.links.filter { !e.links.contains($0) }
        e.assets += source.assets.filter { !e.assets.contains($0) }
        e.reportLinks += source.reportLinks.filter { !e.reportLinks.contains($0) }
        e.downloadedPDFs.merge(source.downloadedPDFs) { current, _ in current }
        e.archivedSources.merge(source.archivedSources) { current, _ in current }
        e.questionHistory += source.questionHistory.filter { turn in !e.questionHistory.contains { $0.id == turn.id } }
        e.questionHistory.sort { $0.date < $1.date }
        if source.standaloneMarkdown, !e.assets.contains("project:" + source.path) { e.assets.append("project:" + source.path) }
        if !source.body.clean.isEmpty { e.body += "\n\n## " + source.title + "\n\n" + source.body }
        try persist(e, in: root)
    }
}

extension Snapshot {
    func entry(at path: String) -> Entry? {
        if let current = all.first(where: { $0.path == path }) { return resolve(current.id) }
        guard path.hasPrefix("annotations/") else { return nil }
        let old = all.first { entry in
            entry.original.map { Document($0).string("legacy_path") == path } ?? false
        }
        return old.flatMap { resolve($0.id) }
    }
}

extension Files {
    /// Both a fresh import and an existing workspace use the same conversion.
    private static func importSelections(from source: URL, into root: URL) throws {
        let directory = try child(source, "annotations")
        guard fm.fileExists(atPath: directory.path) else { return }
        var existing = try scan(root).all
        for file in try list(directory) where file.pathExtension.lowercased() == "md" {
            let oldPath = "annotations/" + file.lastPathComponent
            guard let raw = try contents(child(source, oldPath)) else { throw Failure("旧条目正在同步：" + oldPath) }
            let doc = Document(raw)
            let kind = Kind(rawValue: doc.string("kind") ?? "") ?? .questions
            let path = kind.rawValue + "/" + file.lastPathComponent
            var entry = Entry(kind: kind, path: path, raw: raw)
            let checksum = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
            if let found = existing.first(where: { $0.id == entry.id || $0.path == path }) {
                let metadata = Document(found.original ?? "")
                guard metadata.string("legacy_sha256") == checksum, metadata.string("legacy_path") == oldPath else {
                    throw Failure("旧文件与现有条目有冲突：" + oldPath + "。两份内容均已保留。")
                }
                continue
            }
            entry.origin = "报告划选"
            if doc.string("status") == "resolved" || doc.string("kind") == "answer" { entry.answered = true }

            // Only unfold the old website's known wrapper. Native Markdown bodies stay intact.
            if doc.string("quote") != nil, doc.body.contains("\n## 标注\n"),
               let marker = doc.body.range(of: #"(?m)^备注[：:]"#, options: .regularExpression) {
                let rest = String(doc.body[marker.upperBound...])
                let personal = ["answer","note"].contains(doc.string("kind"))
                let boundary = personal ? nil : rest.range(of: #"(?m)^##[ \t]+解答[ \t]*$"#, options: .regularExpression)
                let note = String(rest[..<(boundary?.lowerBound ?? rest.endIndex)]).clean
                let answer = boundary.map { String(rest[$0.upperBound...]).clean } ?? ""
                if doc.string("title") == nil {
                    if doc.string("kind") == "answer", let section = doc.string("section"), !section.isEmpty { entry.title = section }
                    else { entry.title = note.components(separatedBy: .newlines).first(where: { !$0.clean.isEmpty }) ?? entry.anchors.first?.quote ?? entry.title }
                }
                entry.body = note
                if !answer.isEmpty { entry.body += "\n\n## 解答\n\n" + answer }
            }
            let output = try entry.encoded()
            let sourceFields = try "legacy_path: " + json(oldPath) + "\nlegacy_sha256: " + json(checksum)
            let content = "---\n" + sourceFields + "\n" + output.dropFirst(4)
            try save(child(root, path), content, expected: nil)
            existing.append(Entry(kind: kind, path: path, raw: content))
        }
    }

    static func upgradeLegacySelections(in root: URL) throws {
        let legacy = root.appendingPathComponent("annotations", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else { return }
        try locked(root) {
            guard fm.fileExists(atPath: legacy.path) else { return }
            guard try legacy.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw Failure("旧条目目录是替身，未移动。")
            }
            var coordinationError: NSError?
            var failure: Error?
            NSFileCoordinator().coordinate(writingItemAt: legacy, options: .forMoving, error: &coordinationError) { location in
                do {
                    try importSelections(from: root, into: root)
                    let backup = root.appendingPathComponent(".legacy-selections-" + UUID().uuidString)
                    try fm.moveItem(at: location, to: backup)
                } catch { failure = error }
            }
            if let error = failure ?? coordinationError { throw error }
        }
    }
}

enum MaterialLinks {
    static func isWeb(_ source: String) -> Bool {
        guard let scheme = URL(string: source)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
    // Resolve project-relative Markdown against its owning document, including encoded filenames.
    static func key(_ href: String, from path: String) -> String? {
        if href.hasPrefix("#") || href.isEmpty { return nil }
        if href.hasPrefix("project:") || href.hasPrefix("library:") || href.hasPrefix("lakehouse:") || href.hasPrefix("feynman:") { return href }
        if let url = URL(string: href), let scheme = url.scheme {
            return ["http", "https"].contains(scheme.lowercased()) ? url.absoluteString : nil
        }
        let part = String(href.prefix { $0 != "#" && $0 != "?" })
        guard !part.isEmpty else { return nil }
        let base = URL(fileURLWithPath: "/project").appendingPathComponent(path).deletingLastPathComponent()
        let target = base.appendingPathComponent(part.removingPercentEncoding ?? part).standardizedFileURL.path
        if target.hasPrefix("/project/") { return "project:" + String(target.dropFirst(9)) }
        // Imported reports may retain an older directory depth for the same Library or Sources file.
        let tail = (part.removingPercentEncoding ?? part).split(separator: "/").drop { $0 == ".." || $0 == "." }
        if tail.first == "Sources" || tail.first == "Library" { return "library:" + tail.joined(separator: "/") }
        return nil
    }

    static func links(in body: String, from path: String) -> [String] {
        guard body.contains("[") || body.contains("<") || body.contains("://") else { return [] }
        let markdown = try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        var found = (markdown?.runs.compactMap { $0.link?.relativeString } ?? []).compactMap { key($0, from: path) }
        // Pasted URLs without Markdown link syntax are also usable material.
        if let detector = detector {
            for match in detector.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let range = Range(match.range, in: body),
                      !body[..<range.lowerBound].hasSuffix("(<"), !body[..<range.lowerBound].hasSuffix("]("),
                      let url = match.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { continue }
                found.append(url.absoluteString)
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}

extension Snapshot {
    mutating func indexMaterials(in root: URL) throws {
        let active = entries
        let removedFiles = Set(deletedPaths.map { "project:" + $0 })
        let refs = active.filter { $0.kind == .references }
        var linksByPath: [String: [String]] = [:]
        for e in active { linksByPath[e.path] = MaterialLinks.links(in: e.body, from: e.path) + e.assets }
        for r in refs {
            var seen = Set<String>()
            let candidates = r.standaloneMarkdown ? r.assets + ["project:" + r.path] : r.assets + (linksByPath[r.path] ?? [])
            let sources = candidates.filter {
                !$0.hasPrefix("feynman:") && !removedFiles.contains($0) && seen.insert($0).inserted
            }
            materialSources[r.id] = sources
            for key in Set(sources + Array(r.archivedSources.keys) + ["project:" + r.path] + ([r.id] + r.aliases).map { "feynman:" + $0 }) {
                referenceIDs[key, default: []].append(r.id)
            }
        }
        for path in reports + documents + ["memo.md", "log.md"] {
            do { if let raw = try Files.contents(Files.child(root, path)) { linksByPath[path] = MaterialLinks.links(in: Document(raw).body, from: path) } }
            catch { issues.append(path + "：" + error.localizedDescription) }
        }
        for (path, keys) in linksByPath {
            for key in keys {
                for id in referenceIDs[key] ?? [] { citations[id, default: []].insert(path) }
            }
        }
        for ref in refs { archivedDestinations.merge(ref.archivedSources) { first, _ in first } }
        let registered = Set(referenceIDs.keys)
        unlistedMaterials = Set(active.flatMap(\.assets) + looseAssets.map { "project:" + $0 }).subtracting(registered).sorted()
    }

    func sources(for entry: Entry) -> [String] {
        var seen = Set<String>()
        return (materialSources[entry.id] ?? []).map { archivedDestinations[$0] ?? $0 }.filter { seen.insert($0).inserted }
    }

    func isWebReference(_ entry: Entry) -> Bool {
        let sources = sources(for: entry)
        return entry.kind == .references && !sources.isEmpty && sources.allSatisfy(MaterialLinks.isWeb)
    }

    func archiveSources(for entry: Entry) -> [String] {
        let sources = sources(for: entry)
        let candidates = sources.isEmpty ? ["project:" + entry.path] : sources
        return candidates.filter { !MaterialLinks.isWeb($0) && !$0.hasPrefix("library:Library/") && !$0.hasPrefix("lakehouse:Library/") }
    }

    func reference(for key: String, from path: String) -> Entry? {
        let matches = (referenceIDs[key] ?? []).compactMap { resolve($0) }
        return matches.first { $0.anchors.contains { $0.report == path } || $0.reportLinks.contains(path) } ?? matches.first
    }
}

extension Snapshot {
    func updatingArchivedAssets(_ item: Entry) -> Entry {
        guard item.assets.contains(where: { archivedDestinations[$0] != nil }) else { return item }
        var updated = item
        var seen = Set<String>()
        updated.assets = item.assets.map { archivedDestinations[$0] ?? $0 }.filter { seen.insert($0).inserted }
        return updated
    }
    var needsArchiveUpdate: Bool {
        !archivedDestinations.isEmpty && entries.contains { updatingArchivedAssets($0) != $0 }
    }
}

extension Files {
    static func updateArchivedAssets(in root: URL) throws {
        try locked(root) {
            let snapshot = try scan(root)
            for item in snapshot.entries {
                let updated = snapshot.updatingArchivedAssets(item)
                if updated != item { try persist(updated, in: root) }
            }
        }
    }
}

extension Files {
    static func registerWebLink(_ url: URL, title: String, in root: URL) throws -> String {
        let source = url.absoluteString
        var item = Entry(kind: .references, title: title)
        item.assets = [source]
        try locked(root) {
            let snapshot = try scan(root)
            if let existing = (snapshot.referenceIDs[source] ?? []).compactMap(snapshot.resolve).first(where: snapshot.isWebReference) {
                item = existing
                if item.title != source || title == source { return }
                item.title = title
            }
            try persist(item, in: root)
        }
        return item.id
    }

    static func cachedPDF(_ source: String, in root: URL, snapshot: Snapshot) -> Entry? {
        for id in snapshot.referenceIDs[source] ?? [] {
            guard let item = snapshot.resolve(id), let asset = item.downloadedPDFs[source] else { continue }
            if snapshot.archivedDestinations[asset] != nil { return item }
            if asset.hasPrefix("project:"), let file = try? child(root, String(asset.dropFirst(8))),
               fm.fileExists(atPath: file.path) { return item }
        }
        return nil
    }

    static func registerPDF(_ file: URL, name: String, source: URL, title: String?, in root: URL) throws -> String {
        let original = source.absoluteString
        var id = ""
        try locked(root) {
            let snapshot = try scan(root)
            if let cached = cachedPDF(original, in: root, snapshot: snapshot) { id = cached.id; return }
            let matches = (snapshot.referenceIDs[original] ?? []).compactMap(snapshot.resolve)
            let prior = matches.first { $0.downloadedPDFs[original] != nil } ?? matches.first(where: snapshot.isWebReference)
            var item = prior ?? Entry(kind: .references, title: name)
            if prior == nil || item.title == original { item.title = title ?? name }
            let oldAsset = item.downloadedPDFs[original]
            let asset = oldAsset ?? "project:references/files/" + UUID().uuidString + "-" + name
            guard asset.hasPrefix("project:references/files/") else { throw Failure("PDF 附件路径无效。") }
            let destination = try child(root, String(asset.dropFirst(8)))
            try withAttachmentCopy(file, to: destination) {
                if !item.assets.contains(asset) { item.assets.insert(asset, at: 0) }
                if !item.assets.contains(original) { item.assets.append(original) }
                item.downloadedPDFs[original] = asset
                try persist(item, in: root)
            }
            id = item.id
        }
        return id
    }

    static func registerFile(_ source: URL, mode: ReferenceFileMode, ownerID: String?, in root: URL) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let file = source.resolvingSymlinksInPath().standardizedFileURL
        guard source.isFileURL, try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw Failure("请选择一个可读取的文件。")
        }
        var item = Entry(kind: .references, title: source.lastPathComponent)
        try locked(root) {
            let snapshot = try scan(root)
            let owner = ownerID.flatMap(snapshot.resolve)
            guard ownerID == nil || owner != nil else { throw Failure("要关联的条目已删除。") }

            let asset: String
            let existing: Entry?
            switch mode {
            case .library(let directory, let prefix):
                let base = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                guard file.path.hasPrefix(base) else { throw Failure("请选择知识库内的文件，或使用「添加参考资料」导入本地文件。") }
                asset = prefix + String(file.path.dropFirst(base.count))
                existing = snapshot.reference(for: asset, from: owner?.path ?? "")
            case .copy:
                // Reuse the registered project copy when linking the same file from another entry.
                existing = owner == nil ? nil : snapshot.entries.first { ref in
                    ref.kind == .references && ref.assets.contains { key in
                        guard key.hasPrefix("project:references/files/"),
                              let copy = try? child(root, String(key.dropFirst(8))) else { return false }
                        return file.path == copy.path || (materialLabel(key) == source.lastPathComponent &&
                            fm.contentsEqual(atPath: file.path, andPath: copy.path))
                    }
                }
                asset = "project:references/files/" + UUID().uuidString + "-" + source.lastPathComponent
            }
            if let existing {
                item = existing
                if var owner, owner.id != item.id, !snapshot.related(to: owner).contains(where: { $0.id == item.id }) {
                    owner.links.append(item.id)
                    try persist(owner, in: root)
                }
                return
            }
            item.assets = [asset]
            if let owner { item.links = [owner.id] }
            let saveReference = { try save(child(root, item.path), item.encoded(), expected: nil) }
            if case .copy = mode {
                let destination = try child(root, String(asset.dropFirst(8)))
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try withAttachmentCopy(file, to: destination, register: saveReference)
            } else { try saveReference() }
        }
        return item.id
    }

    private static func withAttachmentCopy(_ source: URL, to destination: URL, register: () throws -> Void) throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source.resolvingSymlinksInPath(), to: staging)
        try fm.moveItem(at: staging, to: destination)
        do { try register() }
        catch { try? fm.removeItem(at: destination); throw error }
    }
}

func materialLabel(_ source: String) -> String {
    if let url = URL(string: source), ["https","http"].contains(url.scheme), let host = url.host {
        return host + (url.lastPathComponent.isEmpty ? "" : " / " + url.lastPathComponent)
    }
    let name = (source as NSString).lastPathComponent
    if source.hasPrefix("project:references/files/"), name.count > 37,
       UUID(uuidString: String(name.prefix(36))) != nil, name.dropFirst(36).first == "-" {
        return String(name.dropFirst(37))
    }
    return name
}
