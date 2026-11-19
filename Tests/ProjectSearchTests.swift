import Foundation
import AppKit
import PDFKit

@main struct ProjectSearchTests {
    static func check(_ ok: Bool, _ message: String) throws {
        if !ok { throw Failure(message) }
    }

    @MainActor static func ready(_ model: Workspace) async throws {
        for _ in 0..<500 {
            if !model.indexing && !model.searchPending { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure("搜索超时")
    }

    @MainActor static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let project = try Files.create(root, title: "搜索", intent: "")
        let other = try Files.create(root, title: "其他项目", intent: "")
        defer {
            for p in [project, other] {
                for prefix in ["searchPins.", "last."] { UserDefaults.standard.removeObject(forKey: prefix + p.id) }
            }
        }

        let headline = Entry(kind: .questions, title: "AI 基础设施与资本开支", body: "Open-AI 长期行业展望")
        var note = Entry(kind: .concepts, title: "季度观察", body: "本季 ＡＩ 企业继续增加資本開支。")
        note.anchors = [Anchor(report: "reports/base.md", section: "一季度", quote: "出口管制")]
        var removed = Entry(kind: .events, title: "AI资本开支已移除")
        removed.deleted = true
        for entry in [note, headline, removed] { try Files.write(entry, in: project.url) }
        let reportPath = "reports/base.md"
        try Files.save(Files.child(project.url, reportPath), "# 季报\nAI\n集群建设仍需资本开支。", expected: nil)
        let memo = try Files.child(project.url, "memo.md")
        try Files.save(memo, "memo 独有证据", expected: Files.contents(memo))
        let loosePath = "references/files/会议.txt"
        let attachmentURL = try Files.child(project.url, loosePath)
        try Files.save(attachmentURL, "光模块出货上升", expected: nil)
        // Create a text-layer PDF so this exercises extraction from a real project attachment.
        let pdfURL = try Files.child(project.url, "references/files/transcript.pdf")
        var page = CGRect(x: 0, y: 0, width: 450, height: 120)
        guard let context = CGContext(pdfURL as CFURL, mediaBox: &page, nil) else { throw Failure("PDF fixture") }
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 10, y: 60)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "photonics backlog") as CFAttributedString), context)
        context.endPDFPage()
        context.closePDF()

        let model = Workspace()
        model.open(project)
        model.search = "wrong"
        model.search = "ai 資本开支"
        try await ready(model)
        let hits = model.searchHits
        try check(hits.count == 3 && hits.first?.item.target == .entry(headline.id), "标题优先、混输、间隔词、跨行与已删过滤")
        try check(hits.contains { $0.item.target == .entry(note.id) && $0.snippet?.contains("資本開支") == true }, "正文原文片段")
        let index = model.searchIndex
        try check(index.results(" AI資本開支  ").count == 3, "无空格的中英混搜")
        try check(index.results("ＯＰＥＮ ai").contains { $0.item.target == .entry(headline.id) }, "空格、标点、大小写与全半角")
        try check(index.results("开支 AI").count == 3, "交换关键词次序")
        try check(index.results("资开支").contains { $0.item.target == .entry(headline.id) }, "汉字间隔匹配")
        try check(index.results("AI 展望").first?.item.target == .entry(headline.id), "跨标题与正文")
        try check(index.results("出口管制").first?.item.target == .entry(note.id), "引文搜索")
        try check(index.results("独有证据").first?.item.target == .document("memo.md"), "Memo 全文")
        try check(index.results("photonics backlog").first?.item.target == .material("project:references/files/transcript.pdf"), "PDF 全文")
        try check(index.results("不存在 Unicorn").isEmpty && index.results(" \n ").isEmpty, "缺词与空输入")
        try check(index.results("ai 资本开支", entriesOnly: true).count == 2, "选择器保留条目范围")
        model.openSearchItem(hits[1].item)
        try check(model.searchHits.map(\.id) == hits.map(\.id), "点开命中保留左侧列表")
        model.retainSearchItems(hits.map(\.item))
        model.retainSearchItems([hits[0].item])
        model.search = ""
        try check(model.retainedItems.count == 3 && model.searchHits.isEmpty, "清空后保留并去重")
        guard let loose = index.results("光模块").first?.item else { throw Failure("附件正文搜索") }
        model.retainSearchItems([loose])
        model.openSearchItem(loose)
        try await ready(model)
        try check(model.retainedItems.contains { if case .entry(let id) = $0.target { return model.place == .entry(id) }; return false }, "资料登记后仍可从保留项打开")
        model.open(other)
        try await ready(model)
        try check(model.retainedItems.isEmpty && model.searchIndex.results("光模块").isEmpty, "项目隔离")
        let reopened = Workspace()
        reopened.open(project)
        try await ready(reopened)
        try check(reopened.retainedItems.count == 4, "重新打开项目仍保留")
        guard var changed = reopened.snapshot.resolve(note.id) else { throw Failure("待更新条目") }
        changed.title = "更新后的名称"
        changed.body = "全新主题"
        try reopened.store(changed)
        reopened.search = "全新主题"
        try await ready(reopened)
        try check(reopened.searchHits.first?.item.title == changed.title && reopened.retainedItems.contains { $0.title == changed.title }, "索引与保留项随修改更新")
        reopened.removeRetainedItem(reopened.searchHits[0].item)
        try check(reopened.retainedItems.count == 3, "取消保留")
        print("通过：中英文全文检索、模糊排序、摘要、实际 PDF / 文本附件、刷新和项目级保留")
    }
}
