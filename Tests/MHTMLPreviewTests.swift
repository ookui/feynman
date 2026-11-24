import AppKit
import SwiftUI
import WebKit

@main struct MHTMLPreviewTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let project = try Files.create(root, title: "网页存档", intent: "")
        let model = Workspace()
        model.open(project)
        let image = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/ahVM1kAAAAASUVORK5CYII="
        let archive = """
        MIME-Version: 1.0
        Content-Type: multipart/related;
          boundary="parts"; start="<outer>"

        --parts
        Content-Type: text/css
        Content-Location: https://example.org/docs/style.css

        h1 { color: rgb(15, 82, 94); }
        --parts
        Content-Type: image/png
        Content-ID: <figure>
        Content-Transfer-Encoding: base64

        \(image)
        --parts
        Content-Type: text/html; charset=utf-8
        Content-ID: <outer>
        Content-Location: https://example.org/docs/report

        <html><title>网页</title><iframe src="cid:report"></iframe></html>
        --parts
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: quoted-printable
        Content-ID: <report>
        Content-Location: https://example.org/docs/report

        <html><head><title>中文报告</title><link rel=3Dstylesheet href=3Dstyle.css></head>
        <body><h1>=E5=8C=BB=E8=8D=AF</h1><p>\(String(repeating:"临床研究结果。",count:60))</p>
        <img src=3D"cid:figure"><script>document.body.remove()</script></body></html>
        --parts--
        """
        let fixture = root.appendingPathComponent("测试.MHT")
        try Data(archive.utf8).write(to: fixture)
        let loose = try Files.child(project.url, "references/files/未登记的存档.mhtml")
        try Data(archive.utf8).write(to: loose)
        model.refresh()
        try model.openAsset(loose)
        guard let opened = model.displayedEntry,
              model.snapshot.sources(for: opened).contains("project:references/files/未登记的存档.mhtml") else {
            throw Failure("从正文链接打开未登记的网页存档失败")
        }
        let window = NSWindow(contentRect:.init(x:0,y:0,width:800,height:600),styleMask:.titled,backing:.buffered,defer:false)
        window.contentView = NSHostingView(rootView: ProjectDetail(m:model,p:project))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func checkFile(_ source: URL, title: String, outerTitle: String, expression: String) async throws {
            let id = try Files.registerFile(source, mode:.copy, ownerID:nil, in:project.url)
            model.refresh()
            model.go(.entry(id))
            func findWeb(_ view: NSView?) -> WKWebView? {
                if let web = view as? WKWebView { return web }
                return view?.subviews.lazy.compactMap(findWeb).first
            }
            enum Step { case body, outerPage, returnToBody }
            var step = Step.body
            var lastStatus = ""
            for _ in 0..<120 {
                if let web = findWeb(window.contentView) {
                    let expected = step == .outerPage ? outerTitle : title
                    let contentCheck = step == .outerPage ? "true" : expression
                    let result = try? await web.evaluateJavaScript("""
                        (()=>{ const page=document.querySelector('#page')?.contentDocument;
                          if (page?.title===\(try json(expected)) && (\(contentCheck))) return 'PASS';
                          return document.querySelector('#status')?.innerText || page?.title || ''; })()
                        """) as? String
                    if result == "PASS" {
                        if step == .returnToBody { return }
                        let next = step == .body ? outerTitle : title
                        let switched = try await web.evaluateJavaScript("""
                            (() => { const picker = document.querySelector('select');
                              const index = [...picker.options].findIndex(option => option.text === \(try json(next)));
                              if (index < 0 || picker.parentElement.hidden) return false;
                              picker.selectedIndex = index;
                              picker.dispatchEvent(new Event('change'));
                              return true; })()
                            """) as? Bool
                        guard switched == true else { throw Failure("存档页面菜单中找不到 " + next) }
                        step = step == .body ? .outerPage : .returnToBody
                    }
                    lastStatus = result ?? lastStatus
                }
                try await Task.sleep(for:.milliseconds(100))
            }
            throw Failure("网页存档预览失败 " + lastStatus)
        }
        try await checkFile(fixture, title: "中文报告", outerTitle: "网页", expression: """
            page.querySelector('h1')?.textContent==='医药' &&
            page.defaultView.getComputedStyle(page.querySelector('h1')).color==='rgb(15, 82, 94)' &&
            page.querySelector('img')?.naturalWidth===1 && document.querySelectorAll('option').length===2
            """)
        if let path = ProcessInfo.processInfo.environment["FEYNMAN_MHTML_SAMPLE"] {
            try await checkFile(URL(fileURLWithPath:path), title:"Generate Biomedicines 研究报告", outerTitle:"ChatGPT", expression:"page.querySelector('h1')?.textContent.includes('Generate') && page.querySelectorAll('p').length>10")
        }
        print("PASS 从附件目录打开网页存档、引用嵌套页面、中文、离线样式及图片")
    }
}
