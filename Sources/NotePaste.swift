import AppKit
import ImageIO
import UniformTypeIdentifiers

final class NoteTextView: NSTextView {
    var noteURL: URL?
    var onPasteError: ((Error) -> Void)?

    override func paste(_ sender: Any?) {
        if !pasteMarkdown(from: .general) { super.paste(sender) }
    }
    @discardableResult func pasteMarkdown(from board: NSPasteboard) -> Bool {
        guard let noteURL else { return false }
        do {
            let text = string as NSString
            let range = selectedRange()
            let selection = text.substring(with: range)
            if var markdown = try NotePaste.markdown(from: board, beside: noteURL, selection: selection) {
                let blocks = markdown.components(separatedBy: "\n\n")
                if NotePaste.isTableBlock(blocks.first), range.location > 0, text.character(at: range.location - 1) != 10 {
                    markdown = "\n\n" + markdown
                }
                if NotePaste.isTableBlock(blocks.last), NSMaxRange(range) < text.length, text.character(at: NSMaxRange(range)) != 10 {
                    markdown += "\n\n"
                }
                insertText(markdown, replacementRange: range)
                return true
            }
            return false
        } catch { onPasteError?(error); return true }
    }
}

enum NotePaste {
    static let noteMarkdown = NSPasteboard.PasteboardType("app.feynman.markdown-selection")
    static let tableMarkdown = NSPasteboard.PasteboardType("app.feynman.markdown-table")
    static let tableCells = NSPasteboard.PasteboardType("app.feynman.table-cells")
    static let svgType = NSPasteboard.PasteboardType(UTType.svg.identifier)
    private static let tableDivider = #"^ *\|? *:?-+:? *(?:\| *:?-+:? *)*\|? *$"#

    static func isTableBlock(_ block: String?) -> Bool {
        guard let block, block.contains("|") else { return false }
        let lines = block.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        return lines.count >= 2 && lines[1].range(of: tableDivider, options: .regularExpression) != nil
    }

    static func originalImages(from items: [NSPasteboardItem], beside note: URL) throws -> String? {
        // Finder can advertise both the file and a preview on the same item.
        let images = try items.compactMap { item -> String? in
            if let value = item.string(forType: .fileURL) ?? item.string(forType: .URL),
               let file = URL(string: value), file.isFileURL,
               file.pathExtension.lowercased() == "svg" || UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true {
                return try storeImage(Data(contentsOf: file), name: file.lastPathComponent, note: note)
            }
            for type in [svgType, .init("image/svg+xml")] where item.types.contains(type) {
                if let bytes = item.data(forType: type) { return try storeImage(bytes, name: "图片.svg", note: note) }
            }
            return nil
        }
        return images.isEmpty ? nil : images.joined(separator: "\n")
    }

    private struct WebImage {
        let data: Data
        let mime: String

        init?(dataURL: String) {
            guard dataURL.lowercased().hasPrefix("data:image/"), let comma = dataURL.firstIndex(of: ",") else { return nil }
            let fields = dataURL[..<comma].dropFirst(5).lowercased().split(separator: ";")
            guard let type = fields.first else { return nil }
            mime = String(type)
            let payload = dataURL[dataURL.index(after: comma)...]
            if fields.contains("base64"), let decoded = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters) {
                data = decoded
            } else if mime == "image/svg+xml", !fields.contains("base64"), let xml = payload.removingPercentEncoding {
                data = Data(xml.utf8)
            } else { return nil }
        }

