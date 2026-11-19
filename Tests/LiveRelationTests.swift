import AppKit
import UniformTypeIdentifiers

private final class LinkFixture: URLProtocol {
    static let pdf: Data = {
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 72, height: 72)
        let context = CGContext(consumer: CGDataConsumer(data: bytes)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        return bytes as Data
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let isPDF = url.path == "/download"
        var headers = ["Content-Type": isPDF ? "application/octet-stream" : "text/html"]
        if isPDF { headers["Content-Disposition"] = "attachment; filename=original.pdf" }
        let data = isPDF ? Self.pdf : Data("<html><title>News</title></html>".utf8)
        let status = url.path == "/missing.pdf" ? 404 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(data.prefix(3)))
        client?.urlProtocol(self, didLoad: Data(data.dropFirst(3)))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct LiveRelationTests {
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message) }
    }

    @MainActor static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let project = try Files.create(root, title: "关系更新验证", intent: "")
        defer { UserDefaults.standard.removeObject(forKey: "last." + project.id) }
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [LinkFixture.self]
        let model = Workspace(linkConfiguration: network)
        model.open(project)

        var entity = Entry(kind: .entities, title: "公司")
        entity.aliases = ["old-company"]
        var question = Entry(kind: .questions, title: "市场多大？")
        question.aliases = ["old-question"]
        let anchor = Anchor(report: "reports/base-v1.md", quote: "软件市场")
        try anchor.quote.write(to: project.url.appendingPathComponent(anchor.report), atomically: true, encoding: .utf8)
        question.anchors = [anchor]
        question.links = ["old-company"]
        try model.store(entity)
        try model.store(question)
        model.go(.entry(entity.id))
        model.go(.doc(anchor.report), anchor: anchor)
        model.passage = [anchor]
        model.go(.entry(question.id))
        model.navigate(.first)
        try check(model.place == .overview && !model.canGoBack && model.canGoForward, "跳到历史起点")
        model.navigate(.last)
        try check(model.place == .entry(question.id) && !model.canGoForward, "跳到历史终点")
        model.navigate(.back)
        try check(model.place == .doc(anchor.report) && model.focus == anchor && model.passage == [anchor], "回退恢复原文位置")
        model.navigate(.back)
        model.navigate(.forward)
        try check(model.focus == anchor, "前进恢复引文")
        model.go(.entry(entity.id))
        try check(!model.canGoForward, "从历史中间点开链接清除前进路径")
        func neighbors(_ id: String) -> [Entry] {
            model.snapshot.resolve(id).map { model.snapshot.related(to: $0) } ?? []
        }
        try check(neighbors(entity.id).map(\.id) == [question.id], "反向关联应立即显示")
        try model.setRelation(from: entity.id, to: question.id, present: false)
        try check(neighbors(entity.id).isEmpty && neighbors(question.id).isEmpty, "从另一端解除旧编号关联")
        try model.setRelation(from: entity.id, to: question.id, present: true)
        try model.setRelation(from: question.id, to: entity.id, present: true)
        try check(neighbors(entity.id).count == 1 && neighbors(question.id).count == 1, "双方立即显示同一条关联")
        var renamed = model.snapshot.resolve(question.id)!
        renamed.title = "新版问题标题"
        // Simulate an older project that duplicated the active relationship at both ends.
        renamed.links = ["old-company", entity.id]
        try model.store(renamed)
        try check(neighbors(entity.id).first?.title == renamed.title, "改名后图中标题立即更新")
        try model.setRelation(from: question.id, to: entity.id, present: false)
        try check(neighbors(question.id).isEmpty && neighbors(entity.id).isEmpty, "移除双向重复记录")
        try model.setRelation(from: question.id, to: entity.id, present: true)
        guard var removed = model.snapshot.resolve(question.id) else { throw Failure("问题缺失") }
        var concept = Entry(kind: .concepts, title: "同处原文的概念")
        concept.anchors = [anchor]
        concept.links = [question.id]
        try model.store(concept)
        model.passage = [anchor]; model.focus = anchor
        removed.deleted = true
        try model.store(removed)
        try check(model.place == .entry(entity.id) && neighbors(entity.id).isEmpty, "当前实体页立即清除已删问题")
        let owners = model.snapshot.owners(of: model.passage)
        try check(owners.map(\.id) == [concept.id] && model.snapshot.questions(for: owners).isEmpty && model.focus == anchor,
                  "共享引文保留概念高亮，并移除已删除的问题")
        try check(!model.valid(.doc(removed.path)), "历史或旧文件路径不能重新打开已删条目")
        concept = model.snapshot.resolve(concept.id)!
        concept.deleted = true
        try model.store(concept)
        try check(model.passage.isEmpty && model.focus == nil && model.snapshot.owners(of: [anchor]).isEmpty, "自动移除最后一个高亮来源")
        try check(model.snapshot.deletedIDs.contains("old-question"), "旧编号正文链接失效")

        var external = Entry(kind: .concepts, title: "同步概念")
        external.links = [entity.id]
        try Files.write(external, in: project.url)
        model.poll() // Same callback as the open window's periodic file check.
        for _ in 0..<100 where model.refreshing { try await Task.sleep(nanoseconds: 25_000_000) }
        try check(neighbors(entity.id).map(\.id) == [external.id], "外部变更更新当前页")
        var story = Entry(kind: .references, title: "新闻", body: "[阅读全文](https://example.org/story)")
        story.links = [entity.id]
        try model.store(story)
        try check(model.snapshot.isWebReference(story) && model.snapshot.archiveSources(for: story).isEmpty, "旧新闻集中显示，不可入库")

        let filenames = ["报告.pdf", "下载的 网页.html", "有来源的笔记.md", "图片.png", "资料.json", "图.svg", "扫描件.jpg", "附件.doc", "报告.docx"]
        let urls = filenames.map { root.appendingPathComponent($0) }
        for file in urls { try Data("[来源](https://example.org/story)".utf8).write(to: file) }
        let providers = urls.map { NSItemProvider(item: $0.dataRepresentation as NSData, typeIdentifier: UTType.fileURL.identifier) }
        await model.importDroppedReferences(providers, into: project)
        let imported = model.snapshot.entries.filter { filenames.contains($0.title) }
        try check(imported.count == filenames.count && model.place == .group(.references), "一次拖入多个文件各自成为一项")
        for item in imported {
            guard let source = item.assets.first else { throw Failure("未复制原件") }
            let file = try model.assetURL(source)
            try model.openAsset(file)
            try check(model.displayedEntry?.id == item.id && model.valid(model.place), "文件链接未打开对应的只读资料页")
            try check(!model.snapshot.isWebReference(item) && model.snapshot.archiveSources(for: item) == [source], "本地资料独立展示并可入库")
            try check(fm.contentsEqual(atPath: file.path, andPath: root.appendingPathComponent(item.title).path), "原件内容应完全一致")
        }
        guard var mixed = imported.first(where: { $0.title.hasSuffix(".html") }) else { throw Failure("HTML 文件未导入") }
        mixed.body = "[来源](https://example.org/other)"
        try model.store(mixed)
        try check(!model.snapshot.isWebReference(mixed) && model.snapshot.archiveSources(for: mixed) == mixed.assets, "混合资料只对文件提供入库")
        try check(model.snapshot.reference(for: "https://example.org/story", from: entity.path)?.id == story.id, "原网页链接仍能定位")
        try check(Place(Place.webLinks.key) == .webLinks, "网页汇总页可恢复")
        let note = project.url.appendingPathComponent("references/原始 Markdown.md")
        try "# 文件笔记\n\n[引用](https://example.org/story)".write(to: note, atomically: true, encoding: .utf8)
        model.refresh()
        let standalone = model.snapshot.entry(at: "references/原始 Markdown.md")!
        try check(!model.snapshot.isWebReference(standalone) && model.snapshot.archiveSources(for: standalone) == ["project:" + standalone.path], "目录中的 Markdown 原件独立显示")
        let originalBytes = try Data(contentsOf: note)
        try model.setRelation(from: standalone.id, to: entity.id, present: true)
        try check(model.snapshot.related(to: entity).contains { $0.id == standalone.id }, "资料的反向关联未显示")
        var linkedSource = model.snapshot.resolve(standalone.id)!
        linkedSource.reportLinks.append("reports/test.md")
        try model.store(linkedSource)
        try model.setRelation(from: entity.id, to: standalone.id, present: false)
        try check(try Data(contentsOf: note) == originalBytes, "关联或解除关联改写了原始 Markdown")
        try check(model.snapshot.resolve(standalone.id)?.reportLinks == linkedSource.reportLinks, "原件的项目关联未保存")
        let url = URL(string: "https://example.org/browser")!
        let browser = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.url.identifier)
        browser.registerItem(forTypeIdentifier: "public.url-name") { reply, _, _ in reply?("浏览器提供的标题" as NSString, nil) }
        await model.importDroppedReferences([browser], into: project)
        guard let dropped = model.snapshot.reference(for: url.absoluteString, from: "") else { throw Failure("浏览器链接未保存") }
        try check(dropped.title == "浏览器提供的标题" && model.snapshot.isWebReference(dropped) && model.place == .entry(dropped.id), "以浏览器标题定位网页链接")
        let pairs = [[url.absoluteString, "https://example.org/safari"], ["重复链接", "Safari 标题"]]
        let data = try PropertyListSerialization.data(fromPropertyList: pairs, format: .binary, options: 0)
        await model.importDroppedReferences([NSItemProvider(item: data as NSData, typeIdentifier: DroppedReference.safariLinks)], into: project)
        try check(model.snapshot.reference(for: pairs[0][1], from: "")?.title == "Safari 标题" && model.place == .webLinks, "带多个标题的 Safari 拖放数据")
        try check(model.snapshot.entries.filter { $0.assets.contains(url.absoluteString) }.count == 1 && model.snapshot.resolve(dropped.id)?.title == dropped.title, "重复拖入保留原条目")
        let download = URL(string: "https://example.org/download?id=123")!
        let oldID = try Files.registerWebLink(download, title: "经典报告", in: project.url)
        let provider = NSItemProvider(item: download as NSURL, typeIdentifier: UTType.url.identifier)
        await model.importDroppedReferences([provider], into: project)
        guard let report = model.snapshot.resolve(oldID), let asset = report.downloadedPDFs[download.absoluteString] else {
            throw Failure("PDF 未沿用原链接编号")
        }
        try check(model.place == .entry(report.id) && !model.snapshot.isWebReference(report) && report.title == "经典报告", "PDF 独立显示并保留原题")
        let copied = try Data(contentsOf: model.assetURL(asset))
        try check(asset.hasSuffix("-original.pdf") && copied == LinkFixture.pdf && model.snapshot.archiveSources(for: report) == [asset], "保存原名和完整 PDF，并可入库")
        await model.importDroppedReferences([provider], into: project)
        try check(model.snapshot.resolve(oldID)?.assets == report.assets && model.snapshot.looseAssets.isEmpty, "重复拖入不产生重复附件")
        let htmlDrop = DroppedReference(url: URL(string: "https://example.org/article.pdf")!, title: "文章页面")
        let htmlID = try await htmlDrop.importLink(into: project.url, configuration: network)
        model.refresh()
        try check(model.snapshot.resolve(htmlID).map(model.snapshot.isWebReference) == true, "实际响应为 HTML 时仍是网页链接")
        let missing = DroppedReference(url: URL(string: "https://example.org/missing.pdf")!)
        let failed = try? await missing.importLink(into: project.url, configuration: network)
        try check(failed == nil && model.snapshot.reference(for: missing.url.absoluteString, from: "") == nil, "下载失败不登记空 PDF")
        let archiveFile = root.appendingPathComponent("Library/original.pdf")
        try fm.createDirectory(at: archiveFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try copied.write(to: archiveFile)
        let archive = ResearchTarget.archive(id: oldID, source: asset, localFile: try model.assetURL(asset), lakehouse: root, prefix: "library:")
        _ = try archive.save(#"{"libraryPath":"Library/original.pdf"}"#, in: project)
        await model.importDroppedReferences([provider], into: project)
        guard let archived = model.snapshot.resolve(oldID) else { throw Failure("入库后资料缺失") }
        try check(Set(archived.assets) == [download.absoluteString, "library:Library/original.pdf"] && model.snapshot.archiveSources(for: archived).isEmpty, "已入库 PDF 再次拖入应复用 Library 文件")
        print("通过：浏览器拖入 PDF、无后缀下载、逐字节核对、Library 入口、旧链接升级、去重及网页分流")
        model.root = root
        let library = root.appendingPathComponent("Library")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let mainNote = library.appendingPathComponent("资料 A.md")
        let raw = "---\ntitle: 原题\n---\n# 资料 A\n\n[继续阅读](B.md#section-two)"
        try raw.write(to: mainNote, atomically: true, encoding: .utf8)
        try "# Section Two".write(to: library.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
        let localNote = root.appendingPathComponent("本地调研.txt")
        try Data("调研记录".utf8).write(to: localNote)
        let startCount = model.snapshot.entries.filter { $0.kind == .references }.count
        let libraryMode = ReferenceFileMode.library(directory: root, prefix: "library:")
        for kind in [Kind.entities, .questions, .events, .concepts] {
            let owner = Entry(kind: kind, title: kind.label)
            try model.store(owner)
            model.go(.entry(owner.id))
            await model.importReferences([DroppedReference(url: localNote)], into: project, ownerID: owner.id)
            await model.importReferences([DroppedReference(url: mainNote)], into: project, mode: libraryMode, ownerID: owner.id)
            let refs = neighbors(owner.id)
            try check(refs.count == 2 && refs.allSatisfy { $0.kind == .references && neighbors($0.id).contains { $0.id == owner.id } },
                      "本地和库内资料均可从两端访问：" + kind.label)
            try check(model.place == .entry(owner.id) && model.notice.contains(owner.title) && model.expanded.contains(Kind.references.rawValue),
                      "保留发起页并显示关联结果")
        }
        let linked = model.snapshot.entries.filter { $0.kind == .references }
        try check(linked.count == startCount + 2, "不同条目复用相同资料")
        let localRef = linked.first { $0.title == localNote.lastPathComponent }!
        let libraryRef = linked.first { $0.title == mainNote.lastPathComponent }!
        let saved = try Files.scan(project.url)
        try check(saved.related(to: localRef).count == 4 && saved.related(to: libraryRef).count == 4, "关系持久化")
        try check(libraryRef.assets == ["library:Library/资料 A.md"] && fm.contentsEqual(atPath: try model.assetURL(localRef.assets[0]).path, andPath: localNote.path),
                  "本地文件复制成功且库内文件保留原路径")
        let previousFiles = try Files.list(project.url.appendingPathComponent("references/files"))
        await model.importReferences([DroppedReference(url: localNote)], into: project, ownerID: removed.id)
        let afterFailure = try Files.list(project.url.appendingPathComponent("references/files"))
        try check(model.error != nil && previousFiles == afterFailure, "发起条目删除后报错且不遗留副本")
        model.error = nil
        print("通过：实体、问题、事件、概念的本地与库内文件登记、复用、双向导航及失败回滚")
        model.follow("library:Library/资料%20A.md", from: "memo.md")
        try check(model.place == .doc("library:Library/资料 A.md"), "知识库内 Markdown 应在工作台打开")
        model.follow("B.md#section-two", from: "library:Library/资料 A.md")
        try check(model.place == .doc("library:Library/B.md") && model.headingFragment == "section-two", "从库内文档继续跳转")
        model.navigate(.back)
        model.editDoc("library:Library/资料 A.md")
        try check(model.inlineNote == nil && model.place == .doc("library:Library/资料 A.md"), "知识库文档允许编辑")
        try check(try model.text("library:Library/资料 A.md") == raw, "知识库文件被修改")
        let source = imported.first { $0.title.hasSuffix(".md") }!.assets[0]
        try model.openAsset(model.assetURL(source))
        try check(model.place == .doc(String(source.dropFirst(8))), "附件文件名打开渲染后的 Markdown")
        model.beginInlineNote(String(source.dropFirst(8)))
        try check(model.inlineNote == nil && model.displayedEntry?.assets.contains(source) == true, "附件须只读并保留关联上下文")
        let manualQuestion = Entry(kind: .questions, title: "手动切换状态")
        try model.store(manualQuestion)
        model.toggleQuestionStatus(manualQuestion.id)
        _ = try ResearchTarget.entry(manualQuestion).save("研究结果", in: project)
        model.refresh()
        try check(model.snapshot.resolve(manualQuestion.id)?.answered == true, "研究写回覆盖了手动状态")
        model.toggleQuestionStatus(manualQuestion.id)
        try check(try Files.scan(project.url).resolve(manualQuestion.id)?.answered == false, "再次点击没有重新打开问题")
        print("通过：浏览器标题、Safari 多链接、重复拖入、库内 Markdown 连续导航、只读保护与手动切换问题状态")
        print("通过：Finder 文件拖入、多文件独立登记、HTML 与网址区分、Markdown 原件、归档资格与旧链接")
        print("通过：即时增删关联、反向解除、旧编号、重命名、高亮清理、外部文件自动检查")
    }
}
