import Foundation

@main struct StorageTests {
    static func must(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message) }
    }
    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let project = try Files.create(root,title:"AI 医疗 ' 示例",intent:"验证")
        try must(try Files.projects(root).first?.id == project.id, "项目发现")
        let report = "reports/base-v1.md"
        try Files.save(Files.child(project.url,report),"# 测试\n\n医院续约。",expected:nil)
        try Files.save(Files.child(project.url,"entities/clinic.md"),"---\nid: clinic\ntitle: 医院\n---\n医院简介",expected:nil)
        var snapshot = try Files.scan(project.url)
        let hospital = snapshot.resolve("clinic")!
        try must(hospital.origin == "预研提取", "终端生成条目的默认来源")
        var other = Entry(kind:.entities,title:"某医院",body:"另一个来源")
        other.anchors=[Anchor(report:report,quote:"医院续约")]
        other.assets=["library:Library/article.pdf"]
        try Files.write(other,in:project.url)
        var q=Entry(kind:.questions,title:"续约了吗？")
        q.links=[other.id]; try Files.write(q,in:project.url)
        snapshot=try Files.scan(project.url)
        try Files.merge(snapshot.resolve(other.id)!,into:hospital,at:project.url)
        snapshot=try Files.scan(project.url)
        try must(snapshot.entries.count == 2, "合并后的左栏")
        try must(snapshot.resolve(other.id)?.assets == other.assets && snapshot.resolve(other.id)?.anchors == other.anchors, "合并的出处与资料")
        try must(snapshot.resolve(q.links[0])?.id == hospital.id, "旧引用")
        let mergedHospital = snapshot.resolve("clinic")!
        try must(snapshot.related(to: mergedHospital).map(\.id) == [q.id], "对象能反查指向旧编号的问题")
        try must(snapshot.related(to: q).map(\.id) == [mergedHospital.id], "问题能打开合并后的对象")
        var topic = Entry(kind: .concepts, title: "续约率")
        var event = Entry(kind: .events, title: "合同续约")
        q.aliases = ["previous-question"]
        topic.links = [q.id, "previous-question"]
        event.links = ["previous-question"]
        q.links = [topic.id]
        var graph = Snapshot()
        graph.all = [topic, event, q]
        try must(graph.related(to: topic).map(\.id) == [q.id], "双向关联只出现一次")
        try must(graph.related(to: event).map(\.id) == [q.id], "事件能打开旧编号关联的问题")
        let quote = Anchor(report:"reports/base-v1.md",section:"软件市场",quote:"合同续约")
        topic.anchors = [quote]; event.anchors = [quote]; q.anchors = [quote]
        var elsewhere = Entry(kind:.questions,title:"另一节的问题")
        elsewhere.anchors = [Anchor(report:quote.report,section:"客户",quote:quote.quote)]
        graph.all = [topic, event, q, elsewhere]
        try must(graph.questions(for: graph.owners(of: [quote])).map(\.id) == [q.id], "同一段的直接与间接问题只列一次，同名引文不串段")
        q.anchors = []; graph.all = [topic, event, q]
        try must(graph.questions(for: graph.owners(of: [quote])).map(\.id) == [q.id], "从高亮对象反查没有直接出处的问题")
        q.deleted = true
        graph.all = [topic, event, q]
        try must(graph.related(to: topic).isEmpty && graph.related(to: event).isEmpty, "已删除问题不出现在列表")
        var edited=snapshot.resolve("clinic")!
        edited.title="新医院名称"; try Files.write(edited,in:project.url)
        var conflicted=false
        do { try Files.write(edited,in:project.url) } catch { conflicted=true }
        try must(conflicted,"并发修改保护")
        var removed=try Files.scan(project.url).resolve("clinic")!
        removed.deleted=true; try Files.write(removed,in:project.url)
        let cleaned = try Files.scan(project.url)
        let oldFields = "---\nreport: reports/base-v1.md\nquote: 历史引文\n"
        try must(Entry(kind:.concepts, path:"concepts/old.md", raw:oldFields + "---\n").anchors.count == 1, "兼容旧版引文")
        try must(Entry(kind:.concepts, path:"concepts/old.md", raw:oldFields + "anchors: []\n---\n").anchors.isEmpty, "显式清除后旧版引文不会恢复")
        try must(cleaned.resolve(q.id)?.links.isEmpty == true && cleaned.deletedIDs.contains(other.id), "删除同时清理指向合并前编号的链接")
        try must(cleaned.deletedPaths.contains(removed.path) && cleaned.deletedPaths.contains(other.path), "旧文件路径也失效")
        try must(cleaned.all.first { $0.id == other.id }?.anchors.isEmpty == true, "合并后删除也清除旧编号的原文标注")
        var synced = cleaned.resolve(q.id)!
        synced.links = [other.id, removed.id, "not-yet-synced"]
        try Files.save(Files.child(project.url,synced.path), synced.encoded(), expected:synced.original)
        try must(try Files.scan(project.url).needsLinkCleanup, "同步重新带入的死链待清理")
        try Files.resumeLinkCleanup(in:project.url)
        try Files.resumeLinkCleanup(in:project.url)
        try must(try Files.scan(project.url).resolve(q.id)?.links == ["not-yet-synced"], "可重复清理，只删除有删除记录的引用")
        try must(try Files.scan(project.url).resolve(other.id) == nil, "删除不复活被合并的条目")
        try must(try Files.contents(Files.child(project.url,report)) == "# 测试\n\n医院续约。", "报告原文保持完整")
        try must(!snapshot.completed && snapshot.reports == [report], "中断后仍可阅读")
        try Files.save(Files.child(project.url,"preflight.done"),"ok",expected:nil)
        try must(try Files.scan(project.url).completed,"完成记录")
        let old=root.appendingPathComponent("旧版")
        try fm.createDirectory(at:old,withIntermediateDirectories:true)
        try Files.save(Files.child(old,"questions.md"),"# 问题\n\n## Q1 问题一？\n\n- 依据：原文",expected:nil)
        try Files.save(Files.child(old,"memo.md"),"原有判断",expected:nil)
        let imported=try Files.create(root,title:"旧专题",intent:"",legacy:old)
        let copied=try Files.scan(imported.url)
        try must(copied.entries.first?.body == "- 依据：原文", "导入旧问题")
        try must(try Files.contents(Files.child(imported.url,"memo.md")) == "原有判断", "导入 Memo")
        try must(!fm.fileExists(atPath: project.url.appendingPathComponent("annotations").path), "新项目仅使用有类型的条目")
        let legacyFolder = project.url.appendingPathComponent("annotations")
        try fm.createDirectory(at: legacyFolder, withIntermediateDirectories: false)
        let oldQuestion = """
        ---
        id: "prior-question"
        kind: "extend"
        status: "resolved"
        report: "reports/base-v1.md"
        quote: "医院续约。"
        prefix: ""
        suffix: ""
        ---
        # A-001

        ## 标注

        > 医院续约。

        备注：谁决定续约？

        ## 解答

        保留这份回答。
        """
        let oldFile = legacyFolder.appendingPathComponent("A-001.md")
        try Files.save(oldFile, oldQuestion, expected:nil)
        try Files.upgradeLegacySelections(in:project.url)
        let updated = try Files.scan(project.url)
        let recovered = updated.entry(at:"annotations/A-001.md")
        try must(recovered?.kind == .questions && recovered?.id == "prior-question", "旧链接直达问题")
        try must(recovered?.answered == true && recovered?.title == "谁决定续约？" && recovered?.body.contains("保留这份回答。") == true, "状态与解答")
        try must(recovered?.anchors.first?.report == report && recovered?.anchors.first?.quote == "医院续约。", "问题保存自己的原文")
        try fm.createDirectory(at:legacyFolder, withIntermediateDirectories:false)
        try Files.save(oldFile,oldQuestion,expected:nil)
        try Files.upgradeLegacySelections(in:project.url)
        try must(try Files.scan(project.url).entries.count == updated.entries.count, "重复同步不复制同一条问题")
        let outside=root.deletingLastPathComponent()
        try fm.createSymbolicLink(at:project.url.appendingPathComponent("external"),withDestinationURL:outside)
        var escaped=false
        do { _ = try Files.child(project.url,"external/other.md"); escaped=true } catch {}
        try must(!escaped, "越界链接")
        let args = Terminal.arguments(project: project.url, root: root, action: .preflight)
        try must(args == ["-C", project.url.path], "启动时不包含提示词")
        try must(Terminal.arguments(project: project.url, root: root, action: .publish) == args + ["--add-dir",root.path], "回写目录作为独立参数传递")
        let selected = try Files.scan(project.url).resolve("prior-question")!
        let questionDraft = try Terminal.prompt(.question, project:project, root:root, context:selected.path, entry:selected)
        try must(questionDraft.hasPrefix(selected.title) && !questionDraft.contains("preflight.done"), "问题入口预填具体问题")
        let target = ResearchTarget.entry(selected)
        let edits = #"{"edits":[{"original":"保留这份回答。","revised":"保留这份回答，并说明依据。"}]}"#
        try must(try target.materializedAnswer(edits) == selected.body.replacingOccurrences(of:"保留这份回答。", with:"保留这份回答，并说明依据。"), "整合回答保留题注和原文位置")
        try must((try? target.materializedAnswer("只有本轮的回答")) == nil, "单独的新回答不能直接覆盖已有正文")
        let repeated = ResearchTarget.entry(Entry(kind:.concepts, title:"示例", body:"首段。\n\n次段。\n\n重复。重复。"))
        let overlapping = #"{"edits":[{"original":"首段。","revised":"首段修订。"},{"original":"首段","revised":"重叠"}]}"#
        let ambiguous = #"{"edits":[{"original":"重复。","revised":"一次"}]}"#
        try must((try? repeated.materializedAnswer(overlapping)) == nil && (try? repeated.materializedAnswer(ambiguous)) == nil, "重叠或无法唯一定位的修订不写入")
        let multi = #"{"edits":[{"original":"首段。","revised":"首段补充了证据。"},{"original":"重复。重复。","revised":"重复。"}]}"#
        try must(try repeated.materializedAnswer(multi) == "首段补充了证据。\n\n次段。\n\n重复。", "多处修订按原位置合并、去重")
        let empty = ResearchTarget.entry(Entry(kind:.questions, title:"新题"))
        try must(try empty.materializedAnswer(#"{"answer":"首答。","edits":[]}"#) == "首答。", "空白问题可以正常首答")
        var historyItem = Entry(kind:.questions, title:"记录持久化", body:"原总结")
        try Files.write(historyItem, in:project.url)
        historyItem = try Files.scan(project.url).resolve(historyItem.id)!
        let turn = ResearchTurn(question:"原问题\n补充条件", answer:"**本轮回答** [出处](feynman:contract)")
        _ = try ResearchTarget.entry(historyItem).save("更新后的总结", in:project, turn:turn)
        var historySaved = try Files.scan(project.url).resolve(historyItem.id)!
        try must(historySaved.questionHistory == [turn] && historySaved.body == "更新后的总结", "总结与本轮问答一同保存、重读")
        historySaved.body += "，手工补充"
        try Files.write(historySaved, in:project.url)
        historySaved = try Files.scan(project.url).resolve(historyItem.id)!
        try must(historySaved.questionHistory == [turn], "手工编辑保留追问记录")
        let stale = ResearchTarget.entry(historySaved)
        var changedHistory = historySaved
        let another = ResearchTurn(question:"另一个并发问题", answer:"独立回答")
        changedHistory.questionHistory.append(another)
        try Files.write(changedHistory, in:project.url)
        try must((try? stale.save("过期总结", in:project, turn:turn)) == nil, "仅历史变化也触发并发冲突保护")
        let destination = Entry(kind:.questions, title:"合并后的问题", body:"目标总结")
        try Files.write(destination, in:project.url)
        let beforeMerge = try Files.scan(project.url)
        try Files.merge(beforeMerge.resolve(historyItem.id)!, into:beforeMerge.resolve(destination.id)!, at:project.url)
        try must(try Files.scan(project.url).resolve(destination.id)?.questionHistory.count == 2, "合并问题保留每轮问答")
        let publishDraft = try Terminal.prompt(.publish, project:project, root:root, context:selected.path, entry:selected)
        try must(publishDraft.contains(selected.path) && !publishDraft.contains("preflight.done"), "回写仅处理所选文件")
        let reportTarget = try ResearchTarget.report(report, in:project, reports:[report])
        let previousReport = try Files.contents(Files.child(project.url, report))
        _ = try reportTarget.save("## 修订稿\n\n正文。\n", in:project)
        try must(try Files.contents(Files.child(project.url, report)) == previousReport, "报告原版和出处保留")
        try must(try Files.contents(Files.child(project.url, "reports/base-v2.md"))?.hasSuffix("## 修订稿\n\n正文。\n") == true, "报告全文自动存新版本")
        try must((try? reportTarget.save("过期修订", in:project)) == nil, "并发报告修订不会覆盖新版本")
        if CommandLine.arguments.count == 2 {
            let source=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
            let before=try Files.contents(Files.child(source,"questions.md"))
            let userProject=try Files.create(root,title:"原专题兼容性验证",intent:"",legacy:source)
            let userSnapshot=try Files.scan(userProject.url)
            try must(!userSnapshot.reports.isEmpty && userSnapshot.entries.contains { $0.kind == .questions } && userSnapshot.entries.contains { !$0.anchors.isEmpty }, "旧专题文本、报告与标注")
            try must(try Files.contents(Files.child(source,"questions.md")) == before, "原专题完整")
            print("旧专题副本：报告 \(userSnapshot.reports.count)，问题 \(userSnapshot.entries.filter { $0.kind == .questions }.count)")
        }
        print("通过：创建、提取、报告、合并、旧引用、删除、外部修改、完成记录、旧版导入、路径边界、终端参数")
    }
}
