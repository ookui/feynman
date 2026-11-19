import AppKit
import LinkPresentation
import UniformTypeIdentifiers

struct DroppedReference {
    let url: URL
    var title: String?

    static let safariLinks = "WebURLsWithTitlesPboardType"
    static let acceptedTypes = [UTType.fileURL.identifier, UTType.url.identifier, safariLinks, UTType.plainText.identifier]

    static func read(_ provider: NSItemProvider) async throws -> [Self] {
        // Safari may supply one property list containing multiple URL/title pairs.
        if provider.hasItemConformingToTypeIdentifier(safariLinks),
           let payload = try? await provider.loadItem(forTypeIdentifier: safariLinks, options: nil) {
            let plist: Any?
            if let data = payload as? Data { plist = try? PropertyListSerialization.propertyList(from: data, format: nil) }
            else { plist = payload }
            if let pairs = plist as? [[String]], pairs.count == 2 {
                let links = pairs[0].enumerated().compactMap { index, value -> Self? in
                    guard let url = webURL(value) else { return nil }
                    return Self(url: url, title: pairs[1].indices.contains(index) ? pairs[1][index] : nil)
                }
                if !links.isEmpty { return links }
            }
        }
        for type in [UTType.fileURL, .url, .plainText] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            guard let item = try? await provider.loadItem(forTypeIdentifier: type.identifier, options: nil) else { continue }
            let url = (item as? URL) ?? string(item).flatMap { URL(string: $0.clean, encodingInvalidCharacters: false) }
            guard let url else { continue }
            if url.isFileURL && type != .plainText { return [Self(url: url)] }
            guard webURL(url.absoluteString) != nil else { continue }
            var title: String?
            if provider.hasItemConformingToTypeIdentifier("public.url-name"),
               let name = try? await provider.loadItem(forTypeIdentifier: "public.url-name", options: nil) { title = string(name) }
            return [Self(url: url, title: title ?? provider.suggestedName)]
        }
        throw Failure("请拖入网页链接或本地文件。")
    }

    private static func string(_ value: Any) -> String? {
        if let string = value as? String { return string }
        return (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string.clean, encodingInvalidCharacters: false),
              MaterialLinks.isWeb(url.absoluteString), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    func importLink(into root: URL, configuration: URLSessionConfiguration = .ephemeral) async throws -> String {
        if let cached = try Files.cachedPDF(url.absoluteString, in: root, snapshot: Files.scan(root)) { return cached.id }
        guard let file = try await PDFLinkDownload(source: url).fetch(configuration: configuration) else {
            return try await Files.registerWebLink(url, title: pageTitle(), in: root)
        }
        defer { try? FileManager.default.removeItem(at: file.url) }
        let label = title?.clean
        let pageName = label == url.absoluteString || label?.isEmpty == true ? nil : label
        let name = Self.pdfFilename(file.name, fallback: pageName ?? url.lastPathComponent)
        return try Files.registerPDF(file.url, name: name, source: url, title: pageName, in: root)
    }

    private static func pdfFilename(_ suggested: String, fallback: String) -> String {
        let last = (suggested.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let base = (last as NSString).pathExtension.lowercased() == "pdf" ? (last as NSString).deletingPathExtension : fallback
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let safe = base.components(separatedBy: forbidden).joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        var stem = ""
        for char in safe {
            if stem.utf8.count + String(char).utf8.count > 170 { break }
            stem.append(char)
        }
        return (stem.isEmpty ? "报告" : stem) + ".pdf"
    }

    func pageTitle() async -> String {
        if let text = title?.clean, !text.isEmpty, text != url.absoluteString, text != url.host { return text }
        let provider = LPMetadataProvider()
        provider.shouldFetchSubresources = false
        provider.timeout = 6
        if let metadata = try? await provider.startFetchingMetadata(for: url),
           let title = metadata.title?.clean, !title.isEmpty { return title }
        return url.absoluteString
    }
}
