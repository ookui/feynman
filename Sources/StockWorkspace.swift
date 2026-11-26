import AppKit

extension Workspace {
    func stock(for entity: Entry) -> ProjectAt? {
        guard let project else { return nil }
        let ids = Set([entity.id] + entity.aliases)
        return stocks.first { company in
            company.info.stock?.links.contains { $0.projectID == project.id && ids.contains($0.entityID) } == true
        }
    }

    func modifyBook(_ change: (inout StockBook) throws -> Void) throws {
        guard let company = project, company.info.stock != nil else { throw Failure("请先打开个股主页。") }
        var book = stockBook
        try change(&book)
        let raw = try StockFiles.save(book, in: company, expected: stockBookOriginal)
        stockBookOriginal = raw
        stockBook = book
    }

    func startJudgment() throws {
        guard let company = project else { return }
        if stockBook.draft == nil {
            var draft = JudgmentDraft()
            let latest = stockBook.history.first
            draft.title = latest == nil ? "首次判断" : ""
            draft.conclusion = latest?.conclusion ?? ""
            draft.direction = latest?.direction
            draft.forecast = stockBook.forecast
            let file = try Files.child(company.url, draft.path)
            try Files.save(file, latest?.body ?? thesisOutline(), expected: nil)
            do { try modifyBook { $0.draft = draft } }
            catch { try? fm.removeItem(at: file); throw error }
        }
        go(.judgmentEditor)
        if let draft = stockBook.draft { beginInlineNote(draft.path, mode: .rich) }
    }

    func publishJudgment() throws {
        guard let company = project, finishInlineNote(), let draft = stockBook.draft else { throw Failure("请先完成草稿保存。") }
        guard !draft.conclusion.clean.isEmpty, !draft.title.clean.isEmpty, !draft.reason.clean.isEmpty else {
            throw Failure("请填写判断标题、一句话结论和本次原因。")
        }
        let file = try Files.child(company.url, draft.path)
        guard let body = try Files.contents(file) else { throw Failure("找不到判断草稿。") }
        var forecast = try draft.forecast.validated()
        if forecast != stockBook.forecast { forecast.updated = Date() }
        var version: String?
        if draft.archiveModel {
            guard let main = stockBook.mainModel else { throw Failure("请先指定主模型。") }
            let source = try Files.child(company.url, main)
            let relative = "versions/" + UUID().uuidString + "-" + source.lastPathComponent
            let dest = try Files.child(company.url, relative)
            var coordination: NSError?, failure: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordination) { url in
                do { try fm.copyItem(at: url, to: dest) } catch { failure = error }
            }
            if let failure = failure ?? coordination { throw failure }
            version = relative
        }
        let scenarios = self.company.scenarios.scenarios.isEmpty ? nil : self.company.scenarios
        let record = Judgment(id: draft.id, date: Date(), title: draft.title.clean, conclusion: draft.conclusion.clean,
                              reason: draft.reason.clean, body: body, forecast: forecast, modelVersion: version,
                              direction: draft.direction?.nilIfEmpty, scenarios: scenarios)
        do {
            try modifyBook { book in
                book.history.insert(record, at: 0)
                book.forecast = forecast
                book.draft = nil
            }
        } catch {
            if let version, let url = try? Files.child(company.url, version) { try? fm.removeItem(at: url) }
            throw error
        }
        try? fm.removeItem(at: file)
        stockHistoryYear[company.id] = nil
        go(.judgments)
    }

    /// Appends the current board and scenarios to the draft, for drafts started before they were filled in.
    func appendThesisOutline() throws {
        guard let company = project, let draft = stockBook.draft, finishInlineNote() else { throw Failure("请先完成草稿保存。") }
        let file = try Files.child(company.url, draft.path)
        let old = try Files.contents(file) ?? ""
        let text = old.clean.isEmpty ? thesisOutline() : old + (old.hasSuffix("\n") ? "\n" : "\n\n") + thesisOutline()
        try Files.save(file, text, expected: old.isEmpty && !fm.fileExists(atPath: file.path) ? nil : old)
        revision += 1
        beginInlineNote(draft.path, mode: .rich)
    }

    func openLinkedEntity(_ link: StockLink, in topic: ProjectAt) throws {
        guard link.projectID == topic.id, project?.info.stock?.links.contains(link) == true,
              let entity = try Files.scan(topic.url).resolve(link.entityID), entity.kind == .entities else {
            throw Failure("找不到这个专题关联的公司实体。")
        }
        open(topic, at: .entry(entity.id))
    }

    func importStockDocument(_ url: URL, companyID: String, workbook: Bool) throws {
        guard let company = project, company.id == companyID else { throw Failure("公司页面已变更。") }
        if workbook && !StockFiles.workbookTypes.contains(url.pathExtension.lowercased()) { throw Failure("请选择 Excel 工作簿。") }
        let path = try StockFiles.copyDocument(url, to: company)
        if StockFiles.workbookTypes.contains(url.pathExtension.lowercased()), stockBook.mainModel == nil {
            try modifyBook { $0.mainModel = path }
        }
        revision += 1
    }

    func openStockFile(_ path: String, using launch: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        attempt {
            guard let company = project else { return }
            let url = try Files.child(company.url, path)
            guard fm.fileExists(atPath: url.path), launch(url) else { throw Failure("无法打开文件：" + url.lastPathComponent) }
        }
    }

    func copyEvidence(_ title: String, target: String) {
        guard let project else { return }
        var components = URLComponents()
        components.scheme = "feynman"
        components.host = "research"
        components.queryItems = [URLQueryItem(name: "project", value: project.id), URLQueryItem(name: "target", value: target)]
        components.fragment = headingFragment
        guard let url = components.url else { return }
        let safeTitle = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "]", with: "\\]")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[\(safeTitle)](<\(url.absoluteString)>)", forType: .string)
        notice = "已复制研究链接"
    }

    func followEvidence(_ href: String) throws {
        guard let url = URLComponents(string: href), url.host == "research",
              let id = url.queryItems?.first(where: { $0.name == "project" })?.value,
              let target = url.queryItems?.first(where: { $0.name == "target" })?.value,
              let owner = (projects + stocks).first(where: { $0.id == id }) else { throw Failure("找不到链接对应的研究项目。") }
        if target.hasPrefix("file:documents/"), owner.info.stock != nil {
            let url = try Files.child(owner.url, String(target.dropFirst(5)))
            guard fm.fileExists(atPath: url.path), NSWorkspace.shared.open(url) else { throw Failure("无法打开公司文档。") }
            return
        }
        let dest = Place(target)
        if case .entry(let id) = dest {
            guard try Files.scan(owner.url).resolve(id) != nil else { throw Failure("研究条目已移走。") }
        }
        open(owner, at: dest, fragment: url.fragment)
    }
}
