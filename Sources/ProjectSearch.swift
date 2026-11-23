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

struct SearchOccurrence: Codable, Equatable, Hashable {
    let path: String
    let start: Int
    let length: Int
    let page: Int?
    let before: String
    let match: String
    let after: String
}
struct ProjectSearchHit: Identifiable {
    let item: ProjectSearchItem
    let snippet: String?
    var occurrences: [SearchOccurrence] = []
    var titleMatch = false
    var id: String { item.id }
}

private struct IndexedBody {
    struct Passage { let start: Int; let original: Substring }
    let compact: NSString
    let passages: [Passage]

    let raw: String
    let path: String
    let page: Int?
    let base: Int
    init(_ raw: String, path: String, page: Int? = nil, base: Int = 0) {
        self.base = base
        self.raw = raw
        self.path = path
        self.page = page
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

    func occurrences(_ regex: NSRegularExpression) -> [SearchOccurrence] {
        let ns = raw as NSString
        var found: [SearchOccurrence] = []
        regex.enumerateMatches(in: raw, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            guard let r = match?.range, r.length > 0 else { return }
            found.append(occurrence(r))
        }
        return found
    }
    func occurrence(_ range: NSRange) -> SearchOccurrence {
        let ns = raw as NSString, end = NSMaxRange(range)
        let lo = max(0, range.location - 20)
        return SearchOccurrence(path: path, start: base + range.location, length: range.length, page: page,
            before: ns.substring(with: NSRange(location: lo, length: range.location-lo)),
            match: ns.substring(with: range),
            after: ns.substring(with: NSRange(location: end, length: min(35, ns.length-end))))
    }
    func fuzzyOccurrence(at location: Int, needle: SearchTerms) -> SearchOccurrence? {
        guard let passage = passages.last(where: { $0.start <= location }) else { return nil }
        var compactOffset = passage.start
        let rawStart = passage.original.startIndex.utf16Offset(in: raw)
        var at = rawStart
        for ch in passage.original {
            let value = String(ch)
            if compactOffset + SearchTerms(value).compact.utf16.count > location { break }
            compactOffset += SearchTerms(value).compact.utf16.count
            at += value.utf16.count
        }
        let ns = raw as NSString
        return occurrence(NSRange(location: at, length: min(ns.length-at, max(1,needle.words.first?.utf16.count ?? 1))))
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
        let bodies: [IndexedBody]
    }
    private var attachments: [URL: CachedAttachment] = [:]
    private var records: [Record] = []
    private(set) var itemsByKey: [String: ProjectSearchItem] = [:]

    init() {}

    init(snapshot: Snapshot, root: URL, previous: Self) {
        func attachment(_ source: String) -> [IndexedBody] {
            guard source.hasPrefix("project:"),
                  let url = try? Files.child(root, String(source.dropFirst(8))),
                  ["txt","json","svg","html","htm","md","markdown","mdown","csv","pdf"].contains(url.pathExtension.lowercased()),
                  let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  attrs.isRegularFile == true else { return [] }
            if let cached = attachments[url] ?? previous.attachments[url],
               cached.modified == attrs.contentModificationDate, cached.size == attrs.fileSize {
                attachments[url] = cached
                return cached.bodies
            }
            let path = String(source.dropFirst(8)), ext = url.pathExtension.lowercased()
            let bodies: [IndexedBody]
            if ext == "pdf", let pdf = PDFDocument(url: url) {
                bodies = (0..<pdf.pageCount).compactMap { i in pdf.page(at:i)?.string.map { IndexedBody($0,path:path,page:i+1) } }
            } else if let raw = try? Files.contents(url) {
                let text = ["html","htm"].contains(ext) ? Self.htmlText(raw) :
                    ["md","markdown","mdown"].contains(ext) ? Document(raw).body : raw
                bodies = [IndexedBody(text,path:path)]
            } else { return [] }
            attachments[url] = CachedAttachment(modified: attrs.contentModificationDate, size: attrs.fileSize, bodies: bodies)
            return bodies
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
            var bodies = [IndexedBody(e.body, path: e.path)]
            for anchor in e.anchors {
                if let url = try? Files.child(root, anchor.report), let raw = try? Files.contents(url),
                   let r = Document(raw).body.range(of: anchor.quote) {
                    let source = Document(raw).body
                    let start = r.lowerBound.utf16Offset(in: source)
                    bodies.append(IndexedBody(anchor.quote, path: anchor.report, base: start))
                } else {
                    bodies.append(IndexedBody(anchor.section + "\n" + anchor.quote, path: e.path))
                }
            }
            bodies += assets.filter { $0 != "project:" + e.path }.flatMap(attachment)
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
                otherTitles: [label, (path as NSString).lastPathComponent], bodies: [IndexedBody(doc.body,path:path)])
        }
        for source in snapshot.unlistedMaterials {
            if Task.isCancelled { return }
            let item = ProjectSearchItem(target: .material(source), title: materialLabel(source), kind: .references)
            add(item, bodies: attachment(source))
        }
    }

