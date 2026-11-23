import AppKit
import SwiftUI
import WebKit

@main struct RichEditorTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        UserDefaults.standard.set(directory.path, forKey: "workspace")
        let project = try Files.create(directory, title: "编辑回归", intent: "")
        let path = "reports/base-v1.md"
        let content = "首段有原文引文。\n\n1. 苹果\n2. 香蕉\n\n| 公司 | 市场 |\n| --- | --- |\n| 甲 | 台北 |\n\n原文有 ==重点== 和 $x^2$。"
        try Files.save(Files.child(project.url, path), content, expected: nil)
        var entity = Entry(kind: .entities, title: "引文实体")
        entity.anchors = [Anchor(report: path, quote: "原文引文")]
        try Files.write(entity, in: project.url)
        let model = Workspace()
        model.open(project)
        model.go(.doc(path))
        let window = NSWindow(contentRect: .init(x:0,y:0,width:850,height:600), styleMask:.titled, backing:.buffered, defer:false)
        window.contentView = NSHostingView(rootView: ProjectDetail(m:model,p:project))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        func wait(_ expression: String) async throws {
            for _ in 0..<180 {
                if (try? await model.readerWeb?.evaluateJavaScript(expression) as? Bool) == true { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw Failure("超时 " + expression + " " + (model.error ?? ""))
        }
        func run(_ script: String) async throws {
            guard let web = model.readerWeb else { throw Failure("阅读器未就绪") }
            _ = try await web.evaluateJavaScript(script + ";true")
        }
        try await wait("document.querySelector('mark[role=button]')?.textContent==='原文引文'")
        try await wait("document.querySelector('.sima-tex svg') != null")
        try await run("article.querySelector('li').click()")
        try await wait("typeof editor !== 'undefined' && !!document.querySelector('.sima-block-input')")
        try await run("""
          window.key = (name, extra={}) => document.activeElement.dispatchEvent(
            new KeyboardEvent('keydown', {key:name, bubbles:true, cancelable:true, ...extra}));
          editor.locate(editor.getText().indexOf('香蕉')+2); key('Tab');
        """)
        try await wait("editor.getText().includes('   1. 香蕉')")
        try await run("key('Tab',{shiftKey:true})")
        try await wait("!editor.getText().includes('   1. 香蕉')")
        try await run("editor.action('edit.undo');editor.action('edit.undo')")
        try await wait("editor.getText().includes('2. 香蕉')")
        try await run("editor.locate(editor.getText().indexOf('苹果')+2);key('Enter')")
        try await wait("editor.getText().includes('1. 苹果\\n2. \\n3. 香蕉')")
        try await run("editor.action('edit.undo');editor.locate(1);key('Enter')")
        try await wait("editor.getText().startsWith('首\\n\\n段')")
        try await run("editor.action('edit.undo');editor.locate(1);key('Enter',{shiftKey:true})")
        try await wait("editor.getText().startsWith('首  \\n段')")
        try await run("editor.action('edit.undo');editor.locate(0,2)")
        model.editorCommand("format.bold")
        try await wait("editor.getText().startsWith('**首段**')")
        try await wait("document.querySelector('.sima-table-block table') != null")
        try await run("editor.locate(editor.getText().indexOf('台北')+1)")
        model.editorCommand("table.columnRight")
        try await wait("document.querySelectorAll('.sima-table th').length === 3")
        try await run("editor.action('edit.undo');editor.locate(editor.getText().indexOf('台北')+1);key('a',{metaKey:true});key('Backspace')")
        try await wait("!editor.getText().includes('| 台北 |')")
        try await run("editor.action('edit.undo')")
        try await wait("editor.getText().includes('| 台北 |')")
        try await run("""
          const transfer = new DataTransfer();
          transfer.items.add(new File(['<svg xmlns="http://www.w3.org/2000/svg" width="60" height="30"/>'],'价值链.svg',{type:'image/svg+xml'}));
          document.querySelector('.sima-end-entry').dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:transfer}));
        """)
        try await wait("editor.getText().includes('![价值链.svg](assets/') && document.querySelector('.sima-sized-image img')?.naturalWidth > 0")
        guard model.finishInlineNote(), let saved = try model.text(path), saved.contains("**首段**"), saved.contains("![价值链.svg](assets/") else {
            throw Failure("保存后回读失败")
        }
        try await wait("typeof article !== 'undefined' && !!article.querySelector('mark[role=button]') && !!article.querySelector('img')")
        try await run("article.querySelector('td').click()")
        try await wait("document.activeElement.classList.contains('sima-table-cell-input')")
        guard model.finishInlineNote() else { throw Failure("单元格编辑退出失败") }
        try await wait("typeof article !== 'undefined' && !!article.querySelector('mark[role=button]')")
        try await run("article.querySelector('mark[role=button]').click()")
        for _ in 0..<100 where model.place != .entry(entity.id) { try await Task.sleep(for:.milliseconds(30)) }
        guard model.place == .entry(entity.id) else { throw Failure("引文跳转失败") }
        print("PASS WebKit 正文、Tab/Shift-Tab、段落拆分与软换行、格式、表格、撤销、SVG 拖入、文件回读与原文引文导航")
    }
}
