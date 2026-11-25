import AppKit

@main struct AtlasTests {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message) }
    }

    static func legacySegment(_ title: String, business: String, competition: String? = nil, in company: ProjectAt) throws -> BusinessSegment {
        let segment = BusinessSegment(directory: StockNotes.segmentDirectory + "/" + UUID().uuidString.lowercased(), title: title)
        try fm.createDirectory(at: Files.child(company.url, segment.directory), withIntermediateDirectories: true)
        try Files.save(Files.child(company.url, segment.directory + "/name.txt"), title, expected: nil)
        try Files.save(Files.child(company.url, segment.business), business, expected: nil)
        if let competition { try Files.save(Files.child(company.url, segment.competition), competition, expected: nil) }
        return segment
    }

    @MainActor static func verifyModules(_ m: Workspace, company: ProjectAt, other: ProjectAt, topic: ProjectAt, link: StockLink) throws {
        let directoryNames = try Files.list(company.url).map(\.lastPathComponent)
        try check(Set(directoryNames) == ["project.json", "analysis", "documents", "versions", "references"], "新个股只配置个股所用目录")
        let legacyTemplate = "## 业务流程\n\n## 收入来源\n\n## 增长驱动\n"
        let unused = try legacySegment("旧版空模板", business: legacyTemplate,
            competition: "## 主要竞争对手\n\n## 产品与市场份额\n\n## 竞争优势与风险\n", in: company)
        let userBody = "已填写的增长假设\n\n![图](<配图 A.svg>)\n\n[报告](../../../documents/q1.pdf) [外部](https://example.com)\n\n`[示例](example.md)`"
        let competitionNote = "同行比较及市场份额"
        let edited = try legacySegment("数据\n授权\n数据授权（Insights）", business: userBody, competition: competitionNote, in: company)
        let otherSegment = try legacySegment("检测", business: "检测收入", in: company)
        let order = [otherSegment, edited, unused].map { String($0.directory.split(separator: "/").last!) }
        try Files.save(Files.child(company.url, StockNotes.segmentDirectory + "/order.json"), json(order), expected: nil)
        let path = StockModule.business.note!
        try Files.save(Files.child(company.url, path), "---\ntitle: 业务\n---\n原有概览", expected: nil)
        let oldMemo = try Files.child(company.url, "memo.md")
        try Files.save(oldMemo, "旧笔记", expected: nil)
        let legacyDir = try Files.child(company.url, "concepts")
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: false)
        let legacyEntry = Entry(kind: .concepts, title: "旧版概念", body: "历史资料")
        try Files.save(Files.child(company.url, legacyEntry.path), legacyEntry.encoded(), expected: nil)
        m.open(other, at: .overview)
        m.open(m.stocks.first { $0.id == company.id } ?? company, at: .overview)
        let merged = Document(try m.text(path) ?? "")
        let headings = merged.body.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        try check(headings == ["## 检测", "## 数据授权（Insights）", "## 旧版空模板"] && merged.fields["title"] == "业务", "业务顺序及原有元数据")
        let prefix = String(edited.directory.dropFirst("analysis/".count)) + "/"
        try check(merged.body.hasPrefix("原有概览") && merged.body.contains(competitionNote) && merged.body.contains("<" + prefix + "配图 A.svg>") && merged.body.contains(prefix + "../../../documents/q1.pdf"), "概览、图片、报告和竞争分析在同一篇正文")
        try check(merged.body.contains("[外部](https://example.com)") && merged.body.contains("`[示例](example.md)`") && !merged.body.contains("## 主要竞争对手"), "区分相对链接、外部链接及代码示例，略过默认模板")
        try check(try m.text(edited.business) == userBody && m.text(edited.competition) == competitionNote, "保留原始笔记")
        try check(m.snapshot.documents.contains(path) && !m.snapshot.documents.contains(edited.business) && !m.snapshot.documents.contains(edited.competition), "搜索收录合并后的单页")
        try check(!m.valid(.preliminary) && !m.valid(.group(.concepts)) && !m.valid(.doc("memo.md")) && !m.canEditNote("memo.md"), "旧专题路由隔离")
        try check(m.snapshot.resolve(legacyEntry.id) == nil && m.snapshot.topicNotes.isEmpty && !m.snapshot.indexedDocuments.contains("memo.md"), "搜索和条目扫描均忽略专题结构")
        m.go(.preliminary); m.editDoc("memo.md"); m.researchProject()
        try check(m.place == .overview && m.dialog == nil && m.inlineNote == nil && m.consoles.isEmpty, "预研与 Memo 无法从个股打开")
        let signature = Workspace.signature(company.url, stock: true)
        try Files.save(oldMemo, "保留旧笔记", expected: "旧笔记")
        try check(Workspace.signature(company.url, stock: true) == signature, "旧目录和文件不触发个股刷新")
        let ref = Entry(kind: .references, title: "公司财报", body: "补充报告")
        try m.store(ref)
        try check(m.snapshot.resolve(ref.id) != nil, "独立个股目录仍可写入引用")
        var named = company
        named.info.title = "Tempus (TEM)"; named.info.stock?.ticker = "TEM US"
        try check(named.stockDisplayName == "Tempus" && named.stockLabel == "Tempus (TEM US)", "显示名与股票代码各出现一次")
        try check(Set(StockModule.allCases.map { $0.category.cssColor }).count >= 6, "六模块使用六种专题分类色")
        let all = StockModule.allCases
        try check(m.stockModule(for: .overview) == nil && Place("home") == .overview && Place("stock:thesis") == .stock(.thesis), "公司首页与投资判断可分别访问")
        try check(m.stockBook.homeLayout == nil && StockHomeLayout().modules == all, "已有公司默认显示全部六张卡片")
        let saved = #"{"order":["business","references","earnings","updates","competition","thesis"],"heights":{"references":220}}"#
        var restored = try JSONDecoder().decode(StockHomeLayout.self, from: Data(saved.utf8))
        try check(restored.modules == all && restored.height(.references) == 220, "旧布局采用新模板章节顺序并保留高度")
        restored.move(.references, to: .updates)
        let roundTrip = try JSONDecoder().decode(StockHomeLayout.self, from: JSONEncoder().encode(restored))
        try check(roundTrip.modules.firstIndex(of: .references) == all.firstIndex(of: .updates) && roundTrip.modules == restored.modules, "升级后再次拖动可保留新的顺序")
        var layout = StockHomeLayout()
        layout.move(.references, to: .thesis)
        layout.move(.business, to: .updates)
        layout.resize(.references, height: 220)
        layout.resize(.updates, height: 1000)
        layout.resize(.earnings, height: 0)
        try check(layout.modules.first == .summary && layout.modules[1] == .references && layout.modules.count == 14 && layout.height(.updates) == 1000 && layout.height(.earnings) == 100 && layout.height(.business) == nil, "卡片双向拖动排序及尺寸边界")
        try m.modifyBook { $0.homeLayout = layout }
        m.open(other, at: .overview)
        try check(m.stockBook.homeLayout == nil, "其他公司保留自己的首页布局")
        m.open(company, at: .overview)
        try check(m.stockBook.homeLayout == layout && layout.height(.references) == 220, "重新进入公司恢复卡片顺序与高度")
        try check(all.map(\.title) == ["一页纸结论", "投资逻辑（当前版本）", "公司概况与商业模式", "业务拆分 Segments", "KPI 仪表盘", "管理层、资本配置与股东结构", "财务模型", "估值分析", "风险清单", "催化剂日历", "重大事件跟踪", "待解决问题", "决策日志", "References"], "个股侧栏名称及顺序")
        for module in all {
            m.openStockModule(module)
            try check(m.stockModule(for: m.place) == module && Place(m.place.key) == m.place, "模块导航与持久化：" + module.title)
        }
        for old in [Place("stock:competition"), .doc(edited.business), .doc("project:" + edited.competition)] {
            m.go(old)
            try check(m.place == .stock(.business) && m.currentNotePath == path, "旧入口重定向到业务拆分整页")
        }
        try m.editStockNote(path)
        try check(m.inlineNote?.text == merged.body, "整页可直接编辑")
        m.inlineNote?.text = "修订后的业务和竞争格局"
        m.openStockModule(.earnings)
        guard let growth = m.currentNotePath else { throw Failure("增长分析路径") }
        try m.editStockNote(growth)
        m.inlineNote?.text = "预测假设"
        m.openStockModule(.updates)
        guard let updates = m.currentNotePath else { throw Failure("重要更新路径") }
        try check(!m.canEditNote(updates), "重大事件通过追加入口写入")
        try Files.save(Files.child(company.url, updates), "本季重大事件", expected: nil)
        m.openStockModule(.thesis)
        m.open(other, at: .overview)
        try check(!m.snapshot.documents.contains(path) && !m.snapshot.documents.contains(growth), "不同公司独立保存")
        m.open(m.stocks.first { $0.id == company.id } ?? company, at: .overview)
        let savedPage = Document(try m.text(path) ?? "")
        try check(savedPage.body == "修订后的业务和竞争格局" && savedPage.fields["title"] == "业务", "重开后保留手工修改，旧分部不会重新追加")
        try check(try m.text(growth) == "预测假设" && m.text(updates) == "本季重大事件", "其他章节保存")
        try m.openLinkedEntity(link, in: topic)
        try check(m.project?.id == topic.id && m.place == .entry(link.entityID) && m.stockModule(for: m.place) == nil, "专题名称直接进入原实体并切回专题侧栏")
        m.navigate(.back)
        try check(m.project?.id == company.id && m.place == .overview, "原实体返回公司")
        print("PASS 十四章导航、单页业务及竞争分析迁移与编辑、增长分析与重要更新自动保存、公司隔离、实体直达")
    }

    @MainActor static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("atlas-tests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let oncology = try Files.create(root, title: "美国肿瘤检测", intent: "")
        let ai = try Files.create(root, title: "AI 制药数据", intent: "")
        let policy = Entry(kind: .events, title: "支付政策", body: "政策原文")
        var entity = Entry(kind: .entities, title: "Tempus", body: "专题内比较")
        entity.anchors = [Anchor(report: "reports/preliminary.md", quote: "检测价格")]
        entity.links = [policy.id]
        let other = Entry(kind: .entities, title: "Tempus", body: "数据业务")
        try Files.write(policy, in: oncology.url)
        try Files.write(entity, in: oncology.url)
        try Files.write(other, in: ai.url)
        let original = try Data(contentsOf: Files.child(oncology.url, entity.path))
        let originalOther = try Data(contentsOf: Files.child(ai.url, other.path))
        let m = Workspace(initialRoot: root)
        try check(m.projects.count == 2 && m.stocks.isEmpty, "旧库在没有 stocks 时可打开")
        let link = StockLink(projectID: oncology.id, entityID: entity.id)
        let second = StockLink(projectID: ai.id, entityID: other.id)
        let company = try Files.createStock(root, name: "Tempus AI", ticker: "TEM", link: link)
        try Files.updateStock(root, id: company.id, adding: second)
        let duplicateMention = Entry(kind: .entities, title: "Tempus 支付业务")
        try Files.write(duplicateMention, in: oncology.url)
        try Files.updateStock(root, id: company.id, adding: StockLink(projectID: oncology.id, entityID: duplicateMention.id))
        let natera = try Files.createStock(root, name: "Natera", ticker: "NTRA", link: nil)
        do { try Files.updateStock(root, id: natera.id, adding: link); throw Failure("不应重复绑定") }
        catch let error as Failure { try check(error.message.contains("先解除"), "跨公司重复绑定") }
        m.refreshProjects()
        func graph() -> ProjectGraphData { ProjectGraphData(projects: m.projects, stocks: m.stocks) }
        try check(graph().nodes.count == 4 && graph().edges.count == 2, "两条去重关系和一个独立节点")
        try check(!m.projects.contains(company) && m.stocks.count == 2, "专题及个股分别扫描")
        for (topic, item) in [(oncology, entity), (ai, other)] {
            m.open(topic, at: .entry(item.id))
            try check(m.stock(for: item)?.id == company.id, "跨专题打开同一家公司")
        }
        m.open(m.stocks.first { $0.id == company.id }!, at: .overview)

        try verifyModules(m, company: company, other: natera, topic: ai, link: second)

        // The test accepts two real XLSX files, or uses distinct opaque bytes for archival tests.
        let workbook = root.appendingPathComponent("Tempus-Financial-Model.xlsx")
        let arguments = Array(CommandLine.arguments.dropFirst())
        let oldBytes = arguments.count == 2 ? try Data(contentsOf: URL(fileURLWithPath: arguments[0])) : Data("Q1 formula".utf8)
        let newBytes = arguments.count == 2 ? try Data(contentsOf: URL(fileURLWithPath: arguments[1])) : Data("Q2 formula".utf8)
        try oldBytes.write(to: workbook)
        try m.importStockDocument(workbook, companyID: company.id, workbook: true)
        let main = try Files.child(company.url, m.stockBook.mainModel!)
        try check(main.path == company.url.appendingPathComponent("documents/Tempus-Financial-Model.xlsx").path, "工作簿按相对路径归档")
        let evidence = "feynman://research?project=" + oncology.id + "&target=entry:" + policy.id
        try m.startJudgment()
        try m.modifyBook {
            $0.draft?.conclusion = "检测业务改善"
            $0.draft?.reason = "首季财报"
            $0.draft?.archiveModel = true
            let eps = ForecastMetric(name: "EPS", unit: "USD/股", basis: "调整后", values: ["FY2028": "0.55"])
            $0.draft?.forecast = Forecast(years: ["FY2028"], metrics: [eps], price: "60 USD", priceDate: "2026-08-01")
        }
        let body = "支付价格假设和[政策依据](<" + evidence + ">)"
        m.inlineNote?.text = body
        m.go(.overview)
        try check(m.stockBook.history.isEmpty, "草稿不进入历史")
        let resumed = Workspace(initialRoot: root)
        resumed.open(company, at: .overview)
        try resumed.startJudgment()
        try check(resumed.inlineNote?.text == body && resumed.stockBook.draft?.reason == "首季财报", "退出后续写草稿")
        try resumed.publishJudgment()
        let first = resumed.stockBook.history[0]
        let archived = try Files.child(company.url, first.modelVersion!)
        try check(first.body == body && first.forecast.metrics[0].values["FY2028"] == "0.55", "首季正文与数字快照")
        try newBytes.write(to: main)
        resumed.refresh()
        try check(resumed.stockBook.forecast == first.forecast, "修改 Excel 不改变摘要及其日期")
        try resumed.startJudgment()
        try check(resumed.inlineNote?.text == body, "更新以已发布判断为底稿")
        try resumed.modifyBook {
            $0.draft?.conclusion = "检测业务利润承压"
            $0.draft?.reason = "支付价低于首季假设"
            $0.draft?.title = "下调检测 EPS"
            $0.draft?.forecast.metrics[0].values["FY2028"] = "0.42"
        }
        resumed.inlineNote?.text = body + "\n第二季证据"
        try resumed.publishJudgment()
        let latest = resumed.stockBook.history[0]
        let changes = latest.forecast.changes(since: first.forecast)
        try check(changes.count == 1 && ["FY2028", "调整后", "EPS", "USD/股", "0.55 → 0.42"].allSatisfy(changes[0].contains), "两次财报间预测变化含财年、口径和单位")
        try check(latest.modelVersion == nil && resumed.stockBook.history[1] == first, "普通发布不复制模型、不改上次记录")
        try check(try Data(contentsOf: main) == newBytes && Data(contentsOf: archived) == oldBytes, "日常工作簿和历史版本分别打开")
        var opened: [URL] = []
        resumed.openStockFile(resumed.stockBook.mainModel!) { opened.append($0); return true }
        resumed.openStockFile(first.modelVersion!) { opened.append($0); return true }
        try check(opened.map(\.path) == [main.path, archived.path], "打开模型操作分别交给系统当前原件及当季副本")
        resumed.stockHistorySelection[company.id] = [first.id]
        resumed.lastHistoryRecord[company.id] = first.id
        resumed.follow(evidence, from: ".history.md")
        try check(resumed.project?.id == oncology.id && resumed.place == .entry(policy.id), "判断内引用进入政策原文")
        resumed.navigate(.back)
        try check(resumed.project?.id == company.id && resumed.place == .judgments && resumed.historyScrollTarget == first.id && resumed.stockHistorySelection[company.id]?.contains(first.id) == true, "后退恢复公司主页及历史展开状态")
        try resumed.modifyBook { $0.history[1].corrections.append(JudgmentCorrection(text: "原文笔误")) }
        try Files.updateStock(root, id: company.id, identity: ("Tempus", "TEM.US"))
        let moved = company.url.deletingLastPathComponent().appendingPathComponent("Renamed Tempus")
        try fm.moveItem(at: company.url, to: moved)
        try Files.updateStock(root, id: company.id, removing: [second])
        let reopened = Workspace(initialRoot: root)
        let same = reopened.stocks.first { $0.id == company.id }!
        reopened.open(same, at: .overview)
        try check(same.url.standardizedFileURL.path == moved.standardizedFileURL.path && same.info.stock?.ticker == "TEM.US", "目录、名称、股票代码改动后保留身份")
        try check(ProjectGraphData(projects: reopened.projects, stocks: reopened.stocks).edges.count == 1, "解除一个专题后重启只移除该边")
        try check(try Data(contentsOf: Files.child(oncology.url, entity.path)) == original && Data(contentsOf: Files.child(ai.url, other.path)) == originalOther, "两份专题实体逐字节保持一致")
        try check(try Files.scan(oncology.url).related(to: entity).contains { $0.id == policy.id }, "原有关系保持")
        try check(reopened.stockBook.history.count == 2 && reopened.stockBook.history[1].corrections.count == 1 && reopened.stockBook.history[1].body == body, "更正留痕与历史记录持久化")
        print("PASS Atlas 目录、去重与孤立节点、绑定冲突、跨专题导航、草稿续写、两次发布、EPS 变化、工作簿版本、政策引用、返回历史、更正、重命名和重启")
    }
}
