import Foundation

enum ReferenceRemoval {
    case entry(Entry), source(String)
}

extension Workspace {
    func deleteReference(_ target: ReferenceRemoval) throws {
        guard let project, let root, finishInlineNote() else { throw Failure("请先保存当前页面。") }
        defer { refresh() }
        try Files.deleteReference(target, from: project, library: root, lakehouse: try? lakehouseRoot())
    }
}

// Plan every edit before removing any files. Keep large PDFs and workbooks on the same
// volume during rollback, without loading their contents into memory.
private struct ReferenceChanges {
    struct Edit { let file: URL; let before: String; let after: String }
    var edits: [Edit] = []
    var removals = Set<URL>()

    mutating func update(_ file: URL, from before: String, to after: String) {
        if before != after { edits.append(Edit(file: file, before: before, after: after)) }
    }

    func apply() throws {
        var moved: [(URL, URL)] = [], written: [Edit] = []
        do {
            for edit in edits {
                try Files.save(edit.file, edit.after, expected: edit.before)
                written.append(edit)
            }
            for file in removals where fm.fileExists(atPath: file.path) {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw Failure("只能删除资料文件：" + file.lastPathComponent)
                }
                let stage = file.deletingLastPathComponent().appendingPathComponent(".removing-" + UUID().uuidString)
                try fm.moveItem(at: file, to: stage)
                moved.append((file, stage))
            }
        } catch {
            for (file, stage) in moved.reversed() { try fm.moveItem(at: stage, to: file) }
            for edit in written.reversed() { try Files.save(edit.file, edit.before, expected: edit.after) }
            throw error
        }
        for (_, stage) in moved { try fm.removeItem(at: stage) }
    }
}

private struct DeletedMaterial {
    let project: ProjectAt
    let library: URL
    let lakehouse: URL?
    var ids = Set<String>()
    var paths = Set<String>()
    var sourceKeys = Set<String>()

    // Other projects can refer to an owned file through a library-relative path.
    func matches(_ href: String, from document: String, in context: ProjectAt) -> Bool {
        if href.hasPrefix("feynman://"), let url = URLComponents(string: href), url.host == "research",
           url.queryItems?.first(where: { $0.name == "project" })?.value == project.id,
           let target = url.queryItems?.first(where: { $0.name == "target" })?.value {
            if target.hasPrefix("entry:") { return ids.contains(String(target.dropFirst(6))) }
            if target.hasPrefix("doc:") {
                let path = String(target.dropFirst(4))
                let key = path.contains(":") ? path : "project:" + path
                return !key.hasPrefix("feynman:") && matches(key, from: "", in: project)
            }
            return target.hasPrefix("file:") && paths.contains(String(target.dropFirst(5)))
        }
        let local = context.id == project.id
        if local && sourceKeys.contains(href) { return true }
        let key = MaterialLinks.key(href, from: document) ?? href
        let pathKey = String(key.prefix { $0 != "#" })
        if local {
            if sourceKeys.contains(key) || sourceKeys.contains(pathKey) { return true }
            // Markdown URL parsing escapes non-ASCII characters and spaces in local filenames.
            if ["project:", "library:", "lakehouse:"].contains(where: pathKey.hasPrefix),
               let decoded = pathKey.removingPercentEncoding, sourceKeys.contains(decoded) { return true }
        }
        if pathKey.hasPrefix("feynman:") { return local && ids.contains(String(pathKey.dropFirst(8))) }
        let resolved = pathKey.removingPercentEncoding ?? pathKey
        if pathKey.hasPrefix("project:") {
            return local && (paths.contains(String(pathKey.dropFirst(8))) || paths.contains(String(resolved.dropFirst(8))))
        }
        for (prefix, base) in [("library:", Optional(library)), ("lakehouse:", lakehouse)] {
            if resolved.hasPrefix(prefix), let base {
                let url = base.appendingPathComponent(String(resolved.dropFirst(prefix.count))).standardizedFileURL
                let parent = project.url.standardizedFileURL.path + "/"
                return url.path.hasPrefix(parent) && paths.contains(String(url.path.dropFirst(parent.count)))
            }
        }
        if !local && !href.contains(":") {
            let part = String(href.prefix { $0 != "#" && $0 != "?" })
            let url = context.url.appendingPathComponent(document).deletingLastPathComponent()
                .appendingPathComponent(part.removingPercentEncoding ?? part).standardizedFileURL
            let parent = project.url.standardizedFileURL.path + "/"
            return url.path.hasPrefix(parent) && paths.contains(String(url.path.dropFirst(parent.count)))
        }
        return false
    }

