import AppKit

@main struct CompanyTests {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message) }
    }
    static func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-6 } ?? false }

    @MainActor static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("company-tests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let topic = try Files.create(root, title: "潮玩", intent: "")
        let entity = Entry(kind: .entities, title: "泡泡玛特")
        let topicQuestion = Entry(kind: .questions, title: "海外 IP 生命周期", body: "初步回答")
        try Files.write(entity, in: topic.url)
        try Files.write(topicQuestion, in: topic.url)
        let created = try Files.createStock(root, name: "泡泡玛特", ticker: "9992.hk", link: StockLink(projectID: topic.id, entityID: entity.id), intent: "海外收入连续超预期")
        try check(created.info.intent == "海外收入连续超预期" && created.info.stock?.ticker == "9992.HK", "研究缘起与代码写入 project.json")
        let m = Workspace(initialRoot: root)
        let company = m.stocks.first { $0.id == created.id }!
        m.open(company, at: .overview)
        try check(m.isCompany && m.valid(.company(.scenarios)) && !m.valid(.group(.entities)) && m.cruxes.isEmpty, "个股项目打开为看板")

        // AI-written candidates use the skill's field names.
        func question(_ id: String, _ title: String, extra: String = "") -> String {
            "---\nid: \"\(id)\"\ntitle: \"\(title)\"\norigin: \"预研提取\"\nrole: \"crux\"\ncandidate: true\n" + extra +
            "links: []\nanchors: []\n---\n## 当前结论\n\n正文 \(id)\n"
        }
        try Files.save(Files.child(company.url, "questions/crux-overseas.md"), question("crux-overseas", "海外店效能否维持", extra:
            "market_view: \"反向 DCF 隐含海外收入 5 年复合 35%\"\nimpact: \"每低 10 个百分点，目标价约下调 15%\"\nevidence: \"medium\"\ntracking: \"海外单店月销\"\n"), expected: nil)
        try Files.save(Files.child(company.url, "questions/crux-cost.md"), question("crux-cost", "原材料成本能否下降"), expected: nil)
        m.refresh()
        try check(m.candidateCruxes.map(\.id) == ["crux-cost", "crux-overseas"] && m.cruxes.isEmpty, "候选关键问题按标题排列")
        let overseas = m.snapshot.resolve("crux-overseas")!
        try check(overseas.role == "crux" && overseas.candidate && overseas.marketView.contains("35%") && overseas.evidence == "medium" && overseas.tracking == "海外单店月销", "AI 起草的字段可读")
        m.confirmCrux("crux-overseas")
        m.dismissCrux("crux-cost")
        try check(m.error == nil && m.cruxes.map(\.id) == ["crux-overseas"] && m.candidateCruxes.isEmpty && m.dismissedCruxes.map(\.id) == ["crux-cost"], "采纳与删除候选")
        let accepted = Document(try m.text("questions/crux-overseas.md")!)
        try check(accepted.fields["candidate"] == nil && accepted.body.contains("正文 crux-overseas") && accepted.fields["market_view"] != nil, "采纳只移除候选标记")
        try check(Document(try m.text("questions/crux-cost.md")!).fields["deleted"] == "true", "删除的问题保留记录")

        try m.updateEntry("crux-overseas") {
            $0.myView = "海外店效会从高位回落"; $0.kill = "连续两季海外同店增长高于 20%"
        }
        let crux = m.snapshot.resolve("crux-overseas")!
        let reread = Entry(kind: .questions, path: crux.path, raw: try m.text(crux.path)!)
        try check(reread.myView == "海外店效会从高位回落" && reread.kill.contains("20%") && reread.marketView.contains("35%"), "用户判断与 AI 字段同存")
        let topicRaw = try Files.contents(Files.child(topic.url, topicQuestion.path))!
        try check(!topicRaw.contains("role:") && !topicRaw.contains("market_view") && !topicRaw.contains("depends"), "专题条目不写个股字段")

        m.newSubQuestion(of: crux)
        guard case .editor(let editor)? = m.dialog, var sub = editor.entry else { throw Failure("子问题编辑框") }
        try check(sub.role == "sub" && sub.parent == crux.id && sub.links == [crux.id], "子问题带上级与关联")
        sub.title = "日本门店的复购"
        try m.store(sub)
        m.dialog = nil
        try check(m.subQuestions(of: crux).map(\.title) == ["日本门店的复购"] && !m.cruxes.contains { $0.id == sub.id }, "子问题归属关键问题")

        // Industry dependency and review prompt.
        try m.addDependency(to: crux.id, topic: topic, entry: topicQuestion)
        try check(m.company.dependencies[crux.id]?.first?.status == .current && m.company.changedDependencies == 0, "新引用的依据为最新")
        var revised = try Files.scan(topic.url).resolve(topicQuestion.id)!
        revised.body = "专题中的新回答"
        try Files.write(revised, in: topic.url)
        m.refresh()
        let changed = m.company.dependencies[crux.id]!.first!
        try check(changed.status == .changed && m.company.changedDependencies == 1 && changed.topic == "潮玩", "专题回答更新后看板提示复核")
        try m.acknowledge(changed, for: crux.id)
        try check(m.company.dependencies[crux.id]?.first?.status == .current, "核对后清除提示")

        // Submit an industry finding to the topic.
        let submitted = try m.submitToTopic(m.snapshot.resolve(sub.id)!, topic: topic, title: "日本潮玩渠道")
        let written = try Files.scan(topic.url).resolve(submitted.id)!
        try check(written.title == "日本潮玩渠道" && written.origin == "个股提交" && written.body.contains("feynman://research") && written.role.isEmpty, "提交到专题并附回链")
        try check(m.snapshot.resolve(sub.id)!.depends.contains { $0.entry == submitted.id } && m.company.dependencies[sub.id]?.first?.status == .current, "提交后本问题自动引用")

        // Lenient snapshot and checklist files.
        let snapshotJSON = #"{"asOf":"2026-11-26","source":"Wind","price":{"value":182.4,"date":"2026-11-25","currency":"HKD"},"valuation":[{"name":"PE（NTM）","value":"24x","percentile":"35% 分位"}],"implied":[{"name":"隐含增速","value":0.18}],"narrative":["海外是主线"],"quarterly":{"periods":["Q1","Q2"],"rows":[{"name":"收入","values":[10,12.5]}]}}"#
        try Files.save(Files.child(company.url, "snapshot.json"), snapshotJSON, expected: try m.text("snapshot.json"))
        let checklistJSON = #"{"updated":"2026-11-26","items":[{"id":"pledge","group":"股东行为","title":"大股东质押","status":"ok","finding":"无质押"},{"id":"rev-cash","group":"会计质量","title":"收入与现金流背离","status":"flag","finding":"应收增速高于收入","evidence":[{"title":"中报","url":"https://example.com/r.pdf"}]},{"id":"vie","title":"VIE","status":"weird"}]}"#
        try Files.save(Files.child(company.url, "checklist.json"), checklistJSON, expected: nil)
        m.refresh()
        let snapshot = m.company.snapshot
        try check(snapshot?.priceLine == "股价 182.4 HKD（2026-11-25）" && snapshot?.implied?.first?.value.text == "0.18" &&
                  snapshot?.quarterly?.rows?.first?.values?.map(\.text) == ["10", "12.5"] && snapshot?.stamp == "截至 2026-11-26 · Wind", "快照数字与字符串兼容")
        let items = m.company.checklist?.items ?? []
        try check(items.map(\.state) == [.ok, .flag, .unchecked] && m.company.checklistIssue == nil, "排雷状态，未知值按未核查")
        let flag = items[1]
        try check(m.flagQuestion(for: flag) == nil, "异常项尚未升级")
        try m.createFlagQuestion(flag)
        let flagQuestion = m.flagQuestion(for: flag)
        try check(flagQuestion?.role == "flag" && flagQuestion?.check == "rev-cash" && flagQuestion?.body.contains("https://example.com/r.pdf") == true &&
                  m.place == .entry(flagQuestion!.id) && m.flagQuestions.count == 1, "异常项升级为排雷问题")
        try Files.save(Files.child(company.url, "snapshot.json"), "{\"asOf\": [", expected: snapshotJSON)
        m.refresh()
        try check(m.company.snapshot == nil && m.company.snapshotIssue?.contains("snapshot.json") == true, "快照格式错误时提示，不中断")

        // Timeline.
        let event = "---\nid: \"event-q3\"\ntitle: \"三季度经营公告\"\norigin: \"预研提取\"\ndate: \"2026-10-21\"\nsource: \"https://example.com/q3\"\nimpacts: [{\"question\":\"crux-overseas\",\"direction\":\"weaken\",\"note\":\"海外同店增长 45%\"}]\n---\n海外收入同比增长 1.5 倍。\n"
        try Files.save(Files.child(company.url, "events/event-q3.md"), event, expected: nil)
        try Files.save(Files.child(company.url, "events/event-q2.md"), "---\nid: \"event-q2\"\ntitle: \"中期业绩\"\ndate: \"2026-08-20\"\n---\n", expected: nil)
        m.refresh()
        try check(m.timeline.map(\.id) == ["event-q3", "event-q2"], "时间线按日期倒序")
        let impacts = m.events(affecting: crux)
        try check(impacts.count == 1 && impacts[0].1.direction == "weaken" && impacts[0].1.note.contains("45%"), "事件标明影响的问题与方向")
        m.newEvent(affecting: crux)
        guard case .editor(let eventEditor)? = m.dialog, let draftEvent = eventEditor.entry else { throw Failure("事件编辑框") }
        try check(draftEvent.kind == .events && draftEvent.impacts.first?.question == crux.id && draftEvent.date.count == 10, "从问题记录事件")
        m.dialog = nil

        // Scenario valuation.
        var book = ScenarioBook()
        book.price = "100"; book.shares = "10"; book.netCash = "50"; book.unit = "港元/股"
        var bull = Scenario(name: "乐观"); bull.probability = "30%"; bull.revenue = "200"; bull.margin = "25"; bull.multiple = "30x"; bull.answers = [crux.id: CruxAnswer.no.rawValue]
        var base = Scenario(name: "基准"); base.probability = "50"; base.method = ValuationMethod.evSales.rawValue; base.revenue = "200"; base.multiple = "4"
        var bear = Scenario(name: "悲观"); bear.probability = "20"; bear.method = ValuationMethod.evEbit.rawValue; bear.revenue = "150"; bear.margin = "10"; bear.multiple = "10"
        book.scenarios = [bull, base, bear]
        try check(close(book.value(bull).perShare, 150) && close(book.value(bull).upside, 0.5), "PE：收入 × 净利率 × 倍数 ÷ 股本")
        try check(close(book.value(base).perShare, 85) && close(book.value(bear).perShare, 20), "EV 方法加净现金")
        try check(close(book.weighted?.target, 91.5) && close(book.weighted?.upside, -0.085) && close(book.weighted?.probability, 100), "概率加权价值")
        var incomplete = book; incomplete.shares = ""
        try check(incomplete.value(bull).missing == ["股本"] && incomplete.weighted == nil, "缺少股本时不计算")
        var discounted = book; discounted.discountRate = "10"; discounted.years = "2"
        try check(close(discounted.value(bull).present, 150 / 1.21), "按年数折现")
        try m.saveScenarios(book)
        let reopened = Workspace(initialRoot: root)
        reopened.open(reopened.stocks.first { $0.id == company.id }!, at: .company(.scenarios))
        try check(reopened.company.scenarios == book && reopened.place == .company(.scenarios), "情景估值保存并恢复")
        try Files.save(Files.child(company.url, "scenarios.json"), "{\"price\": 100, \"scenarios\": [{\"name\": \"AI\", \"probability\": 40, \"revenue\": 10, \"multiple\": 2, \"method\": \"evSales\"}]}", expected: m.company.scenariosRaw)
        do { try m.saveScenarios(book); throw Failure("应拒绝覆盖外部修改") }
        catch let error as Failure { try check(error.message.contains("其他位置修改"), "外部修改后不覆盖情景") }
        m.refresh()
        try check(m.company.scenarios.price == "100" && m.company.scenarios.scenarios.first?.probability == "40" && m.company.scenarios.scenarios.first?.answers == [:], "数字写成的情景也可读取")
        try m.saveScenarios(book)

        // Judgment draft built from the user's own fields, publication records direction and scenarios.
        try m.startJudgment()
        let outline = m.inlineNote?.text ?? ""
        try check(outline.contains("海外店效会从高位回落") && outline.contains("反向 DCF") && outline.contains("| 乐观 | 30%") &&
                  outline.contains("海外店效能否维持：不成立") && outline.contains("连续两季海外同店增长高于 20%"), "首次判断草稿汇集看板与情景")
        try m.modifyBook {
            $0.draft?.title = "首次判断"; $0.draft?.conclusion = "海外增长已被充分定价"; $0.draft?.reason = "开题"; $0.draft?.direction = JudgmentDirection.watch.rawValue
        }
        try m.publishJudgment()
        let latest = m.stockBook.history[0]
        try check(latest.direction == "watch" && latest.scenarios == book && latest.body.contains("海外店效会从高位回落"), "发布判断保存方向与情景")
        try m.startJudgment()
        try check(m.inlineNote?.text == latest.body && m.stockBook.draft?.direction == "watch", "更新判断以上次发布为底稿")
        m.inlineNote?.text = "新的正文"
        try m.appendThesisOutline()
        try check(m.inlineNote?.text.hasPrefix("新的正文") == true && m.inlineNote?.text.contains("## 与市场的分歧") == true, "插入关键问题与情景摘要")

        // Prompts handed to the research terminal.
        let cruxPrompt = Terminal.companyPrompt(.cruxes, company: company, root: root, workspace: m, note: "挑战第一个问题")
        try check(cruxPrompt.contains("$sling-company-study") && cruxPrompt.contains("~/.claude/skills/sling-company-study/SKILL.md") &&
                  cruxPrompt.contains("海外店效能否维持") && cruxPrompt.contains("原材料成本能否下降") && cruxPrompt.contains("挑战第一个问题") &&
                  cruxPrompt.contains("Feynman/stocks/") && cruxPrompt.contains("海外收入连续超预期") && cruxPrompt.contains("潮玩"), "补充关键问题的提示词")
        let thesisPrompt = Terminal.companyPrompt(.thesis, company: company, root: root, workspace: m)
        try check(thesisPrompt.contains("首次判断") && thesisPrompt.contains(latest.id.uuidString), "同步命题的提示词指向最新判断")
        try check(Terminal.skill(.company) == "sling-company-study" && Terminal.skill(.preflight) == "sling-thematic-study", "个股与专题使用各自的 skill")
        let args = ResearchProvider.claude.arguments(action: .company, root: root, project: company.url, batch: false)
        try check(args == ["--add-dir", root.path] && Terminal.arguments(project: company.url, root: root, action: .company).contains("--add-dir"), "个股终端可读写知识库")
        try Files.save(Files.child(company.url, "lakehouse.json"), "{\"thesis\":\"Theses/popmart-thesis.md\",\"synced\":\"2026-11-26\",\"judgment\":\"other\"}", expected: nil)
        m.refresh()
        try check(m.company.lakehouse?.thesis == "Theses/popmart-thesis.md" && m.lakehouseKey("Theses/a.md").hasSuffix("Theses/a.md"), "读取同步目标")

        // Category tags name the company pages, not borrowed topic kinds.
        try check(CompanyPage.scenarios.category.label == "Scenarios" && CompanyPage.snapshot.category.label == "Snapshot" &&
                  CompanyPage.checklist.category.label == "Red Flags" && m.companyAccent(for: .judgments)?.label == "Judgment", "页面分类标签")

        // A batch run with a stand-in Claude CLI writes files in the company folder and reports them.
        try await verifyRun(m, company: company, root: root)

        // The topic side sees only a summary.
        let summary = CompanySummary.load(company)
        try check(summary.latest?.conclusion == "海外增长已被充分定价" && summary.cruxes.map(\.id) == ["crux-overseas"], "专题实体页的个股摘要")
        m.open(topic, at: .entry(entity.id))
        try check(m.stock(for: entity)?.id == company.id && m.companyAccent(for: m.place) == nil, "专题实体关联个股")
        print("PASS 页面分类、批量运行、候选问题采纳与删除记录、用户字段、子问题、行业依据复核、提交到专题、快照与排雷容错、排雷升级、时间线、情景估值、判断草稿与发布、终端提示词、专题摘要")
    }
    @MainActor static func verifyRun(_ m: Workspace, company: ProjectAt, root: URL) async throws {
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("claude")
        let script = """
        #!/bin/zsh
        print -r -- "$@" > "\(bin.path)/args.txt"
        input=$(cat)
        print -r -- "$input" > "\(bin.path)/prompt.txt"
        if [[ "$input" == *刷新快照* ]]; then
          print -r -- '{"asOf":"2026-11-27","source":"测试"}' > snapshot.json
          print -r -- '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"'$PWD'/snapshot.json"}}]}}'
          print -r -- '{"type":"result","result":"已刷新快照","is_error":false}'
        else
          print -r -- '{"type":"result","result":"```json\\n{\\"edits\\":[],\\"answer\\":\\"渠道库存健康，周转 45 天\\"}\\n```","is_error":false}'
        fi
        """
        try Data(script.utf8).write(to: cli)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        UserDefaults.standard.set(ResearchProvider.claude.rawValue, forKey: "researchProvider")
        UserDefaults.standard.set(cli.path, forKey: ResearchProvider.claude.pathKey)
        defer {
            UserDefaults.standard.removeObject(forKey: "researchProvider")
            UserDefaults.standard.removeObject(forKey: ResearchProvider.claude.pathKey)
        }
        func wait(_ run: AIRun) async throws {
            for _ in 0..<150 where run.running { try await Task.sleep(for: .milliseconds(100)) }
        }
        m.open(company, at: .overview)
        m.launchCompany(.snapshot)
        guard case .aiRun(let id)? = m.dialog, let run = m.aiRun, run.id == id else { throw Failure("运行前未弹出提示词框") }
        try check(run.phase == .draft && run.provider == .claude && run.prompt.contains("刷新快照") && m.consoles.isEmpty, "先弹出可编辑的提示词，不打开终端")
        run.prompt += "\n补充：只更新估值。"
        run.start()
        try await wait(run)
        try check(run.phase == .finished, "批量运行完成：" + run.status)
        try check(run.reply == "已刷新快照" && run.changed == ["snapshot.json"] && run.activity.last == "写入 snapshot.json" && run.warnings.isEmpty, "回复、改动文件与过程")
        try check(m.company.snapshot?.asOf.text == "2026-11-27" && run.destination == .company(.snapshot), "结果写入快照页")
        var args = try String(contentsOf: bin.appendingPathComponent("args.txt"), encoding: .utf8)
        let prompt = try String(contentsOf: bin.appendingPathComponent("prompt.txt"), encoding: .utf8)
        try check(args.hasPrefix("-p ") && args.contains("Edit(./**)") && args.contains("--add-dir") && !args.contains("Theses"), "使用 claude -p，只能写公司目录")
        try check(prompt.contains("只更新估值") && prompt.contains("非交互"), "使用修改后的提示词")
        m.aiRun = nil; m.dialog = nil

        // Question research also runs from the dialog; the answer goes into the question and its history.
        let question = Entry(kind: .questions, title: "渠道库存是否健康")
        try m.store(question)
        m.launch(.question, context: question.path)
        guard case .aiRun(let qid)? = m.dialog, let ask = m.aiRun, ask.id == qid else { throw Failure("问题研究未弹出提示词框") }
        try check(!ask.followUp && ask.prompt.contains("渠道库存是否健康") && ask.scope == .none && m.consoles.isEmpty, "问题研究先编辑提示词")
        ask.start()
        try await wait(ask)
        let answered = m.snapshot.resolve(question.id)
        try check(ask.phase == .finished && answered?.body.contains("周转 45 天") == true && answered?.questionHistory.first?.question == "渠道库存是否健康" &&
                  ask.reply == "渠道库存健康，周转 45 天" && ask.destination == .entry(question.id), "回答写入问题与追问记录：" + ask.status)
        args = try String(contentsOf: bin.appendingPathComponent("args.txt"), encoding: .utf8)
        try check(!args.contains("Edit(") && !args.contains(",Write"), "问题研究只读，由工作台保存")
        m.aiRun = nil; m.dialog = nil
        m.launch(.question, context: question.path)
        try check(m.aiRun?.followUp == true && m.aiRun?.prompt.isEmpty == true, "已有回答的问题进入追问")
        m.aiRun = nil; m.dialog = nil

        let thesis = AIRun.arguments(.claude, scope: .theses, directory: company.url, root: root, answer: bin).joined(separator: " ")
        try check(thesis.contains("/Theses/**") && thesis.contains("lh_refresh_ai_index"), "同步命题可写 Theses 并刷新索引")
        let codex = AIRun.arguments(.codex, scope: .project, directory: company.url, root: root, answer: bin)
        try check(codex.contains("workspace-write") && !codex.contains("--add-dir") && codex.last == "-", "Codex 只写公司目录")
        let readOnly = AIRun.arguments(.codex, scope: .none, directory: company.url, root: root, answer: bin, schema: bin)
        try check(readOnly.contains("read-only") && readOnly.contains("--output-schema"), "Codex 问题研究只读并按格式回答")
        try check(AIRun.unfenced("```json\n{\"a\":1}\n```") == "{\"a\":1}", "去掉代码围栏")
    }
}
