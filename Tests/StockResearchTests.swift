import AppKit

@main struct StockResearchTests {
    @MainActor static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("stock-research-test-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let company = try Files.createStock(root, name: "Fixture Corp", ticker: "FX", link: nil)
        let other = try Files.createStock(root, name: "Other Corp", ticker: "OT", link: nil)
        let model = Workspace(initialRoot: root)
        model.open(company, at: .overview)
        let cli = root.appendingPathComponent("fixture-cli")
        let script = #"""
        #!/usr/bin/python3
        import sys, json, pathlib, re, time
        prompt = sys.stdin.read()
        assert 'Fixture Corp' in prompt and '用户附加条件' in prompt
        if '研究范围：全公司深研' in prompt:
            headings = re.findall(r'^## (.+?) 〔.+?〕$', prompt, re.M)
            files = re.findall(r'^.+? → (.+?\.md)$', prompt, re.M)
            assert len(headings) == len(files) == 14
            bodies = ['研究结果 analysis/' + file for file in files]
            bodies[0] += '\n\n![图][chart]\n'
            bodies[3] += '\n\n![动图](assets/demo.gif)\n\n| FY | EPS |\n|---|---:|\n| 2027 | 1 |\n\n' + chr(96)*3 + 'markdown\n## 4. KPI 仪表盘\n' + chr(96)*3
            bodies[13] += '\n\n[chart]: <assets/图 1.svg> "图例"'
            text = '# 公司研究\n\n' + '\n\n'.join('## ' + heading + '\n\n' + body for heading, body in zip(headings,bodies))
            if '截断测试' not in prompt: text += '\n\n<!-- feynman-report-end -->'
            path = '全文'
        else:
            path = re.search(r'（(analysis/[^）]+\.md)）', prompt.split('本次写入第「')[-1]).group(1)
            text = '研究结果 ' + path
        with pathlib.Path(__file__).with_name('sent-sections.txt').open('a') as sent:
            sent.write(path + '\n')
        def send(obj): print(json.dumps(obj, ensure_ascii=False), flush=True)
        if '--json' in sys.argv:
            send({'item':{'type':'agent_message','text':text}, 'type':'item.completed'})
            if '等待测试' in prompt: time.sleep(1)
            pathlib.Path(sys.argv[sys.argv.index('--output-last-message')+1]).write_text(text)
        elif '--include-partial-messages' in sys.argv:
            send({'type':'stream_event','event':{'delta':{'type':'text_delta','text':text}}})
            send({'type':'result','result':text})
        else:
            send({'type':'message','role':'assistant','delta':True,'content':text})
            send({'type':'result','status':'success'})
        """#
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let prefs = UserDefaults.standard
        let original = prefs.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { prefs.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        func use(_ provider: ResearchProvider) {
            prefs.setVolatileDomain(original.merging(["researchProvider":provider.rawValue, provider.pathKey:cli.path]) { _, v in v }, forName: UserDefaults.argumentDomain)
        }
        func check(_ value: Bool, _ name: String) throws { if !value { throw Failure(name) } }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<1600 { if condition() { return }; try await Task.sleep(for: .milliseconds(50)) }
            throw Failure("等待研究输出超时：" + (model.stockRun?.status ?? ""))
        }

        use(.codex)
        let originalLog = "既有记录（包含历史价格）\n"
        for module in [StockModule.decisions, .updates] { try Files.save(Files.child(company.url, module.note!), originalLog, expected: nil) }
        model.prepareStockResearch(nil)
        let job = model.stockRun!
        try check(job.current == .summary && job.modules == StockModule.allCases, "全文研究弹窗应从第 0 章开始，按模板顺序列出章节")
        try check(job.modules.count == 14 && !job.running && model.consoles.isEmpty, "全公司弹窗应等待用户确认")
        for chapter in StockModule.allCases { try check(job.prompt.contains(chapter.template), "全模板缺少 " + chapter.title) }
        job.prompt += "\n用户附加条件 等待测试"
        job.start()
        try await wait { !job.preview.isEmpty }
        try check(job.liveText(module: .business, original: "")?.contains("![动图]") == true &&
                  job.liveText(module: .summary, original: "")?.contains("![动图]") == false, "流式预览按章显示")
        try await wait { !job.running }
        try check(job.completed == 14 && model.consoles.isEmpty, job.status)
        let sent = try String(contentsOf: root.appendingPathComponent("sent-sections.txt"), encoding: .utf8)
        try check(sent == "全文\n", "全文应只发送一次")
        for chapter in StockModule.allCases {
            let path = chapter.note!
            let raw = try Files.contents(Files.child(company.url,path)) ?? ""
            try check(raw.contains("研究结果 " + path), "写错章节 " + path)
            if chapter.appendOnly { try check(raw.hasPrefix(originalLog), "覆盖了历史记录") }
            try check(try Files.contents(Files.child(other.url,path)) == nil, "写错公司 " + path)
        }
        let originalReport = try String(contentsOf: job.reportFile!, encoding: .utf8)
        try check(originalReport == job.preview, "可取回逐字相同的完整报告")
        let parser = try StockReportParser()
        let parsed = try parser.sections(originalReport, final: true)
        try check(parsed[.summary]!.contains("![图][chart]") && parsed[.summary]!.contains("[chart]: <assets/图 1.svg>"), "跨章节引用图定义")
        let rich = "<svg><animate attributeName=\"opacity\" values=\"1;0;1\"/></svg>\n\n<video controls src=\"assets/demo.mp4\"></video>\n\n<table><tr><td rowspan=\"2\">公司</td></tr></table>\n"
        let testReport = originalReport.replacingOccurrences(of: "研究结果 analysis/business.md", with: rich)
        let richBody = try parser.sections(testReport, final: true)[.business]!
        try check(richBody.contains(rich) && richBody.contains("![动图](assets/demo.gif)") && richBody.contains("|---|---:|") && richBody.contains("## 4. KPI 仪表盘"), "原文保留 SVG、视频、表格、GIF 和代码内的同名标题")
        let crlf = testReport.replacingOccurrences(of: "\n", with: "\r\n")
        try check(try parser.sections(crlf, final: true)[.business] == richBody.replacingOccurrences(of: "\n", with: "\r\n"), "保留原始换行")
        let filesBefore = try StockModule.allCases.map { try model.text($0.note!) }
        for invalid in [originalReport.replacingOccurrences(of: "## 3. 业务拆分 Segments", with: "## 4. KPI 仪表盘"),
                        originalReport.replacingOccurrences(of: "## 2. 公司概况与商业模式", with: "### 无章节")] {
            do { _ = try parser.sections(invalid, final: true); throw Failure("意外接受错误标题") }
            catch let e as Failure { try check(e.message != "意外接受错误标题", "重复、缺失或乱序的章节应报错") }
        }
        model.prepareStockResearch(nil)
        let incomplete = model.stockRun!
        incomplete.prompt += "\n用户附加条件 截断测试"
        incomplete.start()
        try await wait { !incomplete.running }
        try check(incomplete.completed == 0 && incomplete.reportFile != nil &&
                  (try StockModule.allCases.map { try model.text($0.note!) }) == filesBefore, "不完整报告保留原稿，所有章节均不覆盖")
        model.prepareStockResearch(nil)
        let fullConflict = model.stockRun!
        fullConflict.prompt += "\n用户附加条件 等待测试"
        fullConflict.start()
        try await wait { !fullConflict.preview.isEmpty }
        try Files.save(Files.child(company.url, StockModule.references.note!), "新来源", expected: filesBefore.last!)
        try await wait { !fullConflict.running }
        try check(fullConflict.completed == 0 && (try model.text(StockModule.references.note!)) == "新来源" &&
                  (try StockModule.allCases.dropLast().map { try model.text($0.note!) }) == Array(filesBefore.dropLast()), "末章冲突时前面各章保持原样")
        for provider in [ResearchProvider.claude, .gemini] {
            use(provider)
            model.prepareStockResearch(.valuation)
            let single = model.stockRun!
            try check(single.prompt.contains(StockModule.valuation.template) && !single.prompt.contains(StockModule.risks.template), "单节模板范围有误")
            single.prompt += "\n用户附加条件"; single.start()
            try await wait { !single.running }
            try check(single.completed == 1, single.status)
        }
        use(.codex)
        model.prepareStockResearch(.valuation)
        let conflict = model.stockRun!
        conflict.prompt += "\n用户附加条件 等待测试"
        conflict.start()
        try await wait { !conflict.preview.isEmpty }
        let file = try Files.child(company.url, StockModule.valuation.note!)
        try Files.save(file, "研究期间的手工修订", expected: Files.contents(file))
        try await wait { !conflict.running }
        try check(conflict.completed == 0 && !conflict.preview.isEmpty && (try Files.contents(file)) == "研究期间的手工修订", "冲突时应保留手工正文和生成预览")
        model.prepareStockResearch(.valuation)
        let cancel = model.stockRun!
        cancel.prompt += "\n用户附加条件 等待测试"; cancel.start()
        try await wait { !cancel.preview.isEmpty }
        cancel.cancel()
        try await Task.sleep(for: .milliseconds(1300))
        try check(cancel.completed == 0 && (try Files.contents(file)) == "研究期间的手工修订", "取消后不应保存部分答案")
        print("PASS 可编辑提示词、一次生成、14 章原文分发、图文格式及完整性、单节范围、三种服务输出格式、流式预览、只追加、跨公司隔离、冲突和取消")
    }
}