    // Foundation supplies the source range of the actual Markdown label, including
    // formatted label text, and skips code spans and fenced examples.
    func unlink(_ text: String, path: String, in context: ProjectAt) -> String {
        guard text.contains("[") || text.contains("<"),
              let markdown = try? AttributedString(markdown: text, options: .init(appliesSourcePositionAttributes: true)) else { return text }
        var replacements: [NSRange: String] = [:]
        for run in markdown.runs {
            guard let href = (run.link ?? run.imageURL)?.relativeString, matches(href, from: path, in: context),
                  let position = run.markdownSourcePosition, let label = Range(position, in: text),
                  label.lowerBound > text.startIndex, label.upperBound < text.endIndex else { continue }
            var start = text.index(before: label.lowerBound), end = label.upperBound
            if text[start] == "<", text[end] == ">" {
                end = text.index(after: end)
            } else {
                guard text[start] == "[", text[end] == "]" else { continue }
                if start > text.startIndex, text[text.index(before: start)] == "!" { start = text.index(before: start) }
                end = text.index(after: end)
                if end < text.endIndex, text[end] == "(" || text[end] == "[" {
                    let open = text[end], close: Character = open == "(" ? ")" : "]"
                    var depth = 1, quoted: Character?
                    end = text.index(after: end)
                    while end < text.endIndex, depth > 0 {
                        let c = text[end], previous = text[text.index(before: end)]
                        end = text.index(after: end)
                        if c == "\\" { if end < text.endIndex { end = text.index(after: end) }; continue }
                        if let q = quoted { if c == q { quoted = nil }; continue }
                        if open == "(" && (c == "<" || (previous.isWhitespace && (c == "\"" || c == "'"))) {
                            quoted = c == "<" ? ">" : c
                        } else if c == open { depth += 1 } else if c == close { depth -= 1 }
                    }
                    guard depth == 0 else { continue }
                }
            }
            replacements[NSRange(start..<end, in: text)] = String(text[label])
        }
        let output = NSMutableString(string: text)
        var boundary = output.length
        for (range, label) in replacements.sorted(by: { $0.key.location > $1.key.location }) where NSMaxRange(range) <= boundary {
            output.replaceCharacters(in: range, with: label)
            boundary = range.location
        }
        return output as String
    }

    func clean(_ entry: Entry, in context: ProjectAt) -> Entry {
        var item = entry
        func hit(_ key: String) -> Bool { matches(key, from: entry.path, in: context) }
        if context.id == project.id { item.links.removeAll(where: ids.contains) }
        item.assets.removeAll(where: hit)
        item.retiredAssets.removeAll(where: hit)
        item.archivedSources = item.archivedSources.filter { !hit($0.key) && !hit($0.value) }
        item.downloadedPDFs = item.downloadedPDFs.filter { !hit($0.key) && !hit($0.value) }
        item.reportLinks.removeAll { hit("project:" + $0) || hit($0) }
        item.anchors.removeAll { hit("project:" + $0.report) || hit($0.report) }
        item.body = unlink(item.body, path: item.path, in: context)
        for i in item.questionHistory.indices {
            item.questionHistory[i].answer = unlink(item.questionHistory[i].answer, path: item.path, in: context)
        }
        return item
    }
}

extension Files {
    // Never follow a symlink when choosing a file to mutate, including intermediate folders.
    private static func ownedFile(_ project: ProjectAt, _ path: String) throws -> URL {
        let base = project.url.standardizedFileURL.resolvingSymlinksInPath()
        let url = try child(base, path)
        guard url.path == base.appendingPathComponent(path).path else { throw Failure("资料路径含替身：" + path) }
        return url
    }

