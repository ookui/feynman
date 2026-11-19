import SwiftUI
import WebKit

@main struct InlineNoteTests {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: folder) }
        let project = try Files.create(folder, title: "原位编辑", intent: "测试")
        let rawBody = "## 阅读\n\n第一段有**粗体**。\n\n点击*这一段*。"
        let entry = Entry(kind: .entities, title: "标题", body: rawBody)
        try Files.write(entry, in: project.url)
        let m = Workspace()
        m.root = folder
        m.open(project)
        m.go(.entry(entry.id))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ProjectDetail(m: m, p: project))
        window.makeKeyAndOrderFront(nil)

        func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
            if let hit = view as? T { return hit }
            for child in view?.subviews ?? [] { if let hit = find(type, in: child) { return hit } }
            return nil
        }
        func until(_ reason: String, _ condition: () async throws -> Bool) async throws {
            for _ in 0..<100 {
                if try await condition() { return }
                try await Task.sleep(for: .milliseconds(60))
            }
            throw Failure(reason)
        }
        func check(_ result: Bool, _ reason: String) throws {
            guard result else { throw Failure(reason) }
        }
        try await until("正文未渲染") {
            guard let web = find(WKWebView.self, in: window.contentView) else { return false }
            return (try? await web.evaluateJavaScript("article.querySelectorAll('p').length===2") as? Bool) == true
        }
        let web = find(WKWebView.self, in: window.contentView)!
        _ = try await web.evaluateJavaScript("""
          (() => { const p=article.querySelectorAll('p')[1], box=p.getBoundingClientRect();
            p.dispatchEvent(new MouseEvent('click', {bubbles:true, detail:1, clientX:box.x+4, clientY:box.y+8})); })()
          """)
        func jsBool(_ script: String) async throws -> Bool {
            try await web.evaluateJavaScript(script) as? Bool == true
        }
        try await until("单击未在段落原位显示源码") {
            try await jsBool("activeBlock?.field.value === '点击*这一段*。' && !!article.querySelector('p strong') && !!article.querySelector('h2')")
        }
        try check(m.dialog == nil && m.inlineNote?.editsMetadata == false, "单击进入了整页编辑")
        _ = try await web.evaluateJavaScript("""
          (() => {
            const f=activeBlock.field;
            f.setSelectionRange(f.value.length, f.value.length);
            document.execCommand('insertText',false,'补充');
          })()
          """)
        let xy = try await web.evaluateJavaScript("(() => { const r=article.querySelector('p').getBoundingClientRect(); return [r.x+12,r.y+r.height/2]; })()") as! [Double]
        let location = web.convert(NSPoint(x: xy[0], y: web.isFlipped ? xy[1] : web.bounds.height-xy[1]), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { web.mouseDown(with: event) }
            else { web.mouseUp(with: event) }
            try await Task.sleep(for: .milliseconds(45))
        }
        try await until("切段后前段未恢复或光标未进入新段") {
            try await jsBool("document.activeElement === activeBlock?.field && activeBlock.field.value === '第一段有**粗体**。' && article.querySelector('p em')?.textContent === '这一段' && article.querySelector('p').textContent.endsWith('补充')")
        }
        _ = try await web.evaluateJavaScript("activeBlock.field.blur()")
        try await until("离焦后未自动排版或保存") {
            guard m.inlineNote == nil, try m.text(entry.path).map({ Document($0).body == rawBody + "补充" }) == true else { return false }
            return try await jsBool("!article.querySelector('textarea') && article.querySelectorAll('p').length===2")
        }
        m.beginInlineNote(entry.path, offset: (rawBody as NSString).length)
        try await until("从编辑入口未能打开对应段落") { try await jsBool("!!activeBlock") }
        _ = try await web.evaluateJavaScript("const f=activeBlock.field; f.setSelectionRange(f.value.length, f.value.length);")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        (web.navigationDelegate as? Reader.Bridge)?.pasteboard = board
        board.setString("<p>阅读<a href='https://example.org/report(a)'>研究报告</a>与<a href='https://example.org/data'>数据</a>。</p>", forType: .html)
        _ = try await web.callAsyncJavaScript("await pasteIntoBlock(activeBlock,'');", arguments: [:], in: nil, contentWorld: .page)
        try check(try await jsBool("activeBlock.field.value.includes('阅读[研究报告](https://example.org/report%28a%29)与[数据](https://example.org/data)。')"), "网页链接丢失")
        let existing = "[来源](https://example.org) 与 `https://example.org`"
        try check(NotePaste.plainMarkdown(existing, selection: "") == existing, "Markdown 链接或代码被重复转换")
        try check(NotePaste.plainMarkdown("https://example.org", selection: "出处") == "[出处](https://example.org)", "选中文字粘贴网址失败")
        board.clearContents()
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = image.representation(using: .png, properties: [:])!
        board.setData(png, forType: .png)
        _ = try await web.callAsyncJavaScript("await pasteIntoBlock(activeBlock,'');", arguments: [:], in: nil, contentWorld: .page)
        try check(try await jsBool("activeBlock.field.value.includes('![图片](assets/')"), "图片未引用本地附件")
        let body = try await web.evaluateJavaScript("paragraphBody(activeBlock)") as! String
        try await until("自动保存未落盘") { try m.text(entry.path).map { Document($0).body == body } == true }
        try check(m.finishInlineNote(), "无法完成编辑")
        try await until("图片未在正文中显示") {
            guard let reader = find(WKWebView.self, in: window.contentView) else { return false }
            return (try? await reader.evaluateJavaScript("article.querySelector('img')?.naturalWidth===4") as? Bool) == true
        }
        let fixture = "## 列表\n\n- 重复\n- 重复\n\n```swift\nlet n = 1\n```\n\n最后一段"
        try Files.save(project.url.appendingPathComponent("memo.md"), fixture, expected: try m.text("memo.md"))
        m.editDoc("memo.md")
        guard let listWeb = find(WKWebView.self, in: window.contentView) else { throw Failure("阅读器未加载") }
        try await until("列表页编辑未就绪") {
            guard let reader = find(WKWebView.self, in: window.contentView) else { return false }
            return (try? await reader.evaluateJavaScript("state.file === 'memo.md' && !!activeBlock && article.querySelectorAll('li').length===2") as? Bool) == true
        }
        let memoWeb = find(WKWebView.self, in: window.contentView) ?? listWeb
        let listOK = try await memoWeb.evaluateJavaScript("""
          (() => { const item=article.querySelectorAll('li')[1], r=item.getBoundingClientRect();
            item.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1,clientX:r.x+8,clientY:r.y+8}));
            return activeBlock.field.value==='- 重复' && article.querySelector('li').textContent==='重复' && !!article.querySelector('pre code'); })()
          """)
        try check(listOK as? Bool == true, "列表定位或相邻列表项排版错误")
        _ = try await memoWeb.evaluateJavaScript("""
          (() => { const f=activeBlock.field; f.setSelectionRange(f.value.length,f.value.length);
            document.execCommand('insertText',false,'二');
            f.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true})); })()
          """)
        try check(try await memoWeb.evaluateJavaScript("activeBlock.field.value.startsWith('```swift') && article.querySelectorAll('li')[1].textContent==='重复二'") as? Bool == true, "跨段键盘导航未恢复列表")
        _ = try await memoWeb.evaluateJavaScript("""
          (() => {
            activeBlock.field.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));
            const f = activeBlock.field; f.setSelectionRange(f.value.length,f.value.length);
            f.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
            document.execCommand('insertText',false,'新的段落');
            return true;
          })()
          """)
        try check(try await memoWeb.evaluateJavaScript("activeBlock.field.value === '新的段落' && [...article.querySelectorAll('p')].some(p=>p.textContent==='最后一段')") as? Bool == true, "新段落没有独立编辑")
        m.go(.entry(entry.id))
        try check(try m.text("memo.md") == fixture.replacingOccurrences(of: "- 重复\n\n", with: "- 重复二\n\n") + "\n\n新的段落", "相同文本的条目被改错或分隔符丢失")
        m.beginInlineNote(entry.path)
        m.inlineNote!.text += "草稿"
        var external = try Files.scan(project.url).resolve(entry.id)!
        external.body += "其他修改"
        try Files.write(external, in: project.url)
        m.go(.doc("memo.md"))
        try check(m.place == .entry(entry.id) && m.inlineNote?.diskVersion != nil, "冲突未保留草稿")
        try check(try m.text(entry.path).map { Document($0).body } == external.body, "覆盖了外部修改")
        m.inlineNote!.text = external.body + "合并"
        try check(m.finishInlineNote(reviewed: true), "核对后合并失败")
        m.editDoc("memo.md")
        m.inlineNote!.text = "切换时保存"
        m.go(.entry(entry.id))
        try check(try m.text("memo.md") == "切换时保存" && m.inlineNote == nil, "切页丢失编辑")
        let first = "ABCDEFGHIJKLMNO"
        let wrapped = String(repeating: "中文换行段落", count: 34)
        let grid = "| 指标 | 本期 | 上期 |\n| :-- | --: | --- |\n| 收入 | **42** | 30 |\n| 空格 |  |  |"
        let note = [first, "短", first, wrapped, grid, "表后正文"].joined(separator: "\n\n")
        try Files.save(project.url.appendingPathComponent("log.md"), note, expected: try m.text("log.md"))
        m.editDoc("log.md")
        try await until("没有打开方向键测试笔记") {
            guard let reader = find(WKWebView.self, in: window.contentView) else { return false }
            return (try? await reader.evaluateJavaScript("state?.file==='log.md' && !!activeBlock") as? Bool) == true
        }
        let reader = find(WKWebView.self, in: window.contentView)!
        func evaluate(_ script: String) async throws -> Bool {
            try await reader.evaluateJavaScript(script) as? Bool == true
        }
        func arrow(down: Bool) async throws {
            let char = down ? "\u{f701}" : "\u{f700}"
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: down ? 125 : 126)!
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(70))
        }
        _ = try await reader.evaluateJavaScript("activeBlock.field.setSelectionRange(8,8)")
        try await arrow(down:true)
        try check(try await evaluate("activeBlock.field.value==='短' && activeBlock.field.selectionEnd===1"), "向下没有落到短段同一横向位置")
        try await arrow(down:true)
        try check(try await evaluate("activeBlock.field.value==='ABCDEFGHIJKLMNO' && Math.abs(activeBlock.field.selectionEnd-8)<=1"), "经过短段丢失了目标列")
        try await arrow(down:false)
        try await arrow(down:false)
        try check(try await evaluate("activeBlock.start===0 && Math.abs(activeBlock.field.selectionEnd-8)<=1"), "反向跨段没有回到原列")
        try await arrow(down:true)
        try await arrow(down:true)
        try await arrow(down:true)
        let firstLine = try await reader.evaluateJavaScript("activeBlock.field.selectionEnd") as! Int
        try await arrow(down:true)
        try check(try await evaluate("activeBlock.field.value.includes('中文换行段落') && activeBlock.field.selectionEnd>\(firstLine) && !article.querySelector('.sima-table-block')"), "折行段落内移动时过早跳段")
        _ = try await reader.evaluateJavaScript("activeBlock.field.setSelectionRange(activeBlock.field.value.length,activeBlock.field.value.length)")
        try await arrow(down:true)
        try check(try await evaluate("!!activeBlock.grid && document.activeElement.closest('th')!==null && !article.querySelector('.paragraph-source')"), "从段落进入表格时网格被源码替代")
        try await arrow(down:true)
        try check(try await evaluate("activeBlock.field.closest('tr').rowIndex===1"), "表内向下未移动至下一行")
        try await arrow(down:true)
        try await arrow(down:true)
        try check(try await evaluate("activeBlock.field.value==='表后正文' && !!article.querySelector('table strong')"), "离开表格后排版或光标错误")
        try await arrow(down:false)
        try check(try await evaluate("activeBlock.field.closest('tr').rowIndex===2"), "向上进入表格未到末行")
        _ = try await reader.evaluateJavaScript("activeBlock.field.blur()")
        try await until("表格失焦后未恢复阅读") { try await evaluate("!activeBlock && !!article.querySelector('.note-table-scroll')") }
        _ = try await reader.evaluateJavaScript("""
          (() => { const td = article.querySelector('table').rows[2].cells[1], box=td.getBoundingClientRect();
            td.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1,clientX:box.left+4,clientY:box.top+4})); })()
          """)
        try await until("单击空单元格没有选中该行列") {
            try await evaluate("activeBlock?.field?.closest('td')?.cellIndex===1 && activeBlock.field.closest('tr').rowIndex===2")
        }
        try check(try await evaluate("getComputedStyle(activeBlock.field).fontSize==='12px' && !!activeBlock.holder.querySelector('td strong')"), "表格字号或其他单元格的格式发生变化")
        _ = try await reader.evaluateJavaScript("document.execCommand('insertText',false,'A|B')")
        _ = try await reader.evaluateJavaScript("activeBlock.field.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}))")
        try check(try await evaluate("activeBlock.field.closest('td').cellIndex===2"), "Tab 未进入下一格")
        _ = try await reader.evaluateJavaScript(#"""
          (() => { let transfer=new DataTransfer(); transfer.setData('text/plain','单元一\t单元二\n单元三\t单元四');
            activeBlock.field.dispatchEvent(new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:transfer})); })()
          """#)
        try check(try await evaluate("activeBlock.holder.querySelector('table').rows.length===4 && activeBlock.holder.querySelector('table').rows[3].cells[3].textContent.includes('单元四')"), "粘贴矩形资料未扩展网格")
        _ = try await reader.evaluateJavaScript("activeBlock.field.dispatchEvent(new KeyboardEvent('keydown',{key:'z',metaKey:true,bubbles:true,cancelable:true}))")
        try check(try await evaluate("activeBlock.holder.querySelector('table').rows.length===3"), "撤销粘贴失败")
        _ = try await reader.evaluateJavaScript("activeBlock.grid.action('rowBelow'); activeBlock.grid.focus(3,2); activeBlock.grid.action('columnRight'); activeBlock.grid.focus(3,3); activeBlock.grid.action('deleteColumn'); activeBlock.grid.action('deleteRow'); true")
        let tableEdges = try await reader.evaluateJavaScript(#"""
          (() => {
            const raw='A|B\n:-|-:\nx|y\nshort';
            const cleared=SimaTables.setCell(raw,0,0,'');
            if (SimaTables.parse(cleared)?.rows[0][1].text!=='B' || !cleared.endsWith('x|y\nshort')) return false;
            const slash=SimaTables.setCell(raw,0,0,'ends\\');
            if (SimaTables.parse(slash)?.rows[0][0].text!=='ends\\') return false;
            const padded=SimaTables.setCell(raw,2,1,'more');
            if (!padded.startsWith('A|B\n:-|-:\nx|y\n') || SimaTables.parse(padded)?.rows[2][1].text!=='more') return false;
            const pasted=SimaTables.pasteRectangle(raw,1,0,'\ty');
            return SimaTables.parse(pasted)?.rows[1][1].text==='y';
          })()
          """#)
        try check(tableEdges as? Bool == true,"可省略首尾竖线的表格编辑错列")
        m.go(.entry(entry.id))
        let written = try m.text("log.md") ?? ""
        try check(written.contains("A\\|B") && written.contains("**42**") && written.contains("---:") &&
                  written.hasPrefix(first+"\n\n短") && written.hasSuffix("表后正文"), "单元格内容、列对齐或表格周围正文丢失")
        let paragraphs = "开头😀**粗体**\n\n第二段\n\n最后"
        try Files.save(project.url.appendingPathComponent("memo.md"), paragraphs, expected: try m.text("memo.md"))
        m.go(.doc("memo.md"))
        let seam = ("开头😀**粗体**" as NSString).length
        m.beginInlineNote("memo.md", offset: seam + 2, editsMetadata: false)
        try await until("未展开第二段") {
            guard let view = find(WKWebView.self, in: window.contentView) else { return false }
            return (try? await view.evaluateJavaScript("activeBlock?.field.value === '第二段'") as? Bool) == true
        }
        let joinWeb = find(WKWebView.self, in: window.contentView)!
        func pressDelete(forward: Bool = false) async throws {
            let character = forward ? "\u{f728}" : "\u{7f}"
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: forward ? 117 : 51)!
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(70))
        }
        try await pressDelete()
        try check(try await joinWeb.evaluateJavaScript("activeBlock.field.value === '开头😀**粗体**第二段' && activeBlock.field.selectionEnd === \(seam)") as? Bool == true, "退格未合并或光标偏移")
        _ = try await joinWeb.evaluateJavaScript("document.execCommand('undo')")
        try await until("合并无法撤销") { m.inlineNote?.text == paragraphs }
        _ = try await joinWeb.evaluateJavaScript("requestBlock(0); activeBlock.field.setSelectionRange(\(seam),\(seam))")
        try await pressDelete(forward: true)
        try await until("合并后没有保存完整正文") { try m.text("memo.md") == paragraphs.replacingOccurrences(of: "**\n\n", with: "**") }
        let chatTable = """
        <div class="markdown"><div><table><thead><tr><th>指标</th><th>数值</th><th>来源</th></tr></thead>
        <tbody><tr><td><p>A||B</p></td><td></td><td><a href="https://example.org/data">原文</a></td></tr>
        <tr><td><strong>收入</strong></td><td>10<br>20</td><td>年报</td></tr></tbody></table></div></div>
        """
        board.clearContents()
        board.setString(chatTable, forType: .html)
        board.setString("指标 数值 来源 A||B 原文 收入 10 20 年报", forType: .string)
        (joinWeb.navigationDelegate as? Reader.Bridge)?.pasteboard = board
        _ = try await joinWeb.evaluateJavaScript("activeBlock.field.setSelectionRange(2,2)")
        _ = try await joinWeb.callAsyncJavaScript("await pasteIntoBlock(activeBlock,'扁平文本');", arguments: [:], in: nil, contentWorld: .page)
        try await until("聊天表格未在两段文字之间按原行列渲染") {
            (try? await joinWeb.evaluateJavaScript("""
              (() => { const t = article.querySelector('table');
                return t?.rows.length===3 && t.rows[0].cells.length===3 && t.rows[1].cells[0].textContent==='A||B' &&
                    t.rows[1].cells[1].textContent==='' && t.rows[1].cells[2].querySelector('a')?.textContent==='原文' &&
                    !!t.rows[2].cells[0].querySelector('strong') && !!t.rows[2].cells[1].querySelector('br'); })()
              """) as? Bool) == true
        }
        let savedTable = "| 指标 | 数值 | 来源 |\n| --- | --- | --- |\n| A\\|\\|B |  | [原文](https://example.org/data) |\n| **收入** | 10<br>20 | 年报 |"
        try await until("表格未保存为 Markdown 或破坏前后正文") { try m.text("memo.md")?.contains("开头\n\n" + savedTable + "\n\n😀") == true }
        _ = try await joinWeb.evaluateJavaScript("const cell=article.querySelector('table').rows[1].cells[1]; cell.click(); true")
        try await until("粘贴后的表格无法编辑") { (try? await joinWeb.evaluateJavaScript("!!activeBlock?.grid") as? Bool) == true }
        _ = try await joinWeb.callAsyncJavaScript("await pasteIntoBlock(activeBlock,'指标 数值 来源');", arguments: [:], in: nil, contentWorld: .page)
        try check(try await joinWeb.evaluateJavaScript("activeBlock.grid.getRaw().includes('[原文](https://example.org/data)') && activeBlock.holder.querySelector('table').rows[3].cells[3].textContent.includes('年报')") as? Bool == true, "在已有表格粘贴时行列错位")
        board.clearContents()
        board.setString("名称\t说明\t备注\r\n甲\t\"第一行\n第二行\"\t", forType: .string)
        try check(try NotePaste.markdown(from: board, beside: project.url.appendingPathComponent("memo.md")) ==
            "| 名称 | 说明 | 备注 |\n| --- | --- | --- |\n| 甲 | 第一行<br>第二行 |  |", "纯文本表格丢失空格或换行")
        board.clearContents()
        board.setString(savedTable, forType: .string)
        try check(try NotePaste.markdown(from: board, beside: project.url.appendingPathComponent("memo.md")) == savedTable, "复制 Markdown 表格时被二次转换")
        let native = NoteTextView()
        native.noteURL = project.url.appendingPathComponent("memo.md")
        native.string = "前后"
        native.setSelectedRange(NSRange(location: 1, length: 0))
        try check(native.pasteMarkdown(from: board) && native.string == "前\n\n" + savedTable + "\n\n后", "新建笔记时表格与原文粘连")
        board.clearContents()
        board.setString("<p>以下是对比。</p>" + chatTable + "<p>对比结束。</p>", forType: .html)
        let mixed = try NotePaste.markdown(from: board, beside: project.url.appendingPathComponent("memo.md")) ?? ""
        try check(mixed.hasPrefix("以下是对比。") && mixed.contains(savedTable) && mixed.hasSuffix("对比结束。"), "复制带表格的整段回答时正文或表格丢失")
        let source = project.url.appendingPathComponent("references/只读原件.md")
        let raw = "# 资料\n\n只读正文\n\n| A | B |\n|---|---|\n| 1 | 2 |"
        try Data(raw.utf8).write(to: source)
        m.refresh()
        m.go(.entry(m.snapshot.entry(at: "references/只读原件.md")!.id))
        try await until("引用资料未只读打开") {
            guard let view = find(WKWebView.self, in: window.contentView) else { return false }
            return (try? await view.evaluateJavaScript("state?.editable === false && !!article.querySelector('td') && !article.querySelector('.after-table-line')") as? Bool) == true
        }
        let readOnly = find(WKWebView.self, in: window.contentView)!
        _ = try await readOnly.evaluateJavaScript("article.querySelector('p').click(); article.querySelector('td').click(); requestBlock(0); openBlockAt(0); true")
        try await Task.sleep(for: .milliseconds(180))
        try check(try await readOnly.evaluateJavaScript("!activeBlock && !article.querySelector('textarea, [contenteditable=true]')") as? Bool == true && m.inlineNote == nil, "引用资料进入编辑状态")
        try check(try Data(contentsOf: source) == Data(raw.utf8), "只读资料的原文发生变化")
        let originalGrid = "| 名称 | 说明 | 数值 |\n| :--- | --- | ---: |\n| 重复 | A\\|B | **4** |\n| 重复 | [链接](https://example.org) |  |"
        let surrounding = "前文\n\n" + originalGrid + "\n\n后文"
        try Files.save(project.url.appendingPathComponent("memo.md"), surrounding, expected: try m.text("memo.md"))
        m.go(.doc("memo.md"))
        try await until("操作测试表格未打开") {
            guard let view = find(WKWebView.self, in: window.contentView) else { return false }
            return (try? await view.evaluateJavaScript("state.file==='memo.md' && !!article.querySelector('td')") as? Bool) == true
        }
        let operations = find(WKWebView.self, in: window.contentView)!
        (operations.navigationDelegate as? Reader.Bridge)?.pasteboard = board
        func js(_ code: String) async throws -> Bool { try await operations.evaluateJavaScript(code) as? Bool == true }
        func menu(_ label: String) async throws {
            let clicked = try await operations.callAsyncJavaScript("""
                const button=[...document.querySelectorAll('.sima-table-menu button')].find(b=>b.textContent===label);
                if (button) button.click();
                return !!button;
                """, arguments: ["label": label], in: nil, contentWorld: .page)
            try check(clicked as? Bool == true, "缺少表格菜单操作 " + label)
        }
        func shortcut(_ char: String, _ code: UInt16, shift: Bool = false) async throws {
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.command,.shift] : .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: code)!
            window.sendEvent(key)
            try await Task.sleep(for: .milliseconds(120))
        }
        _ = try await operations.evaluateJavaScript("article.querySelector('td').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true})); true")
        try await until("阅读中的表格右键没有菜单") { try await js("!!document.querySelector('.sima-table-menu')") }
        try await menu("剪切整表")
        try await until("剪切整表未移除 Markdown 或改变前后正文") { try m.text("memo.md") == "前文\n\n后文" }
        try check(board.string(forType: .string) == originalGrid, "剪贴板丢失原表格 Markdown")
        try await shortcut("z",6)
        try await until("不能撤销整表剪切") { m.inlineNote?.text == surrounding }
        try await shortcut("z",6,shift:true)
        try await until("不能重做整表剪切") { m.inlineNote?.text == "前文\n\n后文" }
        _ = try await operations.callAsyncJavaScript("await pasteIntoBlock(activeBlock,'');", arguments: [:], in: nil, contentWorld: .page)
        try await until("在原位粘回整表后数据或排版有变化") { m.inlineNote?.text == surrounding }
        _ = try await operations.evaluateJavaScript("requestBlock(4); activeBlock.grid.focus(1,1); true")
        try await shortcut("x",7)
        try await until("⌘X 没有剪切当前单元格") { try await js("SimaTables.parse(activeBlock.raw).rows[1][1].text===''") }
        try check(board.string(forType: .string) == "A|B", "单元格未进入剪贴板")
        _ = try await operations.evaluateJavaScript("activeBlock.grid.select(1,1,2,2); true")
        try await shortcut("x",7)
        try await until("矩形选区仅清空了第一个格") { try await js("SimaTables.parse(activeBlock.raw).rows.slice(1).every(r=>r[0].text==='重复' && r[1].text==='' && r[2].text==='')") }
        try check(board.string(forType: NotePaste.tableCells) == "\t**4**\n[链接](https://example.org)\t", "剪切选区丢失链接、空格或行列")
        _ = try await operations.callAsyncJavaScript("await pasteIntoBlock(activeBlock,'');", arguments: [:], in: nil, contentWorld: .page)
        try check(try await js("SimaTables.parse(activeBlock.raw).rows[1][2].text==='**4**' && SimaTables.parse(activeBlock.raw).rows[2][1].text.startsWith('[链接]')"), "剪切选区无法贴回原位")
        try await shortcut("a",0)
        try await shortcut("x",7)
        try await until("⌘A、⌘X 没有剪切整表") { m.inlineNote?.text == "前文\n\n后文" }
        try await shortcut("z",6)
        _ = try await operations.evaluateJavaScript("activeBlock.grid.focus(2,0); activeBlock.grid.action('deleteRow'); activeBlock.grid.action('deleteRow'); true")
        try check(try await js("activeBlock.holder.querySelector('table').rows.length===1"), "删行影响剩余表头")
        _ = try await operations.evaluateJavaScript("activeBlock.grid.action('deleteRow')")
        try await until("删除最后一行仍有空表头") { try await js("!article.querySelector('table') && !state.body.includes('|')") }
        try await shortcut("z",6)
        _ = try await operations.evaluateJavaScript("activeBlock.grid.action('deleteColumn'); activeBlock.grid.action('deleteColumn'); activeBlock.grid.action('deleteColumn'); true")
        try await until("删除最后一列仍有残留") { try m.text("memo.md") == "前文\n\n后文" }
        try await shortcut("z",6)
        _ = try await operations.evaluateJavaScript("activeBlock.holder.querySelector('[data-menu-label^=表格]').click(); true")
        try await menu("删除整表")
        try await until("菜单删除整表未保存") { try m.text("memo.md") == "前文\n\n后文" }
        // A table may also be the entire note. Removing it must leave an editable empty document.
        m.go(.entry(entry.id))
        let solo = "表头一|表头二\n:-|-:\n甲|乙\n丙|丁\n"
        try Files.save(project.url.appendingPathComponent("memo.md"), solo, expected: try m.text("memo.md"))
        m.editDoc("memo.md")
        try await until("独立表格没有显示") {
            guard let view=find(WKWebView.self,in:window.contentView) else { return false }
            return (try? await view.evaluateJavaScript("!!activeBlock?.grid && activeBlock.raw.startsWith('表头一')") as? Bool) == true
        }
        let soloWeb=find(WKWebView.self,in:window.contentView)!
        (soloWeb.navigationDelegate as? Reader.Bridge)?.pasteboard=board
        _ = try await soloWeb.evaluateJavaScript("activeBlock.grid.select(1,0,2,1); activeBlock.grid.action('deleteRow'); true")
        try check(try await soloWeb.evaluateJavaScript("activeBlock.holder.querySelector('table').rows.length===1") as? Bool == true, "删除选中多行应保留未选的表头")
        try await shortcut("z",6)
        _ = try await soloWeb.evaluateJavaScript("activeBlock.grid.focus(1,0); true")
        let cutCommand = #selector(NSText.cut(_:))
        let cutMenuItem = NSMenuItem(title: "Cut", action: cutCommand, keyEquivalent: "x")
        try check(NSApp.sendAction(cutCommand, to: window.firstResponder, from: cutMenuItem), "阅读器未接收系统剪切命令")
        try await until("系统剪切菜单未剪切单元格") {
            guard board.string(forType: NotePaste.tableCells) == "甲" else { return false }
            return try await soloWeb.evaluateJavaScript("SimaTables.parse(activeBlock.raw).rows[1][0].text===''") as? Bool == true
        }
        try await shortcut("z",6)
        _ = try await soloWeb.evaluateJavaScript("activeBlock.grid.action('deleteTable')")
        try await until("空文档仍有表格标记或多余换行") { try m.text("memo.md") == "" }
        try await shortcut("z",6)
        try await until("撤销独立表格删除未还原原格式或结尾换行") { try m.text("memo.md") == solo }
        _ = try await soloWeb.evaluateJavaScript("activeBlock.grid.focus(2,1); true")
        let down = NSEvent.keyEvent(with:.keyDown, location:.zero, modifierFlags:[], timestamp:ProcessInfo.processInfo.systemUptime,
            windowNumber:window.windowNumber, context:nil, characters:"\u{f701}", charactersIgnoringModifiers:"\u{f701}", isARepeat:false, keyCode:125)!
        window.sendEvent(down)
        try await until("表格末行向下没有进入正文") {
            (try? await soloWeb.evaluateJavaScript("activeBlock?.afterTable===true && document.activeElement===activeBlock.field") as? Bool) == true
        }
        _ = try await soloWeb.evaluateJavaScript("document.execCommand('insertText',false,'末段'); document.execCommand('undo'); activeBlock.field.blur(); true")
        try await until("撤销表后输入遗留分隔符") { try m.text("memo.md") == solo }
        _ = try await soloWeb.evaluateJavaScript("""
            (() => {const line=article.querySelector('.after-table-line'); const r=line.getBoundingClientRect();
              const point={clientX:r.left+12,clientY:r.bottom+16,bubbles:true};
              article.dispatchEvent(new PointerEvent('pointermove',point));
              if (!line.matches('.in-table-gap')) throw Error('表下空白没有输入提示');
              article.dispatchEvent(new MouseEvent('click',point)); })()
            """)
        try await until("文末较远的空白处不能点击") {
            (try? await soloWeb.evaluateJavaScript("!!activeBlock?.afterTable") as? Bool) == true
        }
        _ = try await soloWeb.evaluateJavaScript("document.execCommand('insertText',false,'末段'); activeBlock.field.blur(); true")
        try await until("新增正文改变了已有的文件末尾换行") { try m.text("memo.md") == solo + "\n末段\n" }
        // The tail of a question includes a history panel. Click the actual gap before it.
        let tableOnly=solo.trimmingCharacters(in: .newlines)
        let question=Entry(kind: .questions, title: "表后继续写", body: tableOnly)
        try m.store(question)
        m.go(.entry(question.id))
        try await until("问题表格后缺少正文输入行") {
            guard let view=find(WKWebView.self,in:window.contentView) else { return false }
            return (try? await view.evaluateJavaScript("!!article.querySelector('.after-table-line + .question-history')") as? Bool) == true
        }
        let questionWeb=find(WKWebView.self,in:window.contentView)!
        func clickAfterTable() async throws {
            let xy = try await questionWeb.evaluateJavaScript("""
                (() => {const line=article.querySelector('.after-table-line'); line.scrollIntoView({block:'nearest'});
                  const r=line.getBoundingClientRect(); return [r.left+16,r.top+r.height/2];})()
                """) as! [Double]
            let point=questionWeb.convert(NSPoint(x:xy[0], y:questionWeb.isFlipped ? xy[1] : questionWeb.bounds.height-xy[1]),to:nil)
            for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                let event=NSEvent.mouseEvent(with:type, location:point, modifierFlags:[], timestamp:ProcessInfo.processInfo.systemUptime,
                    windowNumber:window.windowNumber, context:nil, eventNumber:1, clickCount:1, pressure:1)!
                if type == .leftMouseDown { questionWeb.mouseDown(with:event) } else { questionWeb.mouseUp(with:event) }
            }
            try await until("点击表格下方未获得普通段落光标") {
                (try? await questionWeb.evaluateJavaScript("!!activeBlock?.afterTable && activeBlock.field===document.activeElement && !activeBlock.grid") as? Bool) == true
            }
        }
        try await clickAfterTable()
        _ = try await questionWeb.evaluateJavaScript("activeBlock.field.blur()")
        try await until("空输入行退出时改动了问题正文") { m.inlineNote == nil && m.snapshot.resolve(question.id)?.body == tableOnly }
        try await clickAfterTable()
        _ = try await questionWeb.evaluateJavaScript("document.execCommand('insertText',false,'表后分析')")
        try await until("表后文字未作为普通段落保存") { m.snapshot.resolve(question.id)?.body == tableOnly+"\n\n表后分析" }
        _ = try await questionWeb.evaluateJavaScript("activeBlock.field.blur()")
        try await until("表后段落排版错误") {
            (try? await questionWeb.evaluateJavaScript("article.querySelector('table').rows.length===3 && article.querySelector('p')?.textContent==='表后分析' && !activeBlock") as? Bool) == true
        }
        _ = try await questionWeb.evaluateJavaScript("article.querySelector('td').click()")
        try await until("表格未进入编辑状态") { (try? await questionWeb.evaluateJavaScript("!!activeBlock?.grid") as? Bool) == true }
        _ = try await questionWeb.evaluateJavaScript("activeBlock.grid.focus(1,0); document.execCommand('insertText',false,'更新')")
        try await clickAfterTable()
        _ = try await questionWeb.evaluateJavaScript("document.execCommand('insertText',false,'中间段落'); activeBlock.field.blur(); true")
        try await until("修改单元格后插段错位或覆盖后文") {
            let changed=tableOnly.replacingOccurrences(of:"甲|乙",with:"甲更新|乙")
            return m.snapshot.resolve(question.id)?.body == changed+"\n\n中间段落\n\n表后分析"
        }
        print("通过：从阅读或单元格编辑状态点击表下空行、末尾和中间插段、空行离焦、问题历史及只读资料")
        print("通过：整表菜单、剪切和原位粘贴、撤销和重做、单元格和矩形选区剪切、删除最后一行和最后一列")
        print("通过：逐段编辑、鼠标切段、失焦排版、列表与代码块、键盘跨段、新段落、段首与段尾合并、撤销、资料只读、链接与截图粘贴、自动保存及冲突保护；上下键保列跨段、长段折行、可视表格编辑、增删行列、聊天表格粘贴到正文和网格、Markdown 与制表符粘贴、矩形粘贴与撤销")
    }
}
