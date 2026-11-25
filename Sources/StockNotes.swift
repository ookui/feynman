import Foundation

/// On-disk layout used before the business chapter became a single note.
struct BusinessSegment {
    let directory: String
    let title: String
    var business: String { directory + "/business.md" }
    var competition: String { directory + "/competition.md" }
}

enum StockNotes {
    static let segmentDirectory = "analysis/segments"
    private static let importedNotesKey = "feynman_imported_segment_notes"

    static func segments(in company: ProjectAt) throws -> [BusinessSegment] {
        let parent = try Files.child(company.url, segmentDirectory)
        guard fm.fileExists(atPath: parent.path) else { return [] }
        var ranks: [UUID: Int] = [:]
        if let raw = try Files.contents(Files.child(parent, "order.json")) {
            guard let ids = decode([UUID].self, raw) else { throw Failure("无法读取原业务板块顺序。") }
            for (index, id) in ids.enumerated() where ranks[id] == nil { ranks[id] = index }
        }
        return try Files.list(parent).compactMap { folder -> (BusinessSegment, Int)? in
            let name = folder.lastPathComponent
            guard let id = UUID(uuidString: name),
                  let rawTitle = try Files.contents(Files.child(parent, name + "/name.txt")) else { return nil }
            let lines = rawTitle.components(separatedBy: .newlines).map(\.clean).filter { !$0.isEmpty }
            let title: String
            if lines.count > 1, let last = lines.last, last.hasPrefix(lines.dropLast().joined()) { title = last }
            else { title = lines.joined(separator: " ") }
            return (BusinessSegment(directory: segmentDirectory + "/" + name, title: title), ranks[id] ?? Int.max)
        }.sorted { left, right in
            if left.1 != right.1 { return left.1 < right.1 }
            return left.0.title.localizedStandardCompare(right.0.title) == .orderedAscending
        }.map(\.0)
    }

    /// Write the body and its list of imported files together. Reopening or saving an
    /// edited chapter must never append the same source a second time.
    static func consolidate(in company: ProjectAt) throws -> [String: String] {
        let segments = try segments(in: company)
        guard !segments.isEmpty else { return [:] }
        let file = try Files.child(company.url, StockModule.business.note!)
        let original = try Files.contents(file)
        let doc = Document(original ?? "")
        var imported: [String: String] = [:]
        if let field = doc.fields[importedNotesKey] {
            guard let saved = decode([String: String].self, field) else { throw Failure("业务拆分的迁移记录无法读取。") }
            imported = saved
        }
        var additions: [String] = []
        let previous = imported
        for segment in segments {
            var parts: [String] = []
            for path in [segment.business, segment.competition] where imported[path] == nil {
                guard let raw = try Files.contents(Files.child(company.url, path)) else { continue }
                let body = Document(raw).body
                let template = path == segment.business ? "## 业务流程\n\n## 收入来源\n\n## 增长驱动" : "## 主要竞争对手\n\n## 产品与市场份额\n\n## 竞争优势与风险"
                if !body.clean.isEmpty && body.clean != template {
                    parts.append(rebaseLinks(in: body, directory: String(segment.directory.dropFirst("analysis/".count))))
                }
                imported[path] = segment.title
            }
            if !parts.isEmpty || (previous[segment.business] == nil && imported[segment.business] != nil) {
                additions.append((["## " + segment.title] + parts).joined(separator: "\n\n"))
            }
        }
        guard imported != previous else { return imported }
        var lines = doc.header.components(separatedBy: "\n").dropLast(2).filter { !$0.hasPrefix(importedNotesKey + ":") }
        if lines.isEmpty { lines = ["---"] }
        lines.append(importedNotesKey + ": " + (try json(imported)))
        let header = (lines + ["---", ""]).joined(separator: "\n")
        var body = doc.body
        if !additions.isEmpty {
            if !body.isEmpty { body += body.hasSuffix("\n\n") ? "" : (body.hasSuffix("\n") ? "\n" : "\n\n") }
            body += additions.joined(separator: "\n\n") + "\n"
        }
        try Files.save(file, header + body, expected: original)
        return imported
    }

    // Insert a prefix at the beginning of the original destination. This preserves
    // angle brackets, title strings, percent escapes, parentheses and fragments.
    private static let destinations = try! NSRegularExpression(pattern: [
        // Skip fenced code, HTML comments and inline code before matching links.
        #"(?ms)^ {0,3}(`{3,}|~{3,})[^\n]*\n.*?(?:^ {0,3}\1[`~]*[ \t]*(?=\n|$)|\z)"#,
        #"(?s)<!--.*?(?:-->|\z)|(`+)(?!`).*?(?<!`)\2(?!`)"#,
        #"(?m)(?:\]\(\s*<?|^ {0,3}\[[^\]\n]+\]:[ \t]*<?|(?i:<(?:img|a)\b[^>\n]*?\s(?:src|href)\s*=\s*["']))()(?!(?:[a-zA-Z][a-zA-Z0-9+.\-]*:|[/#?<>\s)"']))(?=.)"#
    ].joined(separator: "|"))

    private static func rebaseLinks(in body: String, directory: String) -> String {
        let result = NSMutableString(string: body)
        let matches = destinations.matches(in: body, range: NSRange(location: 0, length: result.length))
        for match in matches.reversed() {
            let insertion = match.range(at: 3)
            if insertion.location != NSNotFound { result.insert(directory + "/", at: insertion.location) }
        }
        return result as String
    }
}