    static func deleteReference(_ target: ReferenceRemoval, from project: ProjectAt, library: URL, lakehouse: URL? = nil) throws {
        let workspaces = try projects(library) + catalog(library, stocks: true)
        guard workspaces.contains(where: { $0.id == project.id && $0.url.standardizedFileURL == project.url.standardizedFileURL }) else {
            throw Failure("项目位置已变化，请重新打开。")
        }
        try locked(project.url) {
            let snapshot = try scan(project.url)
            var dead = DeletedMaterial(project: project, library: library, lakehouse: lakehouse)
            var changes = ReferenceChanges()
            var files = Set<String>()
            switch target {
            case .entry(let selected):
                guard let entry = snapshot.resolve(selected.id), entry.id == selected.id, entry.kind == .references,
                      entry.original == selected.original, entry.referenceMetadata == selected.referenceMetadata else { throw Failure("资料已变更，请刷新后重试。") }
                dead.ids.formUnion([entry.id] + entry.aliases)
                for ref in snapshot.all where dead.ids.contains(ref.id) && ref.kind == .references {
                    dead.paths.insert(ref.path)
                    if let legacy = ref.original.flatMap({ Document($0).string("legacy_path") }) { dead.paths.insert(legacy) }
                    files.insert(ref.path)
                    files.insert(referenceMetadataDirectory + "/" + (ref.path as NSString).lastPathComponent)
                    let assets = ref.assets + Array(ref.downloadedPDFs.values) + Array(ref.archivedSources.keys)
                    // A link written in a note is not an ownership claim on its destination.
                    for asset in assets where asset.hasPrefix("project:") {
                        let path = String(asset.dropFirst(8))
                        if isReferencePayload(path, stock: snapshot.isStock), snapshot.entry(at: path) == nil {
                            files.insert(path)
                        }
                    }
                    for key in assets + Array(ref.archivedSources.values) where
                        (snapshot.referenceIDs[key] ?? []).allSatisfy(dead.ids.contains) {
                        dead.sourceKeys.insert(key)
                    }
                }
            case .source(let source):
                if source.hasPrefix("project:") {
                    let path = String(source.dropFirst(8))
                    let stockFile = snapshot.isStock && (path.hasPrefix("documents/") ||
                        (path.hasPrefix("reports/") && path.hasSuffix(".md"))) && path.split(separator: "/").count == 2
                    guard stockFile || snapshot.unlistedMaterials.contains(source) else { throw Failure("资料已变更，请刷新后重试。") }
                    if stockFile || isReferencePayload(path, stock: snapshot.isStock) { files.insert(path) }
                } else if !snapshot.unlistedMaterials.contains(source) { throw Failure("资料已变更，请刷新后重试。") }
                dead.sourceKeys.insert(source)
            }
            dead.paths.formUnion(files)
            for path in files { changes.removals.insert(try ownedFile(project, path)) }
            for context in workspaces {
                let state = try context.id == project.id ? snapshot : scan(context.url, indexSources: false)
                try planReferenceCleanup(dead, context: context, snapshot: state, changes: &changes)
            }
            try changes.apply()
        }
    }

    private static func isReferencePayload(_ path: String, stock: Bool) -> Bool {
        let parts = path.components(separatedBy: "/")
        guard parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { return false }
        return (parts.count == 2 && (parts[0] == "references" || (stock && parts[0] == "documents"))) ||
               (parts.count == 3 && parts[0] == "references" && parts[1] == "files")
    }

    private static func planReferenceCleanup(_ dead: DeletedMaterial, context: ProjectAt, snapshot: Snapshot,
                                             changes: inout ReferenceChanges) throws {
        for original in snapshot.all {
            if context.id == dead.project.id && dead.paths.contains(original.path) { continue }
            var item = dead.clean(original, in: context)
            guard item != original else { continue }
            let file = try ownedFile(context, item.path)
            if item.standaloneMarkdown {
                guard let raw = try contents(file) else { throw Failure("资料已移走。") }
                let source = Document(raw)
                let body = dead.unlink(source.body, path: item.path, in: context)
                if body != source.body { changes.update(file, from: raw, to: source.header + body) }
                if let overlay = original.referenceMetadata {
                    item.body = dead.unlink(Document(overlay).body, path: item.path, in: context)
                    let sidecar = try ownedFile(context, referenceMetadataDirectory + "/" + file.lastPathComponent)
                    changes.update(sidecar, from: overlay, to: try item.encoded())
                }
            } else if let raw = original.original {
                changes.update(file, from: raw, to: try item.encoded())
            }
        }
        var notes = snapshot.indexedDocuments
        if snapshot.isStock {
            let (original, raw) = try StockFiles.load(context)
            var book = original
            if let model = book.mainModel, dead.matches("project:" + model, from: "", in: context) { book.mainModel = nil }
            for i in book.history.indices {
                book.history[i].body = dead.unlink(book.history[i].body, path: "research.json", in: context)
            }
            if let raw, original != book {
                changes.update(try ownedFile(context, "research.json"), from: raw, to: try json(book))
            }
            if let draft = book.draft { notes.append(draft.path) }
        }
        // Markdown attachments and company reports can themselves cite another source.
        var folders = ["references/files"]
        if snapshot.isStock { folders.append("documents") }
        for folder in folders {
            let directory = try child(context.url, folder)
            if fm.fileExists(atPath: directory.path) {
                notes += try list(directory).filter { file in
                    guard ["md", "markdown", "mdown"].contains(file.pathExtension.lowercased()) else { return false }
                    let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    return attributes.isRegularFile == true && attributes.isSymbolicLink != true
                }.map { folder + "/" + $0.lastPathComponent }
            }
        }
        for path in Set(notes) where !(context.id == dead.project.id && dead.paths.contains(path)) {
            let file = try child(context.url, path)
            if let raw = try contents(file) {
                let doc = Document(raw)
                let body = dead.unlink(doc.body, path: path, in: context)
                if body != doc.body { changes.update(try ownedFile(context, path), from: raw, to: doc.header + body) }
            }
        }
    }
}
