import Foundation
import PDFKit

/// Tokens retain word and script boundaries. The compact form also matches variations
/// such as "Open AI", "OpenAI", and "Open-AI".
private struct SearchTerms {
    let words: [String]
    let compact: String

    init(_ raw: String) {
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX"))
        let text = folded.unicodeScalars.contains { $0.properties.isIdeographic }
            ? folded.applyingTransform(.init("Traditional-Simplified"), reverse: false) ?? folded
            : folded
        var tokens: [String] = []
        var token = ""
        var lastWasHan = false
        for scalar in text.unicodeScalars {
            let isHan = scalar.properties.isIdeographic
            let isWord = CharacterSet.alphanumerics.contains(scalar)
            if !token.isEmpty && (!isWord || lastWasHan != isHan) {
                tokens.append(token)
                token = ""
            }
            if isWord { token.unicodeScalars.append(scalar) }
            lastWasHan = isHan
        }
        if !token.isEmpty { tokens.append(token) }
        words = tokens
        compact = tokens.joined()
    }

    struct Match {
        let tier: Int
        let gap: Int
        let location: Int
    }

    func match(in text: NSString) -> Match? {
        guard !compact.isEmpty, text.length > 0 else { return nil }
        let direct = text.range(of: compact, options: .literal)
        if direct.location != NSNotFound {
            return Match(tier: direct.length == text.length ? 0 : 1, gap: 0, location: direct.location)
        }
        if words.count > 1, let match = ordered(words, in: text, tier: 2) { return match }
        // A single unspaced Chinese phrase may omit intervening words.
        let parts = words.flatMap { word in
            word.unicodeScalars.first?.properties.isIdeographic == true ? word.map(String.init) : [word]
        }
        if parts != words, let match = ordered(parts, in: text, tier: 3, maxGap: 16) { return match }
        guard words.count > 1 else { return nil }
        // Match reordered keywords without using the same occurrence twice.
        var used: [NSRange] = []
        for word in words.sorted(by: { $0.utf16.count > $1.utf16.count }) {
            var start = 0
            while true {
                let r = text.range(of: word, options: .literal, range: NSRange(location: start, length: text.length - start))
                guard r.location != NSNotFound else { return nil }
                if let overlap = used.first(where: { NSIntersectionRange($0, r).length > 0 }) {
                    start = NSMaxRange(overlap)
                } else { used.append(r); break }
            }
        }
        let first = used.map(\.location).min() ?? 0
        let span = (used.map(NSMaxRange).max() ?? first) - first
        return Match(tier: 4, gap: span - compact.utf16.count, location: first)
    }

    /// Consume keywords covered by the title so the remaining ones can match in the body.
    func remainingTerms(after title: NSString) -> SearchTerms? {
        guard words.count > 1 else { return nil }
        let available = NSMutableString(string: title as String)
        var unused: [String] = []
        for word in words {
            let range = available.range(of: word, options: .literal)
            if range.location == NSNotFound { unused.append(word) }
            else { available.replaceCharacters(in: range, with: " ") }
        }
        guard !unused.isEmpty, unused.count < words.count else { return nil }
        return SearchTerms(unused.joined(separator: " "))
    }

    private func ordered(_ parts: [String], in text: NSString, tier: Int, maxGap: Int? = nil) -> Match? {
        var start = 0
        var best: Match?
        while start < text.length {
            if Task.isCancelled { return nil }
            var end = start
            var first = 0
            for (i, part) in parts.enumerated() {
                let r = text.range(of: part, options: .literal, range: NSRange(location: end, length: text.length - end))
                guard r.location != NSNotFound else { return best }
                if i == 0 { first = r.location }
                end = NSMaxRange(r)
            }
            // Tighten this window backwards so an early stray word does not hide a closer match.
            var previous = end
            for part in parts.reversed() {
                let r = text.range(of: part, options: [.literal, .backwards],
                                   range: NSRange(location: first, length: previous - first))
                previous = r.location
            }
            let gap = end - previous - compact.utf16.count
            if gap <= (maxGap ?? Int.max), gap < (best?.gap ?? Int.max) {
                best = Match(tier: tier, gap: gap, location: previous)
                if gap == 0 { break }
            }
            start = previous + parts[0].utf16.count
        }
        return best
    }
}

