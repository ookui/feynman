import SwiftUI
import WebKit
import ImageIO
import UniformTypeIdentifiers

struct Mark: Codable, Equatable {
    var id: String; var kind: String; var title: String; var anchor: Anchor
}
struct ReaderData: Codable, Equatable {
    var file: String; var body: String; var marks: [Mark]; var focus: Anchor?; var extract: Bool; var scroll: Double
    var deletedIDs: [String]; var deletedPaths: [String]; var fragment: String?
    var questionHistory: [ResearchTurn]?
    var searchLanding: SearchOccurrence?
    var searchNavigation: UUID?
    var sourceOffset: Int?
    var editID: UUID?
    var initialCommand: String?
    var viewportY: Double?
    var selectionLength: Int?
    var editOffset: Int?
    var editable: Bool?
    var doubleClickDelay: Double?
    var kinds: [String]?
}
struct Reader: NSViewRepresentable {
    @ObservedObject var model: Workspace
    var path: String
    var bodyText: String
    var extract = false
    var questionHistory: [ResearchTurn]? = nil
    var allowsEditing = true
    func makeCoordinator() -> Bridge { Bridge(model) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "feynman-image")
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "feynman-media")
        config.userContentController.add(context.coordinator, name: "reader")
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "notePaste")
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "tableCopy")
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "selectionClipboard")
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "imageImport")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        if let url = Bundle.main.url(forResource: "reader", withExtension: "html") { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        let marks = model.snapshot.entries.flatMap { e in e.anchors.filter { $0.report == path }.map { Mark(id: e.id, kind: e.kind.rawValue, title: e.title, anchor: $0) } }
        let bridge = context.coordinator
        let scroll = bridge.data?.file == path ? bridge.data!.scroll : UserDefaults.standard.double(forKey: bridge.scrollKey(path))
        let editable = allowsEditing && model.canEditNote(path)
        let note = model.inlineNote.flatMap { editable && $0.path == path && $0.mode != .title ? $0 : nil }
        model.readerWeb = web
        let rich = note?.mode == .rich
        if bridge.rich != rich {
            bridge.ready = false; bridge.rich = rich
            if let url = Bundle.main.url(forResource: rich ? "markdown" : "reader", withExtension: "html") { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        }
        let data = ReaderData(file: path, body: bodyText, marks: marks, focus: model.focus, extract: extract, scroll: scroll,
                              deletedIDs: model.snapshot.deletedIDs.sorted(), deletedPaths: model.snapshot.deletedPaths.sorted(), fragment: model.headingFragment, questionHistory: questionHistory,
                              searchLanding: model.searchLanding.flatMap { $0.path == path ? $0 : nil }, searchNavigation: model.searchNavigation,
                              sourceOffset: model.readingPosition.flatMap { $0.path == path ? $0.offset : nil },
                              editID: note?.id, initialCommand: note?.initialCommand, viewportY: note?.viewportY, selectionLength: note?.selectionLength, editOffset: note?.caret,
                              editable: editable, doubleClickDelay: NSEvent.doubleClickInterval * 1000,
                              kinds: model.project?.info.stock == nil ? nil : Kind.companyKinds.filter { $0 != .references }.map(\.rawValue))
        if bridge.data != data { bridge.data = data; bridge.render(web) }
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Bridge) {
        coordinator.imagePreview?.close()
        let controller = web.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "imageImport", contentWorld: .page)
        controller.removeScriptMessageHandler(forName: "selectionClipboard", contentWorld: .page)
        controller.removeScriptMessageHandler(forName: "reader")
        controller.removeScriptMessageHandler(forName: "notePaste", contentWorld: .page)
        controller.removeScriptMessageHandler(forName: "tableCopy", contentWorld: .page)
    }
    @MainActor final class Bridge: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKURLSchemeHandler {
        let model: Workspace; var data: ReaderData?; var ready = false
        var rich = false
        var imagePreview: ReaderImagePanel?
        init(_ model: Workspace) { self.model = model }
        @objc func openItem(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? String { model.go(.entry(id)) }
        }
        func scrollKey(_ path: String) -> String { "scroll." + (model.project?.id ?? "") + "." + path }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; render(webView) }
        func render(_ web: WKWebView) {
            guard ready else { return }
            guard let data, let raw = try? json(data) else { return }
            web.evaluateJavaScript("render(" + raw + ")") { _, e in if let e { self.model.error = e.localizedDescription } }
        }
        func localMedia(_ request: URL) throws -> (URL, String) {
            guard ["feynman-image", "feynman-media"].contains(request.scheme), request.host == "local",
                  let parts = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems,
                  let path = parts.first(where: { $0.name == "file" })?.value,
                  path == data?.file,
                  let encoded = parts.first(where: { $0.name == "src" })?.value,
                  let relative = encoded.removingPercentEncoding,
                  !relative.hasPrefix("/"), URL(string: relative)?.scheme == nil else { throw Failure("图片路径无效。") }
            let directory = try model.documentURL(path).deletingLastPathComponent()
            let image = directory.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
            let key = try model.documentKey(for: image)
            if key.hasPrefix("lakehouse:"), !path.hasPrefix("lakehouse:") { throw Failure("图片超出工作目录。") }
            if request.scheme == "feynman-media" {
                guard let type = UTType(filenameExtension: image.pathExtension), type.conforms(to: .movie),
                      let mime = type.preferredMIMEType else { throw Failure("视频格式无效。") }
                return (image, mime)
            }
            if image.pathExtension.lowercased() == "svg" { return (image,"image/svg+xml") }
            guard let type = UTType(filenameExtension: image.pathExtension), type.conforms(to: .image),
                  let source = CGImageSourceCreateWithURL(image as CFURL, nil),
                  let identifier = CGImageSourceGetType(source) as String?,
                  let mime = UTType(identifier)?.preferredMIMEType, mime != "image/svg+xml" else { throw Failure("图片格式无效。") }
            return (image, mime)
        }
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            do {
                guard let request = task.request.url else { throw Failure("图片路径无效。") }
                let (image, mime) = try localMedia(request)
                let bytes = try Data(contentsOf: image, options: .mappedIfSafe)
                task.didReceive(URLResponse(url: request, mimeType: mime, expectedContentLength: bytes.count, textEncodingName: nil))
                task.didReceive(bytes)
                task.didFinish()
            } catch { task.didFailWithError(error) }
        }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let page = rich ? "markdown" : "reader"
            decisionHandler(action.request.url == Bundle.main.url(forResource: page, withExtension: "html") ? .allow : .cancel)
        }

        var pasteboard: NSPasteboard = .general
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            if message.name == "imageImport" {
                guard message.frameInfo.isMainFrame, let m = message.body as? [String: Any], let file = m["file"] as? String,
                      file == data?.file, data?.editable == true, model.canEditNote(file),
                      let name = m["name"] as? String, let encoded = m["data"] as? String, let bytes = Data(base64Encoded: encoded) else {
                    replyHandler(nil, "无法导入图片。"); return
                }
                do {
                    let path = try NotePaste.storeImageFile(bytes, name: name, note: model.documentURL(file), mime: m["mime"] as? String)
                    replyHandler(["path":path, "markdown":NotePaste.imageMarkdown(name, path)], nil)
                } catch { replyHandler(nil, error.localizedDescription) }
                return
            }
            if message.name == "selectionClipboard" {
                guard message.frameInfo.isMainFrame, let m = message.body as? [String: Any],
                      let path = m["file"] as? String, data?.file == path, data?.editable == true,
                      model.canEditNote(path), let expected = m["body"] as? String,
                      expected == (model.inlineNote.flatMap { $0.path == path ? $0.text : nil } ?? data?.body) else {
                    replyHandler(nil, "正文已更新，请重新选择。"); return
                }
                if m["action"] as? String == "cut", let text = m["text"] as? String {
                    let item = NSPasteboardItem()
                    guard item.setString(text, forType: .string), item.setString(text, forType: NotePaste.noteMarkdown) else {
                        replyHandler(nil, "无法复制选中的正文。"); return
                    }
                    pasteboard.clearContents()
                    if pasteboard.writeObjects([item]) { replyHandler(true,nil) }
                    else { replyHandler(nil, "无法写入剪贴板。") }
                } else if m["action"] as? String == "paste" {
                    do { replyHandler(try NotePaste.markdown(from: pasteboard, beside: model.documentURL(path), htmlFallback: m["html"] as? String, plainFallback: m["plain"] as? String), nil) }
                    catch { replyHandler(nil,error.localizedDescription) }
                } else { replyHandler(nil, "无法读取选区操作。") }
                return
            }
            guard message.frameInfo.isMainFrame,
                  let m = message.body as? [String: Any], let note = model.inlineNote,
                  data?.editable != false, model.canEditNote(note.path), note.path == data?.file, m["id"] as? String == note.id.uuidString else {
                replyHandler(nil, "当前段落已结束编辑。"); return
            }
            if message.name == "tableCopy" {
                guard let text = m["text"] as? String, let whole = m["whole"] as? Bool else {
                    replyHandler(nil, "无法读取选中的表格。"); return
                }
                let item = NSPasteboardItem()
                guard item.setString(text, forType: .string),
                      item.setString(text, forType: whole ? NotePaste.tableMarkdown : NotePaste.tableCells) else {
                    replyHandler(nil, "无法复制选中的表格。"); return
                }
                pasteboard.clearContents()
                if pasteboard.writeObjects([item]) { replyHandler(true, nil) }
                else { replyHandler(nil, "无法写入剪贴板。") }
                return
            }
            if m["grid"] as? Bool == true, let cells = pasteboard.string(forType: NotePaste.tableCells) {
                replyHandler(["cells": cells], nil); return
            }
            if m["imageOriginals"] as? Bool == true {
                do { replyHandler(try NotePaste.originalImages(from: pasteboard.pasteboardItems ?? [], beside: note.url), nil) }
                catch { replyHandler(nil, error.localizedDescription) }
                return
            }
            do { replyHandler(try NotePaste.markdown(from: pasteboard, beside: note.url, selection: m["selection"] as? String ?? "", htmlFallback: m["html"] as? String, plainFallback: m["plain"] as? String), nil) }
            catch { replyHandler(nil, error.localizedDescription) }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let m = message.body as? [String:Any], let path = m["file"] as? String, data?.file == path else { return }
            switch m["action"] as? String {
            case "error": model.error = m["message"] as? String
            case "rich":
                guard data?.editable == true, let start = m["start"] as? Int else { return }
                if model.inlineNote == nil, (try? model.text(path)).map({ Document($0).body }) != data?.body {
                    model.refresh()
                    return
                }
                model.beginInlineNote(path, offset: start, mode: .rich)
                if let draft = model.inlineNote, draft.mode == .rich, draft.path == path {
                    draft.selectionLength = m["length"] as? Int ?? 0
                    draft.initialCommand = m["command"] as? String
                    draft.viewportY = m["viewportY"] as? Double
                }
            case "dropImages":
                guard data?.editable == true, model.canEditNote(path), let body = m["body"] as? String,
                      let offset = m["at"] as? Int, let value = m["value"] as? String,
                      offset >= 0, offset <= (body as NSString).length else { return }
                model.beginInlineNote(path, offset: offset, mode: .rich)
                guard let draft = model.inlineNote, draft.path == path, draft.mode == .rich, draft.text == body else { return }
                let before = (body as NSString).substring(to: offset), after = (body as NSString).substring(from: offset)
                let prefix = before.isEmpty || before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n"
                let suffix = after.isEmpty || after.hasPrefix("\n\n") ? "" : after.hasPrefix("\n") ? "\n" : "\n\n"
                draft.text = before + prefix + value + suffix + after
                draft.caret = offset + (prefix + value).utf16.count
                model.scheduleNoteSave(draft)
            case "imageMenu", "previewImage":
                if let web = message.webView { handleImageMessage(m, in: web) }
            case "edit":
                guard data?.editable != false, model.canEditNote(path), let offset = m["offset"] as? Int else { return }
                if let note = model.inlineNote, note.path == path, note.mode != .title {
                    message.webView?.callAsyncJavaScript("if (state?.editID === id && !activeBlock) openBlockAt(offset, y)",
                        arguments: ["id": note.id.uuidString, "offset": offset, "y": m["y"] ?? NSNull()],
                        in: nil, in: .page, completionHandler: nil)
                    return
                }
                guard (try? model.text(path)).map({ Document($0).body }) == data?.body else { model.refresh(); return }
                model.beginInlineNote(path, offset: offset, mode: .paragraph)
            case "change", "endParagraph":
                guard data?.editable != false, model.canEditNote(path), let note = model.inlineNote, note.path == path, m["id"] as? String == note.id.uuidString else { return }
                if let start = m["start"] as? Int, let length = m["length"] as? Int, let value = m["value"] as? String {
                    let text = note.text as NSString
                    guard start >= 0, length >= 0, start <= text.length, length <= text.length - start else { return }
                    note.text = text.replacingCharacters(in: NSRange(location: start, length: length), with: value)
                    if m["composing"] as? Bool == true { note.autosave?.cancel() }
                    else { model.scheduleNoteSave(note) }
                }
                if let caret = m["caret"] as? Int { note.caret = caret }
                if m["action"] as? String == "endParagraph", note.mode == .paragraph || m["done"] as? Bool == true {
                    model.finishInlineNote()
                }
            case "extract":
                guard data?.extract == true, let raw = m["kind"] as? String, let k = Kind(rawValue: raw), k != .references,
                      model.snapshot.kinds.contains(k), let a = m["anchor"] as? [String:Any], let bytes = try? JSONSerialization.data(withJSONObject: a), let anchor = try? JSONDecoder().decode(Anchor.self, from: bytes), anchor.report == path else { return }
                let e = Entry(kind: k, title: String(anchor.quote.prefix(80)), origin: "报告划选")
                model.dialog = .editor(Editor(entry: e, anchor: anchor))
            case "show":
                if let href = m["href"] as? String, Workspace.isMarkdown(URL(fileURLWithPath: String(href.prefix { $0 != "#" && $0 != "?" }))) {
                    model.follow(href, from: path)
                    return
                }
                if m["href"] is String,
                   let ref = (m["ids"] as? [String] ?? []).compactMap({ model.snapshot.resolve($0) }).first(where: { $0.kind == .references }) {
                    model.go(.entry(ref.id))
                    return
                }
                if path.hasPrefix("reports/"), model.place == .doc(path),
                   let values = m["anchors"] as? [[String:Any]], let bytes = try? JSONSerialization.data(withJSONObject: values),
                   let anchors = try? JSONDecoder().decode([Anchor].self, from: bytes) {
                    let current = Set(data?.marks.map(\.anchor) ?? [])
                    let passage = anchors.filter { current.contains($0) }
                    if !model.snapshot.questions(for: model.snapshot.owners(of: passage)).isEmpty {
                        model.passage = passage
                        model.focus = passage.first
                        model.inspect = true
                        return
                    }
                }
                let items = (m["ids"] as? [String] ?? []).compactMap { model.snapshot.resolve($0) }
                if items.count == 1, let item = items.first { model.go(.entry(item.id)) }
                else if items.count > 1 {
                    let menu = NSMenu()
                    for entry in items {
                        let option = menu.addItem(withTitle: entry.kind.label + " · " + entry.title, action: #selector(openItem(_:)), keyEquivalent: "")
                        option.target = self
                        option.representedObject = entry.id
                    }
                    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                }
            case "scroll": if let y = m["y"] as? Double { UserDefaults.standard.set(y, forKey: scrollKey(path)) }
            case "link":
                if let href = m["href"] as? String {
                    if let key = MaterialLinks.key(href, from: path),
                       let archived = model.snapshot.entry(at: path)?.archivedSources[key] { model.attempt { try model.openMaterial(archived) } }
                    else { model.follow(href, from: path) }
                }
            default: break
            }
        }
    }
}
extension Workspace {
    func follow(_ href: String, from path: String) {
        guard let project, let root else { return }
        attempt {
            let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let target = parts.first.map(String.init) ?? ""
            let fragment = parts.count == 2 ? String(parts[1]).removingPercentEncoding : nil
            if target.isEmpty {
                if let fragment { go(place, fragment: fragment) }
                return
            }
            if target.hasPrefix("feynman://research?") { try followEvidence(href); return }
            if target.hasPrefix("feynman:") {
                guard let e = snapshot.resolve(String(target.dropFirst(8))) else { throw Failure("关联条目已删除或尚未同步。") }
                go(.entry(e.id), fragment: fragment); return
            }
            let isWeb = MaterialLinks.isWeb(href)
            let isLocalReader = !path.hasPrefix("library:") && !path.hasPrefix("lakehouse:")
            if let key = MaterialLinks.key(isWeb ? href : target, from: path),
               (isLocalReader || isWeb || target.hasPrefix("project:") || target.hasPrefix("library:") || target.hasPrefix("lakehouse:")),
               snapshot.entry(at: path)?.kind != .references {
                if !isWeb, let url = try? assetURL(key), Self.isMarkdown(url), fm.fileExists(atPath: url.path) {
                    let location = try documentKey(for: url)
                    if let entry = snapshot.entry(at: location) { go(.entry(entry.id), fragment: fragment) }
                    else { try openAsset(url, fragment: fragment) }
                    return
                }
                if let ref = snapshot.reference(for: key, from: path) { go(.entry(ref.id), fragment: fragment); return }
                if snapshot.unlistedMaterials.contains(key) { go(.entry(try registerMaterial(key).id), fragment: fragment); return }
            }
            if isWeb, let url = URL(string: href) { NSWorkspace.shared.open(url); return }
            if ["library:", "project:", "lakehouse:"].contains(where: target.hasPrefix) {
                let decoded = target.removingPercentEncoding ?? target
                let original = try? assetURL(target)
                let file = try original.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil } ?? assetURL(decoded)
                try openAsset(file, fragment: fragment); return
            }
            let part = String(target.prefix { $0 != "?" }).removingPercentEncoding ?? target
            guard !part.isEmpty else { return }
            let directory = try documentURL(path).deletingLastPathComponent()
            let file: URL
            if let url = URL(string: target), url.isFileURL { file = url }
            else if part.hasPrefix("/") { file = URL(fileURLWithPath: part) }
            else { file = directory.appendingPathComponent(part) }
            var resolved = file.standardizedFileURL.resolvingSymlinksInPath()
            if !fm.fileExists(atPath: resolved.path), isLocalReader {
                // Imported siblings have UUID-prefixed filenames. Match the original name only when unique.
                if path.hasPrefix("references/files/"), directory.path == resolved.deletingLastPathComponent().path {
                    let matches = try Files.list(directory).filter { candidate in
                        let name = candidate.lastPathComponent
                        return UUID(uuidString: String(name.prefix(36))) != nil && name.dropFirst(36).first == "-" &&
                               String(name.dropFirst(37)) == resolved.lastPathComponent
                    }
                    if matches.count > 1 { throw Failure("项目中有多个同名附件，请在参考资料中选择。") }
                    if let match = matches.first { resolved = match }
                }
                if !fm.fileExists(atPath: resolved.path), let old = project.info.legacyDirectory {
                    let oldBase = try Files.child(root, old)
                    let oldFile = try Files.child(oldBase, path).deletingLastPathComponent().appendingPathComponent(part).standardizedFileURL.resolvingSymlinksInPath()
                    if fm.fileExists(atPath: oldFile.path) { resolved = oldFile }
                }
            }
            let key = try documentKey(for: resolved)
            if key.hasPrefix("lakehouse:"), !path.hasPrefix("lakehouse:") { throw Failure("链接超出当前工作目录。") }
            if snapshot.deletedPaths.contains(key) { return }
            if let entry = snapshot.entry(at: key) { go(.entry(entry.id), fragment: fragment); return }
            if valid(.doc(key)) { go(.doc(key), fragment: fragment); return }
            try openAsset(resolved, fragment: fragment)
        }
    }
}
