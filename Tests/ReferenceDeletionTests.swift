import Foundation

@main struct ReferenceDeletionTests {
    static func check(_ ok: @autoclosure () throws -> Bool, _ reason: String) throws {
        guard try ok() else { throw Failure(reason) }
    }

    @MainActor static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let topic = try Files.create(root, title: "支付政策", intent: "")
        let stock = try Files.createStock(root, name: "Tempus", ticker: "TEM", link: nil)
        let source = root.appendingPathComponent("原报告.pdf")
        let bytes = Data("source".utf8)
        try bytes.write(to: source)
        let m = Workspace(initialRoot: root)
        for project in [topic, stock] {
            m.open(project)
            let other = project.id == topic.id ? stock : topic
            let id = try Files.registerFile(source, mode: .copy, ownerID: nil, in: project.url)
            var ref = try Files.scan(project.url).resolve(id)!
            ref.aliases = ["former-id"]
            try Files.write(ref, in: project.url)
            let asset = ref.assets[0]
            let payload = try Files.child(project.url, String(asset.dropFirst(8)))
            let cross = "[跨项目](<feynman://research?project=" + project.id + "&target=entry:" + id + ">)"
            let note = project.id == topic.id ? "memo.md" : "reports/base-v1.md"
            let otherNote = project.id == topic.id ? "reports/base-v1.md" : "memo.md"
            let a = try Files.child(project.url, note), b = try Files.child(other.url, otherNote)
            let keep = "[保留](https://example.org/other)"
            let code = "`[示例](feynman:" + id + ")`"
            let body = "[**原文**](feynman:" + id + ") | [旧编号](feynman:former-id#heading) | [文件](<" + asset + ">) | " + keep + " | " + code
            try Files.save(a, body, expected: Files.contents(a))
            try Files.save(b, cross + " | " + keep, expected: Files.contents(b))
            var peer = Entry(kind: project.id == topic.id ? .concepts : .references, title: "同行")
            peer.links = ["former-id", id]
            peer.assets = [asset]
            peer.reportLinks = [ref.path]
            peer.anchors = [Anchor(report: ref.path, quote: "证据")]
            try Files.write(peer, in: project.url)
            m.refresh()
            try m.deleteReference(.entry(m.snapshot.resolve(id)!))
            try check(!fm.fileExists(atPath: payload.path) && !fm.fileExists(atPath: project.url.appendingPathComponent(ref.path).path), "附件和资料登记文件应同时删除")
            try check(try Data(contentsOf: source) == bytes, "导入前的原件应保留")
            try check(try Files.contents(a) == "**原文** | 旧编号 | 文件 | " + keep + " | " + code, "清理正文链接并保留格式、代码和其他引用，实际为 " + ((try? Files.contents(a)) ?? ""))
            try check(try Files.contents(b) == "跨项目 | " + keep, "跨项目证据链接")
            let remaining = try Files.scan(project.url)
            let live = remaining.resolve(peer.id)!
            try check(live.links.isEmpty && live.anchors.isEmpty && live.assets.isEmpty && live.reportLinks.isEmpty, "反链、引文、附件、关系图清理")
            try check(remaining.referenceIDs[asset] == nil && !remaining.unlistedMaterials.contains(asset), "重新扫描也不会恢复附件")

            let linked = try Files.registerFile(source, mode: .library(directory: root, prefix: "library:"), ownerID: nil, in: project.url)
            m.refresh()
            let externalKey = m.snapshot.resolve(linked)!.assets[0]
            let externalLink = "[库外证据](<" + externalKey + ">)"
            try Files.save(a, externalLink, expected: Files.contents(a))
            try Files.save(b, externalLink, expected: Files.contents(b))
            try m.deleteReference(.entry(m.snapshot.resolve(linked)!))
            try check(try Files.contents(a) == "库外证据" && Files.contents(b) == externalLink, "仅解除删除登记所在项目与外部原件的关联")
            let pageURL = URL(string: "https://example.org/policy")!
            let webID = try Files.registerWebLink(pageURL, title: "网页", in: project.url)
            m.refresh()
            try Files.save(a, "[政策](https://example.org/policy) / " + keep, expected: Files.contents(a))
            try m.deleteReference(.entry(m.snapshot.resolve(webID)!))
            try check(try Files.contents(a) == "政策 / " + keep && m.snapshot.resolve(webID) == nil, "网页登记和项目内引用清理")
            try check(try Data(contentsOf: source) == bytes && Files.scan(project.url).resolve(linked) == nil, "保留以外链登记的原文件")
            let loosePath = "references/原件.md"
            try Files.save(Files.child(project.url, loosePath), "# 正文", expected: nil)
            m.refresh()
            var loose = m.snapshot.entry(at: loosePath)!
            loose.core = true
            try m.store(loose)
            try m.deleteReference(.entry(m.snapshot.entry(at: loosePath)!))
            try check(!fm.fileExists(atPath: project.url.appendingPathComponent(loosePath).path) &&
                      !fm.fileExists(atPath: project.url.appendingPathComponent(Files.referenceMetadataDirectory + "/原件.md").path), "独立 Markdown 与对应元数据")
            let pdf = "references/files/loose.pdf"
            try bytes.write(to: Files.child(project.url, pdf))
            try m.deleteReference(.source("project:" + pdf))
            try check(!fm.fileExists(atPath: project.url.appendingPathComponent(pdf).path), "未登记的本地资料")
        }
        m.open(stock)
        let model = root.appendingPathComponent("模型.xlsx")
        try bytes.write(to: model)
        try m.importStockDocument(model, companyID: stock.id, workbook: true)
        let modelPath = m.stockBook.mainModel!
        try m.startJudgment()
        try m.modifyBook { $0.draft?.archiveModel = true; $0.draft?.title = "首次判断"; $0.draft?.reason = "首发"; $0.draft?.conclusion = "基本假设" }
        m.inlineNote?.text = "[现用模型](<feynman://research?project=" + stock.id + "&target=file:" + modelPath + ">)"
        try m.publishJudgment()
        let archived = m.stockBook.history.first!.modelVersion!
        try m.deleteReference(.source("project:" + modelPath))
        try check(m.stockBook.mainModel == nil && !fm.fileExists(atPath: stock.url.appendingPathComponent(modelPath).path), "主模型删除后清除当前指针")
        try check(try Data(contentsOf: model) == bytes && Data(contentsOf: Files.child(stock.url, archived)) == bytes, "模型原件和历史副本保留")
        try check(m.stockBook.history.first?.body == "现用模型", "保留已发布的判断文字")
        print("通过：专题与个股删除附件、外部原件保护、关系清理、跨项目引文、独立文件与模型历史")
    }
}