struct ProjectSearchItem: Identifiable {
    enum Target: Hashable { case entry(String), document(String), material(String) }
    let target: Target
    let title: String
    let kind: Kind?
    var id: String {
        switch target {
        case .entry(let id): return "entry:" + id
        case .document(let path): return "doc:" + path
        case .material(let source): return "material:" + source
        }
    }
}

struct ProjectSearchHit: Identifiable {
    let item: ProjectSearchItem
    let snippet: String?
    var id: String { item.id }
}

private struct IndexedBody {
    struct Passage { let start: Int; let original: Substring }
    let compact: NSString
    let passages: [Passage]

    init(_ raw: String) {
        var text = ""
        var passages: [Passage] = []
        var offset = 0
        for line in raw.split(whereSeparator: \.isNewline) {
            if Task.isCancelled { break }
            var tail = line[...]
            while !tail.isEmpty && !Task.isCancelled {
                let chunk = tail.prefix(100)
                let normalized = SearchTerms(String(chunk)).compact
                if !normalized.isEmpty {
                    passages.append(Passage(start: offset, original: chunk))
                    text += normalized
                    offset += normalized.utf16.count
                }
                tail = tail[chunk.endIndex...]
            }
        }
        self.passages = passages
        compact = text as NSString
    }

    func snippet(at location: Int) -> String? {
        guard let index = passages.lastIndex(where: { $0.start <= location }) else { return nil }
        let passage = passages[index]
        let length = (index + 1 < passages.count ? passages[index + 1].start : compact.length) - passage.start
        let skip = max(0, (location - passage.start) * passage.original.count / max(1, length) - 8)
        let fragment = passage.original.dropFirst(skip)
        var preview = String(fragment)
        if fragment.count < 45 && index + 1 < passages.count { preview += " " + passages[index + 1].original }
        return (skip == 0 ? "" : "…") + preview.clean
    }
}

struct ProjectSearchIndex {
    private struct Record {
        let item: ProjectSearchItem
        let titles: [SearchTerms]
        let bodies: [IndexedBody]
    }
    private struct CachedAttachment {
        let modified: Date?
        let size: Int?
        let body: IndexedBody
    }
    private var attachments: [URL: CachedAttachment] = [:]
    private var records: [Record] = []
    private(set) var itemsByKey: [String: ProjectSearchItem] = [:]

    init() {}