        init?(resource: [String: Any]) {
            guard let type = resource["WebResourceMIMEType"] as? String, type.lowercased().hasPrefix("image/"),
                  let bytes = resource["WebResourceData"] as? Data else { return nil }
            mime = type
            data = bytes
        }
    }

    private static func svgBytes(_ element: XMLElement) -> Data {
        let root = element.copy() as! XMLElement
        if root.namespace(forPrefix: "") == nil {
            root.addNamespace(XMLNode.namespace(withName: "", stringValue: "http://www.w3.org/2000/svg") as! XMLNode)
        }
        return Data(root.xmlString.utf8)
    }

    private static func webArchiveMarkdown(_ board: NSPasteboard, note: URL) throws -> String? {
        for type in ["com.apple.webarchive", "Apple Web Archive pasteboard type"] {
            guard let archive = board.propertyList(forType: .init(type)) as? [String: Any],
                  let main = archive["WebMainResource"] as? [String: Any] else { continue }
            if let image = WebImage(resource: main) {
                return try storeImage(image.data, name: "图片", note: note, mime: image.mime)
            }
            guard let data = main["WebResourceData"] as? Data, let html = String(data: data, encoding: .utf8),
                  let resources = archive["WebSubresources"] as? [[String: Any]] else { continue }
            var images: [String: WebImage] = [:]
            for resource in resources {
                if let url = resource["WebResourceURL"] as? String, let image = WebImage(resource: resource) {
                    images[url] = image
                }
            }
            if !images.isEmpty {
                let base = (main["WebResourceURL"] as? String).flatMap { URL(string: $0) }
                if let value = try htmlMarkdown(html, beside: note, archivedImages: images, baseURL: base) { return value }
            }
        }
        return nil
    }

    static func markdown(from board: NSPasteboard, beside note: URL, selection: String = "", htmlFallback: String? = nil, plainFallback: String? = nil) throws -> String? {
        if let text = board.string(forType: noteMarkdown) { return text }
        if let table = board.string(forType: tableMarkdown) { return table }
        if let images = try originalImages(from: board.pasteboardItems ?? [], beside: note) { return images }
        if let archived = try webArchiveMarkdown(board, note: note) { return archived }
        let plain = board.string(forType: .string) ?? plainFallback
        if let value = plain?.clean {
            if let image = WebImage(dataURL: value) { return try storeImage(image.data, name: "图片", note: note, mime: image.mime) }
            if value.hasPrefix("<svg") || value.hasPrefix("<?xml"),
               let root = (try? XMLDocument(xmlString: value, options: [.nodeLoadExternalEntitiesNever]))?.rootElement(),
               root.localName == "svg" {
                let bytes = root.namespace(forPrefix: "") == nil ? svgBytes(root) : Data(value.utf8)
                return try storeImage(bytes, name: "图片.svg", note: note)
            }
        }
        if let html = board.string(forType: .html) ?? htmlFallback, !html.isEmpty {
            let bitmapType = board.types?.first(where: isImageType)
            if let value = try htmlMarkdown(html, beside: note, plain: plain, selection: selection, bitmap: { bitmapType.flatMap { board.data(forType: $0) } }) { return value }
        }
        for type in board.types ?? [] {
            if isImageType(type), let data = board.data(forType: type) {
                return try storeImage(data, name: "图片", note: note)
            }
        }
        if let pairs = board.propertyList(forType: .init(DroppedReference.safariLinks)) as? [[String]], pairs.count == 2 {
            let links = pairs[0].enumerated().compactMap { index, url -> String? in
                guard MaterialLinks.isWeb(url) else { return nil }
                let title = pairs[1].indices.contains(index) ? pairs[1][index] : url
                return link(selection.isEmpty || pairs[0].count > 1 ? title : selection, url)
            }
            if !links.isEmpty { return links.joined(separator: "\n") }
        }
        if let url = board.string(forType: .URL), MaterialLinks.isWeb(url) {
            return link(selection.isEmpty ? board.string(forType: .init("public.url-name")) ?? url : selection, url)
        }
        if let data = board.data(forType: .rtf),
           let rich = NSAttributedString(rtf: data, documentAttributes: nil) {
            var hasTable = false
            rich.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rich.length)) { value, _, stop in
                if (value as? NSParagraphStyle)?.textBlocks.contains(where: { $0 is NSTextTableBlock }) == true {
                    hasTable = true
                    stop.pointee = true
                }
            }
            if hasTable, let html = try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html]),
               let string = String(data: html, encoding: .utf8), let value = try htmlMarkdown(string, beside: note) {
                return value
            }
            var result = ""
            rich.enumerateAttribute(.link, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
                let label = (rich.string as NSString).substring(with: range)
                let href = (value as? URL)?.absoluteString ?? value as? String
                result += href.map { link(label, $0) } ?? label
            }
            if result != rich.string { return tabularText(result) ?? result }
        }
        return plain.map { tabularText($0) ?? plainMarkdown($0, selection: selection) }
    }

    private static func isImageType(_ type: NSPasteboard.PasteboardType) -> Bool {
        type == .png || type == .tiff || type.rawValue.hasPrefix("image/") || UTType(type.rawValue)?.conforms(to: .image) == true
    }

    private static func htmlMarkdown(_ html: String, beside note: URL, plain: String? = nil,
                                     selection: String = "", bitmap: () -> Data? = { nil },
                                     archivedImages: [String: WebImage] = [:], baseURL: URL? = nil) throws -> String? {
        // HTML Tidy drops inline SVG. Preserve its case-sensitive geometry and paint definitions
        // before converting the surrounding HTML to Markdown.
        var markup = html
        if html.contains("<svg"), let fragment = try? XMLDocument(xmlString: "<div>" + html + "</div>",
                options: [.documentTidyXML, .nodeLoadExternalEntitiesNever]),
           let elements = try? fragment.nodes(forXPath: "//*[local-name()='svg' and not(ancestor::*[local-name()='svg'])]") {
            for case let svg as XMLElement in elements {
                guard let parent = svg.parent as? XMLElement else { continue }
                let img = XMLElement(name: "img")
                img.setAttributesWith(["alt": svg.attribute(forName: "aria-label")?.stringValue ?? "图片",
                                       "src": "data:image/svg+xml;base64," + svgBytes(svg).base64EncodedString()])
                parent.replaceChild(at: svg.index, with: img)
            }
            if !elements.isEmpty { markup = fragment.rootElement()?.xmlString ?? html }
        }
        guard let document = try? XMLDocument(xmlString: markup, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let root = document.rootElement() else { return nil }
        // XPath on a detached XMLNode silently loses its document context.
        return try withExtendedLifetime(document) {
            let body = (try? root.nodes(forXPath: "//body").first) ?? root
            let base = (try? root.nodes(forXPath: "//base/@href").first?.stringValue).flatMap { URL(string: $0) } ?? baseURL
            let images = (try? body.nodes(forXPath: ".//img")) as? [XMLElement] ?? []
            for img in images {
                guard let src = img.attribute(forName: "src"), let url = src.stringValue,
                      let image = archivedImages[url] ?? archivedImages[URL(string: url, relativeTo: base)?.absoluteString ?? url] else { continue }
                src.stringValue = "data:" + image.mime + ";base64," + image.data.base64EncodedString()
            }
            if images.count == 1, let src = images[0].attribute(forName: "src"),
               src.stringValue?.lowercased().hasPrefix("data:image/") != true, let data = bitmap() {
                // Clipboards can carry a bitmap alongside a private preview URL and a caption.
                // ImageIO identifies the actual format from the bytes.
                src.stringValue = "data:image/unknown;base64," + data.base64EncodedString()
            }
            // Some copy buttons wrap plain Markdown or tabular text in a rich-text span.
            if images.isEmpty, let plain, (try? body.nodes(forXPath: "descendant-or-self::table | descendant-or-self::pre | descendant-or-self::code | descendant-or-self::ul | descendant-or-self::ol").isEmpty) == true {
                if let table = tabularText(plain) { return table }
                if plain.components(separatedBy: "\n\n").contains(where: { isTableBlock($0) }) {
                    return plainMarkdown(plain, selection: selection)
                }
            }
            let value = try convert(body, base: base, note: note).clean
            return value.isEmpty ? nil : value
        }
    }

    private static func label(_ value: String) -> String {
        value.replacingOccurrences(of: #"([\\\[\]])"#, with: #"\\$1"#, options: .regularExpression)
    }
    private static func destination(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
    }
    private static func link(_ name: String, _ href: String) -> String { "[" + label(name) + "](" + destination(href) + ")" }

    static func imageMarkdown(_ name: String, _ href: String) -> String { "!" + link(name, href) }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let markup = try! NSRegularExpression(pattern: [
        #"(?ms)^ {0,3}(`{3,}|~{3,})[^\n]*\n.*?(?:^ {0,3}\1[ \t]*(?:\n|$)|\z)"#,
        #"`+[^`\n]*`+"#,
        #"!?\[(?:\\.|[^\]\n])*\]\((?:\\.|[^()\n]|\([^()\n]*\))*\)"#,
        #"<[^>\n]+>"#,
        #"(?m)^ {0,3}\[[^\]\n]+\]:[^\n]*"#
    ].joined(separator: "|"))
    static func plainMarkdown(_ text: String, selection: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let protected = markup.matches(in: text, range: range)
        let output = NSMutableString(string: text)
        for match in (detector?.matches(in: text, range: range) ?? []).reversed() {
            let value = (text as NSString).substring(with: match.range)
            guard MaterialLinks.isWeb(value), !protected.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { continue }
            output.replaceCharacters(in: match.range, with: link(match.range == range && !selection.isEmpty ? selection : value, value))
        }
        return output as String
    }

    private static func markdownTable(_ rows: [[String]]) -> String? {
        guard let columns = rows.map(\.count).max(), columns > 0 else { return nil }
        func row(_ values: [String]) -> String {
            let cells = values.map { value in
                let text = value.clean.replacingOccurrences(of: #"\s*\n\s*"#, with: "<br>", options: .regularExpression)
                var escaped = ""
                var slash = false
                for character in text {
                    if character == "|", !slash { escaped.append("\\") }
                    escaped.append(character)
                    slash = character == "\\" && !slash
                }
                return escaped
            }
            return "| " + (cells + Array(repeating: "", count: columns - cells.count)).joined(separator: " | ") + " |"
        }
        var lines = rows.map(row)
        lines.insert(row(Array(repeating: "---", count: columns)), at: 1)
        return lines.joined(separator: "\n")
    }

    // Only infer a table from plain text when tabs identify the same columns in multiple rows.
    private static func tabularText(_ text: String) -> String? {
        guard text.contains("\t"), !text.contains("```"), !text.contains("~~~") else { return nil }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var input = normalized.makeIterator()
        var next = input.next()
        var quoted = false
        var field = ""
        var fields: [String] = []
        var rows: [[String]] = []
        while let ch = next {
            next = input.next()
            switch ch {
            case "\"" where quoted && next == "\"":
                field.append(ch)
                next = input.next()
            case "\"" where quoted || field.isEmpty: quoted.toggle()
            case "\t" where !quoted: fields.append(field); field = ""
            case "\n" where !quoted:
                fields.append(field)
                rows.append(fields)
                fields = []
                field = ""
            default: field.append(ch)
            }
        }
        guard !quoted else { return nil }
        if !field.isEmpty || !fields.isEmpty { rows.append(fields + [field]) }
        guard rows.count > 1, let columns = rows.first?.count, columns > 1,
              rows.allSatisfy({ $0.count == columns }) else { return nil }
        return markdownTable(rows.map { $0.map { plainMarkdown($0, selection: "") } })
    }

    private static func convertTable(_ table: XMLElement, base: URL?, note: URL) throws -> String {
        let elements = try table.nodes(forXPath: "./tr | ./thead/tr | ./tbody/tr | ./tfoot/tr")
        var occupiedUntil: [Int: Int] = [:]
        var rows: [[String]] = []
        for (index, element) in elements.enumerated() {
            var row: [String] = []
            for case let cell as XMLElement in try element.nodes(forXPath: "./td | ./th") {
                while occupiedUntil[row.count, default: 0] > index { row.append("") }
                let column = row.count
                let content = try (cell.children ?? []).map { try convert($0, base: base, note: note) }.joined()
                row.append(content)
                let width = min(1000, max(1, Int(cell.attribute(forName: "colspan")?.stringValue ?? "") ?? 1))
                let height = min(elements.count - index, max(1, Int(cell.attribute(forName: "rowspan")?.stringValue ?? "") ?? 1))
                row += Array(repeating: "", count: width - 1)
                if height > 1 { for c in column..<(column + width) { occupiedUntil[c] = index + height } }
            }
            rows.append(row)
        }
        let caption = try table.nodes(forXPath: "./caption").map { try convert($0, base: base, note: note).clean }
        return "\n\n" + (caption + [markdownTable(rows)].compactMap { $0 }).joined(separator: "\n\n") + "\n\n"
    }

    private static func convert(_ node: XMLNode, base: URL?, note: URL) throws -> String {
        guard let el = node as? XMLElement else {
            guard node.kind == .text else { return "" }
            let value = (node.stringValue ?? "").replacingOccurrences(of: #"[\t\r\n ]+"#, with: " ", options: .regularExpression)
            return value.contains("://") ? plainMarkdown(value, selection: "") : value
        }
        func attribute(_ name: String) -> String? { el.attribute(forName: name)?.stringValue }
        func resolved(_ path: String) -> String { URL(string: path, relativeTo: base)?.absoluteString ?? path }
        let tag = el.name?.lowercased() ?? ""
        switch tag {
        case "script", "style", "head", "noscript": return ""
        case "ol", "ul":
            var number = min(999_999_999, max(0, Int(attribute("start") ?? "") ?? 1))
            var items: [String] = []
            for child in el.children ?? [] {
                guard let item = child as? XMLElement, item.name?.lowercased() == "li" else { continue }
                let marker = tag == "ol" ? "\(number). " : "- "
                let indent = String(repeating: " ", count: marker.count)
                var text = ""
                for part in item.children ?? [] {
                    let value = try convert(part, base: base, note: note)
                    if ["ul", "ol"].contains(part.name?.lowercased() ?? "") {
                        text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + value.clean + "\n"
                    } else {
                        text += value
                    }
                }
                let lines = text.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
                items.append(marker + (lines.first ?? "").clean + lines.dropFirst().map { $0.isEmpty ? "\n" : "\n" + indent + $0 }.joined())
                number = number < 999_999_999 ? number + 1 : 999_999_999
            }
            return items.isEmpty ? "" : "\n\n" + items.joined(separator: "\n") + "\n\n"
        case "table": return try convertTable(el, base: base, note: note)
        case "input" where attribute("type")?.lowercased() == "checkbox":
            return attribute("checked") == nil ? "[ ] " : "[x] "
        case "br": return "\n"
        case "pre": return "\n\n```\n" + (el.stringValue ?? "") + "\n```\n\n"
        case "code": return "`" + (el.stringValue ?? "") + "`"
        case "img":
            let alt = attribute("alt") ?? "图片"
            guard let src = attribute("src") else { return "" }
            if let image = WebImage(dataURL: src) {
                return try storeImage(image.data, name: alt, note: note, mime: image.mime)
            }
            let url = resolved(src)
            return MaterialLinks.isWeb(url) ? "!" + link(alt, url) : ""
        default: break
        }
        let inner = try (el.children ?? []).map { try convert($0, base: base, note: note) }.joined()
        switch tag {
        case "a":
            guard let href = attribute("href"), !href.isEmpty else { return inner }
            let target = resolved(href)
            if inner.hasPrefix("![") {
                if ["blob", "data", "sandbox"].contains(URL(string: target)?.scheme?.lowercased() ?? "") { return inner }
                return "[" + inner + "](" + destination(target) + ")"
            }
            let title = (el.stringValue ?? "").clean
            return link(title.isEmpty ? target : title, target)
        case "b", "strong": return "**" + inner + "**"
        case "em", "i": return "*" + inner + "*"
        case "h1", "h2", "h3", "h4", "h5", "h6": return "\n\n" + String(repeating: "#", count: Int(tag.suffix(1))!) + " " + inner.clean + "\n\n"
        case "blockquote": return "\n\n" + inner.clean.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n"
        case "td", "th": return inner + "\t"
        case "tr": return inner + "\n"
        case "p", "div", "section": return inner.clean.isEmpty ? "" : "\n\n" + inner.clean + "\n\n"
        default: return inner
        }
    }

    static func storeImage(_ data: Data, name: String, note: URL, mime: String? = nil) throws -> String {
        imageMarkdown(name, try storeImageFile(data, name: name, note: note, mime: mime))
    }

    static func storeImageFile(_ data: Data, name: String, note: URL, mime: String? = nil) throws -> String {
        let folder = try Files.child(note.deletingLastPathComponent(), "assets")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if (name as NSString).pathExtension.lowercased() == "svg" || mime?.lowercased() == "image/svg+xml" {
            guard let xml = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
                  xml.rootElement()?.localName == "svg" else { throw Failure("无法读取 SVG 图片。") }
            let filename = UUID().uuidString.lowercased() + ".svg"
            try data.write(to: Files.child(folder, filename), options: .withoutOverwriting)
            return "assets/" + filename
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier) else {
            throw Failure("无法读取剪贴板中的图片。")
        }
        let bytes: Data
        let ext: String
        if [.png, .jpeg, .gif, .webP].contains(type) {
            bytes = data
            ext = type.preferredFilenameExtension ?? "png"
        } else {
            guard let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw Failure("无法转换剪贴板图片。") }
            bytes = png
            ext = "png"
        }
        let filename = UUID().uuidString.lowercased() + "." + ext
        try bytes.write(to: Files.child(folder, filename), options: .withoutOverwriting)
        return "assets/" + filename
    }
}
