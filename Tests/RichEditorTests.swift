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
        // Exercise the shipping rich editor with AppKit mouse drags and the Delete key.
        let first = "前段保留。这几十个中文字用于验证编辑状态下的鼠标拖选，可以一次删除选中的全部文字。"
        let middle = "第二段在这里继续。"
        let last = "末段保留原文。"
        let original = [first, middle, last].joined(separator: "\n\n")
        let selectionNote = Entry(kind: .concepts, title: "编辑选区", body: original)
        try model.store(selectionNote)
        model.go(.entry(selectionNote.id))
        try await wait("typeof article !== 'undefined' && article.querySelectorAll('p').length===3")
        try await run("article.querySelector('p').click()")
        try await wait("typeof editor !== 'undefined' && document.activeElement.tagName==='TEXTAREA'")
        guard let web = model.readerWeb else { throw Failure("缺少选区测试视图") }
        func gesture(_ points: [Double]) async throws {
            guard let web = model.readerWeb else { throw Failure("缺少鼠标测试视图") }
            let types: [NSEvent.EventType] = [.leftMouseDown,.leftMouseDragged,.leftMouseDragged,.leftMouseUp]
            for (i,type) in types.enumerated() {
                let t = [0.0,0.5,1.0,1.0][i]
                let x = points[0]+(points[2]-points[0])*t, y = points[1]+(points[3]-points[1])*t
                let at = web.convert(NSPoint(x:x,y:web.isFlipped ? y : web.bounds.height-y),to:nil)
                let event = NSEvent.mouseEvent(with:type,location:at,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                                               windowNumber:window.windowNumber,context:nil,eventNumber:i+1,clickCount:1,pressure:1)!
                switch type {
                case .leftMouseDown: web.mouseDown(with:event)
                case .leftMouseDragged: web.mouseDragged(with:event)
                default: web.mouseUp(with:event)
                }
                try await Task.sleep(for:.milliseconds(75))
            }
        }
        func drag(_ start: (Int,Int), _ end: (Int,Int)) async throws {
            let points = try await web.evaluateJavaScript("""
                (() => {
                  const nodes = [...document.querySelectorAll('.sima-block')].filter(b=>b.dataset.kind!=='blank');
                  function point(n, offset) {
                    const el = nodes[n].querySelector('.sima-text-mirror,p');
                    const r = document.createRange();
                    r.setStart(el.firstChild,offset);r.collapse(true);
                    const box = r.getBoundingClientRect();
                    return [box.x,box.y+box.height/2];
                  }
                  return [...point(\(start.0),\(start.1)), ...point(\(end.0),\(end.1))];
                })()
                """) as! [Double]
            try await gesture(points)
        }
        func deleteAndCheck(_ start: Int, _ end: Int) async throws {
            try await wait("Math.min(editor.getState().selection.anchor,editor.getState().selection.head)===\(start) && Math.max(editor.getState().selection.anchor,editor.getState().selection.head)===\(end)")
            let key = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,characters:"\u{7f}",charactersIgnoringModifiers:"\u{7f}",isARepeat:false,keyCode:51)!
            web.keyDown(with:key)
            let expected = (original as NSString).replacingCharacters(in:NSRange(location:start,length:end-start),with:"")
            try await wait("editor.getText()===\(try json(expected))")
            try await run("editor.action('edit.undo')")
            try await wait("editor.getText()===\(try json(original))")
        }
        try await drag((0,5),(0,36))
        try await deleteAndCheck(5,36)
        try await run("editor.locate(3)")
        try await drag((0,3),(2,2))
        let lastOffset = original.utf16.count-last.utf16.count+2
        try await deleteAndCheck(3,lastOffset)
        try await run("editor.locate(2)")
        try await drag((2,2),(0,3))
        try await deleteAndCheck(3,lastOffset)
        try await run("editor.locate(1)")
        try await drag((1,1),(2,2))
        try await deleteAndCheck(first.utf16.count+3,lastOffset)
        guard model.finishInlineNote(), try Files.scan(project.url).resolve(selectionNote.id)?.body == original else {
            throw Failure("拖选删除并撤销后正文回读失败")
        }
        print("PASS 原生 WebKit 段内、跨段、反向拖选删除与撤销")
        let rows = ["- 第一，**它不需要免疫动物**。这是截图中带有行内粗体的长列表项。点击第一行或已经换行的文字，都只应该编辑这一项，后面的项目继续保留排版。",
                    "- 第二，**它的难点和 AbCellera 正好相反**。这里继续使用正文的字号。",
                    "- 第三，**比较结果**。" + String(repeating:"这一段中文用于测试自动换行后的列表行首位置。",count:4),
                    "- 第四，**其余文字**保留原来的格式。"]
        let loose = "## AbCellera 和 Absci 的异同\n\n几点区别：\n\n" + rows.joined(separator:"\n\n\n")
        let listNote = Entry(kind:.concepts,title:"列表行距",body:loose)
        try model.store(listNote)
        model.go(.entry(listNote.id))
        try await wait("typeof article !== 'undefined' && article.querySelectorAll('li').length===4")
        func mousePoints(_ script: String) async throws -> [Double] {
            guard let points = try await model.readerWeb?.evaluateJavaScript("(() => {" + script + "})()") as? [Double]
            else { throw Failure("无法定位列表项") }
            return points
        }
        // Enter through the reading view, then click the gutter of a different item.
        try await gesture(mousePoints("""
          const r=article.querySelectorAll('li')[1].getBoundingClientRect();
          return [r.left-2,r.top+10,r.left-1,r.top+10];
        """))
        try await wait("typeof editor !== 'undefined' && document.activeElement.value===\(try json(rows[1]))")
        try await run("""
          editor.goToBeginning();
          window.glyph=(el,word,skip=0)=>{
            const tree=document.createTreeWalker(el,NodeFilter.SHOW_TEXT);
            while(tree.nextNode()){
              const n=tree.currentNode,i=n.data.indexOf(word);
              if(i<0)continue;
              const r=document.createRange();r.setStart(n,i+skip);r.setEnd(n,i+skip+1);
              return r.getBoundingClientRect();
            }
            throw Error('找不到 '+word);
          };
          window.thirdPosition=()=>{
            const b=glyph(document.querySelectorAll('.sima-block li')[2],'第三');
            const doc=document.querySelector('.sima-document').getBoundingClientRect();
            return [b.x-doc.x,b.y-doc.y];
          };
          window.beforePosition=thirdPosition();
          window.rowGap=()=>{const rows=document.querySelectorAll('.sima-block li');
            return rows[2].getBoundingClientRect().top-rows[0].getBoundingClientRect().top};
          window.gapBefore=rowGap();
        """)
        try await gesture(mousePoints("""
          const r=document.querySelectorAll('.sima-block li')[2].getBoundingClientRect();
          return [r.left-3,r.top+9,r.left+1,r.top+10];
        """))
        try await wait("document.activeElement.value===\(try json(rows[2])) && editor.getState().selection.anchor===editor.getState().selection.head")
        try await wait("document.querySelectorAll('.sima-block li strong').length===3 && Math.abs(rowGap()-gapBefore)<2")
        try await wait("thirdPosition().every((v,i)=>Math.abs(v-beforePosition[i])<2) && getComputedStyle(document.querySelectorAll('.sima-block li')[2]).listStyleType==='none' && getComputedStyle(document.querySelectorAll('.sima-block li')[1]).listStyleType!=='none'")
        try await run("editor.action('insertText','测');editor.action('edit.undo')")
        try await wait("editor.getText()===\(try json(loose))")
        try await run("""
          editor.goToBeginning();
          window.typeMetrics=()=>['h2','.sima-block p','li p','li strong'].map(s=>{
            const style=getComputedStyle(document.querySelector(s));
            return [style.fontSize,style.fontWeight,style.lineHeight].join('/');
          }).join(',');
          window.beforeMetrics=typeMetrics();
          editor.locate(3);
        """)
        try await gesture(mousePoints("""
          const h=glyph(document.querySelector('.sima-text-mirror'),'AbCellera'),
                p=glyph(document.querySelectorAll('.sima-block li')[1],'第二');
          return [h.left+.1,h.top+h.height/2,p.right-.1,p.top+p.height/2];
        """))
        try await wait("document.activeElement.classList.contains('sima-range-input') && typeMetrics()===beforeMetrics && document.querySelectorAll('.sima-block li strong').length===4 && CSS.highlights.get('sima-selection').size===1")
        try await wait("editor.getState().selection.anchor===3 && editor.getState().selection.head===editor.getText().indexOf('第二')+1")
        try await run("""
          editor.action('insertText','替换');
          editor.action('edit.undo');
        """)
        try await wait("typeMetrics()===beforeMetrics && editor.getText()===\(try json(loose))")
        try await run("editor.locate(editor.getText().indexOf('第二'))")
        try await wait("document.activeElement.value===\(try json(rows[1])) && document.querySelectorAll('.sima-block li strong').length===3")
        guard model.finishInlineNote(), try Files.scan(project.url).resolve(listNote.id)?.body == loose else {
            throw Failure("单击或撤销改变了列表的原始空行")
        }
        print("PASS 原生 WebKit 列表行首轻拖、单项编辑、相邻项间距与 Markdown 回读")
        print("PASS WebKit 正文、Tab/Shift-Tab、段落拆分与软换行、格式、表格、撤销、SVG 拖入、文件回读与原文引文导航")
    }
}