    init(snapshot: Snapshot, root: URL, previous: Self) {
        func attachment(_ source: String) -> IndexedBody? {
            guard source.hasPrefix("project:"),
                  let url = try? Files.child(root, String(source.dropFirst(8))),
                  ["txt", "md", "markdown", "mdown", "csv", "pdf"].contains(url.pathExtension.lowercased()),
                  let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  attrs.isRegularFile == true else { return nil }
            if let cached = attachments[url] ?? previous.attachments[url],
               cached.modified == attrs.contentModificationDate, cached.size == attrs.fileSize {
                attachments[url] = cached
                return cached.body
            }
            let raw: String?
            if url.pathExtension.lowercased() == "pdf" { raw = PDFDocument(url: url)?.string }
            else { raw = try? Files.contents(url) }
            guard let raw else { return nil }
            let body = IndexedBody(raw)
            attachments[url] = CachedAttachment(modified: attrs.contentModificationDate, size: attrs.fileSize, body: body)
            return body
        }
        func add(_ item: ProjectSearchItem, otherTitles: [String] = [], bodies: [IndexedBody], aliases: [String] = []) {
            records.append(Record(item: item, titles: ([item.title] + otherTitles).map(SearchTerms.init), bodies: bodies))
            itemsByKey[item.id] = item
            for alias in aliases where itemsByKey[alias] == nil { itemsByKey[alias] = item }
        }
        for e in snapshot.entries {
            if Task.isCancelled { return }
            let sources = snapshot.sources(for: e)
            let assets = e.kind == .references ? sources : e.assets
            let excerpts = ([e.body] + e.anchors.map { $0.section + "\n" + $0.quote }).joined(separator: "\n")
            let bodies = [IndexedBody(excerpts)] + assets.filter { $0 != "project:" + e.path }.compactMap(attachment)
            add(ProjectSearchItem(target: .entry(e.id), title: e.title, kind: e.kind),
                otherTitles: sources.map(materialLabel), bodies: bodies,
                aliases: e.aliases.map { "entry:" + $0 } + (sources + Array(e.archivedSources.keys)).map { "material:" + $0 })
        }
        for path in snapshot.reports + snapshot.documents + ["memo.md", "log.md"] {
            if Task.isCancelled { return }
            guard let raw = try? Files.contents(Files.child(root, path)) else { continue }
            let doc = Document(raw)
            let label = documentLabel(path)
            let title = doc.string("title") ?? doc.heading ?? label
            add(ProjectSearchItem(target: .document(path), title: title, kind: nil),
                otherTitles: [label, (path as NSString).lastPathComponent], bodies: [IndexedBody(doc.body)])
        }
        for source in snapshot.unlistedMaterials {
            if Task.isCancelled { return }
            let item = ProjectSearchItem(target: .material(source), title: materialLabel(source), kind: .references)
            add(item, bodies: [attachment(source)].compactMap { $0 })
        }
    }

    func results(_ query: String, entriesOnly: Bool = false) -> [ProjectSearchHit] {
        let needle = SearchTerms(query)
        guard !needle.compact.isEmpty else { return [] }
        var ranked: [(rank: Int, gap: Int, index: Int, hit: ProjectSearchHit)] = []
        for (index, record) in records.enumerated() {
            if Task.isCancelled { return [] }
            if entriesOnly {
                guard case .entry = record.item.target else { continue }
            }
            let titles = record.titles.compactMap { title -> SearchTerms.Match? in
                guard let hit = needle.match(in: title.compact as NSString) else { return nil }
                // For "AI", put a whole word ahead of the letters inside "retail".
                let wholeWord = needle.words.count == 1 && title.words.contains(needle.compact)
                let tier = hit.tier == 0 || wholeWord ? hit.tier : hit.tier + 1
                return SearchTerms.Match(tier: tier, gap: hit.gap, location: hit.location)
            }
            if let best = titles.min(by: { ($0.tier, $0.gap) < ($1.tier, $1.gap) }) {
                ranked.append((best.tier, best.gap, index, ProjectSearchHit(item: record.item, snippet: nil)))
                continue
            }
            var matches = record.bodies.compactMap { body in needle.match(in: body.compact).map { ($0, body) } }
            if matches.isEmpty, let title = record.titles.first, let remaining = needle.remainingTerms(after: title.compact as NSString) {
                matches = record.bodies.compactMap { body in remaining.match(in: body.compact).map { ($0, body) } }
            }
            if let (best, body) = matches.min(by: { ($0.0.tier, $0.0.gap) < ($1.0.tier, $1.0.gap) }) {
                ranked.append((6 + best.tier, best.gap, index, ProjectSearchHit(item: record.item, snippet: body.snippet(at: best.location))))
            }
        }
        return ranked.sorted { ($0.rank, $0.gap, $0.index) < ($1.rank, $1.gap, $1.index) }.map(\.hit)
    }
}

func documentLabel(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    if path.hasPrefix("references/files/"), UUID(uuidString: String(name.prefix(36))) != nil, name.dropFirst(36).first == "-" { return String(name.dropFirst(37)) }
    return ["README.md":"项目说明","questions.md":"原关键问题","companies.md":"原公司清单","challenge.md":"反驳稿","memo.md":"我的 Memo","log.md":"过程日志"][path] ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
}