    static func htmlText(_ raw: String) -> String {
        var s = raw
        for pattern in ["(?is)<(script|style|head|template|noscript)\\b[^>]*>.*?</\\1\\s*>", "(?s)<!--.*?-->"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "(?i)<(?:br|/p|/div|/li|/h[1-6]|/tr|/section|/article)\\b[^>]*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?s)<[^>]*>", with: " ", options: .regularExpression)
        let re = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos|nbsp);")
        let ns = s as NSString; let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let key = ns.substring(with: m.range(at: 1)); var value: String?
            if key.hasPrefix("#x"), let n = UInt32(key.dropFirst(2), radix: 16), let scalar = UnicodeScalar(n) { value = String(scalar) }
            else if key.hasPrefix("#"), let n = UInt32(key.dropFirst()), let scalar = UnicodeScalar(n) { value = String(scalar) }
            else { value = ["amp":"&", "lt":"<", "gt":">", "quot":"\"", "apos":"'", "nbsp":" "][key] }
            if let value = value, let range = Range(m.range, in: s) { s.replaceSubrange(range, with: value) }
        }
        return s
    }
    func results(_ query: String, entriesOnly: Bool = false, options: ProjectSearchOptions = ProjectSearchOptions(), document: String? = nil) -> [ProjectSearchHit] {
        let needle = SearchTerms(query)
        guard let regex = options.matcher(options.isRegex || options.exact ? query.clean : query.clean.folding(options: .widthInsensitive, locale: nil)), !needle.compact.isEmpty || options.isRegex else { return [] }
        var ranked: [(rank: Int, gap: Int, index: Int, hit: ProjectSearchHit)] = []
        // A Latin phrase uses word boundaries. Otherwise the compact fuzzy index
        // also matches "physical ai" inside "metaphysical aid".
        let latinPhrase = needle.words.count > 1 && needle.words.allSatisfy {
            $0.unicodeScalars.allSatisfy { $0.isASCII }
        }
        for (index, record) in records.enumerated() {
            if Task.isCancelled { return [] }
            if entriesOnly {
                guard case .entry = record.item.target else { continue }
            }
            let bodies = record.bodies.filter { document == nil || $0.path == document }
            if document != nil && bodies.isEmpty { continue }
            let occurrences = bodies.flatMap { $0.occurrences(regex) }
            let exactTitle = regex.firstMatch(in: record.item.title,range:NSRange(record.item.title.startIndex...,in:record.item.title)) != nil
            if options.strict || latinPhrase {
                if exactTitle || !occurrences.isEmpty {
                    ranked.append((exactTitle ? 0 : 6,0,index,ProjectSearchHit(item:record.item,snippet:occurrences.first?.match,occurrences:occurrences,titleMatch:exactTitle)))
                }
                continue
            }
            let titles = record.titles.compactMap { title -> SearchTerms.Match? in
                guard let hit = needle.match(in: title.compact as NSString) else { return nil }
                // For "AI", put a whole word ahead of the letters inside "retail".
                let wholeWord = needle.words.count == 1 && title.words.contains(needle.compact)
                let tier = hit.tier == 0 || wholeWord ? hit.tier : hit.tier + 1
                return SearchTerms.Match(tier: tier, gap: hit.gap, location: hit.location)
            }
            if let best = titles.min(by: { ($0.tier, $0.gap) < ($1.tier, $1.gap) }) {
                ranked.append((best.tier, best.gap, index, ProjectSearchHit(item: record.item, snippet: nil, occurrences: occurrences, titleMatch: true)))
                continue
            }
            var matches = bodies.compactMap { body in needle.match(in: body.compact).map { ($0, body) } }
            if matches.isEmpty, let title = record.titles.first, let remaining = needle.remainingTerms(after: title.compact as NSString) {
                matches = bodies.compactMap { body in remaining.match(in: body.compact).map { ($0, body) } }
            }
            if let (best, body) = matches.min(by: { ($0.0.tier, $0.0.gap) < ($1.0.tier, $1.0.gap) }) {
                ranked.append((6 + best.tier, best.gap, index, ProjectSearchHit(item: record.item, snippet: body.snippet(at: best.location), occurrences: occurrences.isEmpty ? [body.fuzzyOccurrence(at: best.location, needle: needle)].compactMap { $0 } : occurrences)))
            } else if !occurrences.isEmpty {
                ranked.append((6,0,index,ProjectSearchHit(item: record.item,snippet:occurrences[0].match,occurrences:occurrences)))
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

// SimaQ's separator rules and ICU variant groups preserve original UTF-16 ranges.
struct ProjectSearchOptions: Equatable {
    var whole = false
    var sensitive = false
    var exact = false
    var isRegex = false
    var strict: Bool { whole || sensitive || exact || isRegex }
    func matcher(_ q: String) -> NSRegularExpression? {
        let separators = try! NSRegularExpression(pattern: #"[\s_\-‐‑‒–—―−]+"#)
        let transition = try! NSRegularExpression(pattern: #"(?<=\p{Han})(?=[A-Za-z0-9])|(?<=[A-Za-z0-9])(?=\p{Han})"#)
        let gap = #"[\t _\-‐‑‒–—―−]"#
        let words = exact ? [q] : separators.split(q)
        let parts = words.map { exact ? [$0] : transition.split($0) }
        var pattern = ""
        if isRegex { pattern = q }
        else {
            for (i,word) in parts.enumerated() {
                if i > 0 {
                    let boundary = String(words[i-1].suffix(1)) + String(words[i].prefix(1))
                    let mixed = transition.firstMatch(in:boundary,range:NSRange(boundary.startIndex...,in:boundary)) != nil
                    pattern += gap + (mixed ? "*" : "+")
                }
                pattern += word.map(ChineseSearchForms.shared.literalPattern).joined(separator:gap + "*")
            }
        }
        guard !pattern.isEmpty else { return nil }
        if whole {
            pattern = #"(?<![\p{L}\p{N}])(?:"# + pattern + #")(?![\p{L}\p{N}])"#
        } else if !isRegex {
            // Latin words can abut Chinese prose, but “AI” must not match “aid”.
            let wordChar = #"[\p{Latin}\p{N}\p{M}]"#
            if words.first?.range(of:"^[A-Za-z0-9]",options:.regularExpression) != nil { pattern = "(?<!" + wordChar + ")" + pattern }
            if words.last?.range(of:"[A-Za-z0-9]$",options:.regularExpression) != nil { pattern += "(?!" + wordChar + ")" }
        }
        return try? NSRegularExpression(pattern: pattern, options: sensitive ? [] : [.caseInsensitive])
    }
}

private struct ChineseSearchForms {
    static let shared = ChineseSearchForms()
    private let representatives: [Unicode.Scalar:Unicode.Scalar]
    private let alternatives: [Unicode.Scalar:String]

    private init() {
        let ideographs = (0...0x10ffff).compactMap(Unicode.Scalar.init).filter { $0.properties.isIdeographic }
        var parents = [Unicode.Scalar:Unicode.Scalar]()
        func representative(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
            var root = scalar
            while let parent = parents[root] { root = parent }
            return root
        }
        // Use the system's ICU character mappings. Separating characters prevents
        // phrase transliteration from changing how a substring is indexed.
        let transform = StringTransform("Traditional-Simplified")
        for start in stride(from: 0, to: ideographs.count, by: 4096) {
            let batch = ideographs[start..<min(start + 4096, ideographs.count)]
            let input = batch.map(String.init).joined(separator:"\n")
            guard let converted = input.applyingTransform(transform, reverse:false) else { continue }
            for (source, form) in zip(batch, converted.split(separator:"\n", omittingEmptySubsequences:false)) {
                guard form.unicodeScalars.count == 1, let target = form.unicodeScalars.first,
                      target != source else { continue }
                // A few system mappings are reciprocal. Merge both sets once.
                let a = representative(source), b = representative(target)
                if a != b { parents[a] = b }
            }
        }
        var keys = [Unicode.Scalar:Unicode.Scalar]()
        var groups = [Unicode.Scalar:String]()
        for variant in parents.keys {
            let key = representative(variant)
            keys[variant] = key
            groups[key, default:String(key)].unicodeScalars.append(variant)
        }
        representatives = keys
        alternatives = groups
    }

    func key(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.isASCII && representatives[$0] != nil }) else { return text }
        var result = String(scalars[..<first])
        for scalar in scalars[first...] { result.unicodeScalars.append(representatives[scalar] ?? scalar) }
        return result
    }

    func literalPattern(_ text: String) -> String {
        var result = "", literal = ""
        for scalar in text.unicodeScalars {
            if let group = alternatives[representatives[scalar] ?? scalar] {
                result += NSRegularExpression.escapedPattern(for:literal) + "[" + group + "]"
                literal = ""
            } else {
                literal.unicodeScalars.append(scalar)
            }
        }
        return result + NSRegularExpression.escapedPattern(for:literal)
    }
}

private extension NSRegularExpression {
    func split(_ text: String) -> [String] {
        let ns = text as NSString; let matches = self.matches(in:text, range:NSRange(location:0,length:ns.length)); var start = 0; var parts = [String]()
        for match in matches { if match.range.location > start { parts.append(ns.substring(with:NSRange(location:start,length:match.range.location-start))) }; start = NSMaxRange(match.range) }
        if start < ns.length { parts.append(ns.substring(from:start)) }; return parts
    }
}
