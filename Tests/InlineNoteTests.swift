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
        var titleQuestion = Entry(kind: .questions, title: "问题可以改名吗？", body: "问题正文。")
        titleQuestion.links = [entry.id]
        try m.store(titleQuestion)
        m.go(.entry(titleQuestion.id))
        try await until("改名测试问题未加载") {
            guard let reader = find(WKWebView.self, in: window.contentView) else { return false }
            return (try? await reader.evaluateJavaScript("article.querySelector('p')?.textContent === '问题正文。'") as? Bool) == true
        }
        func clickQuestionTitle() async throws {
            let view = window.contentView!
            let point = view.convert(NSPoint(x:55, y:view.isFlipped ? 38 : view.bounds.height-38), to:nil)
            for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                let event = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],
                    timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,
                    eventNumber:1,clickCount:1,pressure:type == .leftMouseDown ? 1 : 0)!
                window.sendEvent(event)
            }
            try await until("单击标题后输入焦点未进入标题") { m.inlineNote?.mode == .title && window.firstResponder is NSTextView }
        }
        try await clickQuestionTitle()
        let titleWeb = find(WKWebView.self, in:window.contentView)!
        try check(try await titleWeb.evaluateJavaScript("!activeBlock && !state.editID") as? Bool == true,"改名时展开了正文段落")
        let titleInput = window.firstResponder as! NSTextView
        titleInput.selectAll(nil)
        titleInput.insertText("怎样验证这个问题？",replacementRange:titleInput.selectedRange())
        let enterTitle = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],
            timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,
            characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        window.sendEvent(enterTitle)
        try await until("回车未保存问题标题") { m.inlineNote == nil && !(window.firstResponder is NSTextView) && m.snapshot.resolve(titleQuestion.id)?.title == "怎样验证这个问题？" }
        try await clickQuestionTitle()
        let nextInput = window.firstResponder as! NSTextView
        nextInput.selectAll(nil)
        nextInput.insertText("更新后的关键问题",replacementRange:nextInput.selectedRange())
        m.go(.entry(entry.id))
        let savedTitle=try Files.scan(project.url).resolve(titleQuestion.id)
        try check(savedTitle?.title=="更新后的关键问题" && savedTitle?.body==titleQuestion.body && savedTitle?.links==titleQuestion.links,
                  "切页时改名未保存或改变了正文与关联")
        try await until("正文未渲染") {
            guard let web = find(WKWebView.self, in: window.contentView) else { return false }
            return (try? await web.evaluateJavaScript("article.querySelector('h2')?.textContent==='阅读' && article.querySelectorAll('p').length===2") as? Bool) == true
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
        try check(m.dialog == nil && m.inlineNote?.mode == .paragraph, "单击进入了整页编辑")
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
        board.setString("<ol start='9'><li>甲<ul><li><b>乙</b></li></ul></li><li>丙</li></ol>", forType: .html)
        try check(try NotePaste.markdown(from: board, beside: project.url.appendingPathComponent("memo.md")) == "9. 甲\n   - **乙**\n10. 丙", "粘贴网页列表丢失起始编号、粗体或子项")
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
        _ = try await web.evaluateJavaScript("article.querySelector('img').click()")
        try check(try await jsBool("!activeBlock && !imageLine.hidden && getComputedStyle(selectedImage).cursor==='default' && imageLine.value.startsWith('![图片](assets/') && imageSourceRange(selectedImage)?.start === state.body.indexOf(imageLine.value)"),
                  "单击图片未正确显示原始引用，或误入段落编辑")
        let bridge = web.navigationDelegate as! Reader.Bridge
        let imageCenter = try await web.evaluateJavaScript("(() => { const r=selectedImage.getBoundingClientRect(); return [r.x+r.width/2,r.y+r.height/2] })()") as! [Double]
        let imagePoint = web.convert(NSPoint(x:imageCenter[0],y:web.isFlipped ? imageCenter[1] : web.bounds.height-imageCenter[1]),to:nil)
        for clicks in 1...2 {
            for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                let event = NSEvent.mouseEvent(with:type,location:imagePoint,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                    windowNumber:window.windowNumber,context:nil,eventNumber:clicks,clickCount:clicks,pressure:1)!
                if type == .leftMouseDown { web.mouseDown(with:event) } else { web.mouseUp(with:event) }
                try await Task.sleep(for:.milliseconds(20))
            }
        }
        try await until("双击图片未打开前景预览") { bridge.imagePreview?.isVisible == true }
        let panel = bridge.imagePreview!
        try await until("小图原始大小或放大按钮错误") { find(NSButton.self,in:panel.contentView)?.toolTip == "放大" && find(PreviewImageScroll.self,in:panel.contentView)?.scale == 1 }
        let escape = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,
                                      context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
        panel.sendEvent(escape)
        try await until("Esc 未关闭图片预览") { !panel.isVisible }
        try check(try await jsBool("!!selectedImage && !activeBlock && !imageLine.hidden"),"退出预览后丢失图片选区")
        // Exercise both wheel paths and hand dragging on a real, overflowing preview.
        let large = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2000,pixelsHigh:1600,bitsPerSample:8,samplesPerPixel:4,
                                     hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let largeURL = try m.documentURL(entry.path).deletingLastPathComponent().appendingPathComponent("大图.png")
        try large.representation(using:.png,properties:[:])!.write(to:largeURL)
        let previewURL = try await web.evaluateJavaScript("new URL('feynman-image://local/?'+new URLSearchParams({file,src:'大图.png'})).href") as! String
        bridge.handleImageMessage(["action":"previewImage","src":previewURL],in:web)
        let largePanel = bridge.imagePreview!
        try await until("大图未以原始尺寸打开") {
            find(PreviewImageScroll.self,in:largePanel.contentView)?.documentView?.frame.width == 2000
        }
        let viewport = find(PreviewImageScroll.self,in:largePanel.contentView)!
        let canvas = viewport.documentView!
        let zoomButton = find(NSButton.self,in:largePanel.contentView)!
        try check(viewport.scale==1 && !viewport.offersZoomIn && zoomButton.toolTip=="缩小","大图没有自动切换到缩小")
        zoomButton.performClick(nil)
        try check(viewport.scale<1 && viewport.offersZoomIn && zoomButton.toolTip=="放大","适应窗口后放大按钮错误")
        zoomButton.performClick(nil)
        try check(viewport.scale==1,"放大按钮未返回原始大小")
        let wheelPoint = viewport.convert(NSPoint(x:viewport.bounds.width/3,y:viewport.bounds.height/3),to:nil)
        let wheelScreenPoint = largePanel.convertPoint(toScreen:wheelPoint)
        func wheel(_ delta:Int32,command:Bool) {
            let cg = CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:delta,wheel2:0,wheel3:0)!
            cg.flags = command ? .maskCommand : []
            cg.location = CGPoint(x:wheelScreenPoint.x,y:NSScreen.screens[0].frame.maxY-wheelScreenPoint.y)
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:Int64(largePanel.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:Int64(largePanel.windowNumber))
            largePanel.sendEvent(NSEvent(cgEvent:cg)!)
        }
        let anchor = canvas.convert(wheelPoint,from:nil)
        wheel(20,command:true)
        let afterZoom = canvas.convert(wheelPoint,from:nil)
        try check(hypot(anchor.x-afterZoom.x/viewport.scale,anchor.y-afterZoom.y/viewport.scale)<1.5,"缩放时鼠标指向的位置发生漂移")
        try check(viewport.scale>1 && canvas.frame.width>2000,"⌘ 滚轮未放大图片")
        wheel(-20,command:true)
        try check(abs(viewport.scale-1)<0.001,"反向 ⌘ 滚轮未缩小图片")
        let clip = viewport.contentView
        clip.scroll(to:NSPoint(x:220,y:220))
        viewport.reflectScrolledClipView(clip)
        wheel(-40,command:false)
        try await until("普通滚轮未滚动大图") { abs(clip.bounds.minY-220)>1 && abs(viewport.scale-1)<0.001 }
        let beforeDrag = clip.bounds.origin, point = canvas.convert(NSPoint(x:clip.bounds.midX,y:clip.bounds.midY),to:nil)
        func pointer(_ type:NSEvent.EventType,_ at:NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with:type,location:at,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:largePanel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        }
        canvas.mouseDown(with:pointer(.leftMouseDown,point))
        try check(NSCursor.current == .closedHand,"按住图片时没有切换为抓手")
        let moved = NSPoint(x:point.x+35,y:point.y+22)
        canvas.mouseDragged(with:pointer(.leftMouseDragged,moved))
        canvas.mouseUp(with:pointer(.leftMouseUp,moved))
        try check(abs(clip.bounds.minX-beforeDrag.x+35)<1 && abs(clip.bounds.minY-beforeDrag.y-22)<1 && abs(viewport.scale-1)<0.001,
                  "拖动没有双向平移，或松开后误触缩放")
        largePanel.close()
        var menuOpened = false
        let observer = NotificationCenter.default.addObserver(forName:NSMenu.didBeginTrackingNotification,object:nil,queue:.main) { notice in
            guard let menu = notice.object as? NSMenu, let copy = menu.item(withTitle:"复制图片源码") else { return }
            menuOpened = menu.item(withTitle:"剪切")?.isEnabled == true && menu.item(withTitle:"缩放预览")?.submenu != nil
            menu.performActionForItem(at:menu.index(of:copy))
            menu.cancelTracking()
        }
        _ = try await web.evaluateJavaScript("selectedImage.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true,button:2})); true")
        try await until("图片右键菜单未显示或复制了错误内容") { menuOpened && board.string(forType:.string)?.hasPrefix("![图片](assets/") == true }
        NotificationCenter.default.removeObserver(observer)
        let originalImage = board.string(forType:.string)!
        let alternate = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:70,pixelsHigh:24,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let changedImage = try NotePaste.storeImage(alternate.representation(using:.png,properties:[:])!,name:"修改后的图注",note:m.documentURL(entry.path))
        let above = String(repeating:"正文段落。\n\n",count:45) + "`" + originalImage + "` " + originalImage + " ["
        let below = "](#另一个位置)\n\n" + String(repeating:"后续段落。\n\n",count:24) + "## 另一个位置"
        let imageEntry = Entry(kind:.entities,title:"长文图片",body:above + originalImage + below)
        try m.store(imageEntry)
        m.go(.entry(imageEntry.id))
        try await until("长文图片未加载") {
            guard let reader = find(WKWebView.self,in:window.contentView) else { return false }
            return (try? await reader.evaluateJavaScript("article.querySelector('a img')?.naturalWidth===4") as? Bool) == true
        }
        let longWeb = find(WKWebView.self,in:window.contentView)!
        func clickInReader(_ selector: String) async throws {
            let center = try await longWeb.callAsyncJavaScript("const r=document.querySelector(sel).getBoundingClientRect(); return [r.x+r.width/2,r.y+r.height/2]",
                arguments:["sel":selector],in:nil,contentWorld:.page) as! [Double]
            let point = longWeb.convert(NSPoint(x:center[0],y:longWeb.isFlipped ? center[1] : longWeb.bounds.height-center[1]),to:nil)
            for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                let event = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                    windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
                if type == .leftMouseDown { longWeb.mouseDown(with:event) } else { longWeb.mouseUp(with:event) }
                try await Task.sleep(for:.milliseconds(30))
            }
        }
        _ = try await longWeb.evaluateJavaScript("article.querySelector('a img').scrollIntoView({block:'center'});window.imageScrollBefore=scrollY;")
        try await clickInReader("article a img")
        try await Task.sleep(for:.milliseconds(400))
        try check(try await longWeb.evaluateJavaScript("imageScrollBefore>0 && Math.abs(scrollY-imageScrollBefore)<2 && selectedImage===article.querySelector('a img') && !imageLine.hidden && !imageLine.readOnly && !activeBlock") as? Bool == true,
                  "长文单击图片后失去选区、滚动跳转或打开了段落源码")
        try await clickInReader("#image-source")
        _ = try await longWeb.callAsyncJavaScript("imageLine.select(); document.execCommand('insertText',false,value);",arguments:["value":changedImage],in:nil,contentWorld:.page)
        try check(try await longWeb.evaluateJavaScript("document.activeElement===imageLine && selectedImage.alt==='图片'") as? Bool == true,"编辑图注时图片消失或输入框未获得焦点")
        let enterImage = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
            windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        window.sendEvent(enterImage)
        try await until("回车未原位更新图片说明和路径") {
            try await longWeb.evaluateJavaScript("selectedImage===article.querySelector('a img') && selectedImage?.alt==='修改后的图注' && selectedImage.naturalWidth===70 && Math.abs(scrollY-imageScrollBefore)<2 && !activeBlock") as? Bool == true
        }
        try await until("图片修改未保存到正确的引用") { try m.text(imageEntry.path).map { Document($0).body == above + changedImage + below } == true }
        try check(m.finishInlineNote(),"无法结束图片编辑")
        print("通过：长文图片单击原位选中、编辑说明与路径、回车更新及保存重复引用中的指定图片")
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
            return activeBlock.field.value==='重复' && activeBlock.listPrefix==='- ' && article.querySelector('li').textContent==='重复' && !!article.querySelector('pre code'); })()
          """)
        try check(listOK as? Bool == true, "列表定位或相邻列表项排版错误")
        _ = try await memoWeb.evaluateJavaScript("""
          (() => { const f=activeBlock.field; f.setSelectionRange(f.value.length,f.value.length);
            document.execCommand('insertText',false,'二');
            f.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true})); })()
          """)
        try check(try await memoWeb.evaluateJavaScript("activeBlock.field.value==='重复二' && activeBlock.listPrefix==='  - ' && activeBlock.holder.parentElement.parentElement.matches('li') && activeBlock.field.selectionStart===activeBlock.field.value.length") as? Bool == true, "Tab 未缩进当前列表项或移动了光标")
        _ = try await memoWeb.evaluateJavaScript("""
            const sendListKey=(key,shiftKey=false)=>activeBlock.field.dispatchEvent(new KeyboardEvent('keydown',{key,shiftKey,bubbles:true,cancelable:true}));
            sendListKey('Tab',true);
            if (activeBlock.field.value!=='重复二' || activeBlock.listPrefix!=='- ') throw Error('Shift+Tab 未恢复列表层级');
            sendListKey('Tab',true);
            if (activeBlock.tag!=='P' || activeBlock.field.value!=='重复二' || activeBlock.field!==document.activeElement) throw Error('顶层未退出列表');
            sendListKey('ArrowRight');
            """)
        try check(try await memoWeb.evaluateJavaScript("activeBlock.field.value.startsWith('```swift') && article.querySelectorAll('li').length===1 && [...article.querySelectorAll('p')].some(p=>p.textContent==='重复二')") as? Bool == true, "跨段键盘导航未恢复列表")
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
        try check(try m.text("memo.md") == fixture.replacingOccurrences(of: "- 重复\n\n", with: "\n重复二\n\n") + "\n\n新的段落", "相同文本的条目被改错或分隔符丢失")
        let outline="前文\n\n10. 父项\n11. **重复**\n12. 重复\n    - 子项\n      - 孙项\n    - 小结\n13. 末项\n\n后文"
        let nested="前文\n\n10. 父项\n    1. **重复**\n    2. 重复\n       - 子项\n         - 孙项\n       - 小结\n11. 末项\n\n后文"
        let outlineEntry=Entry(kind:.questions,title:"列表缩进",body:outline)
        try m.store(outlineEntry)
        m.go(.entry(outlineEntry.id))
        try await until("未加载缩进测试笔记") {
            guard let view=find(WKWebView.self,in:window.contentView) else { return false }
            return (try? await view.evaluateJavaScript("article.querySelectorAll(':scope > ol > li').length===4") as? Bool)==true
        }
        let outlineWeb=find(WKWebView.self,in:window.contentView)!
        window.makeFirstResponder(outlineWeb)
        _ = try await outlineWeb.evaluateJavaScript("""
            const rows=article.querySelectorAll(':scope > ol > li');
            getSelection().setBaseAndExtent(rows[2].querySelector('div').firstChild,2,rows[1].querySelector('strong').firstChild,1); true
            """)
        func listKey(_ char:String,_ code:UInt16,_ modifiers:NSEvent.ModifierFlags=[]) async throws {
            let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,characters:char,charactersIgnoringModifiers:char,isARepeat:false,keyCode:code)!
            window.sendEvent(key)
            try await Task.sleep(for:.milliseconds(100))
        }
        try await listKey("\t",48)
        try await until("两行没有一起缩进或子项位置错误") { m.snapshot.resolve(outlineEntry.id)?.body==nested }
        try check(try await outlineWeb.evaluateJavaScript("article.querySelectorAll('ol > li > ol > li').length===2 && getSelection().focusNode.parentElement.tagName==='STRONG' && getSelection().focusOffset===1") as? Bool==true,"缩进后没有保留反向选区")
        try await listKey("z",6,.command)
        try await until("无法一次撤销多行缩进") { m.inlineNote?.text==outline }
        try await listKey("z",6,[.command,.shift])
        try await until("无法重做多行缩进") { m.inlineNote?.text==nested }
        try await listKey("\u{19}",48,.shift)
        try await until("两行没有一起减少缩进") { m.snapshot.resolve(outlineEntry.id)?.body==outline }
        _ = try await outlineWeb.evaluateJavaScript("""
            (() => {
                const rows=article.querySelectorAll(':scope > ol > li');
                getSelection().setBaseAndExtent(rows[0].firstChild,0,rows[1].querySelector('strong').firstChild,2);
            })()
            """)
        try await listKey("\t",48)
        try check(m.inlineNote?.text==outline, "首项没有上一个同级项时应保留原层级")
        func clickListText(_ selector: String) async throws {
            let xy = try await outlineWeb.callAsyncJavaScript("""
                const el=article.querySelector(selector);
                el.scrollIntoView({block:'nearest'});
                const r=el.getBoundingClientRect();
                return [r.left+10,r.top+10];
                """, arguments:["selector":selector], in:nil, contentWorld:.page) as! [Double]
            let point=outlineWeb.convert(NSPoint(x:xy[0],y:outlineWeb.isFlipped ? xy[1] : outlineWeb.bounds.height-xy[1]),to:nil)
            for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                let event=NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                    windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
                if type == .leftMouseDown { outlineWeb.mouseDown(with:event) } else { outlineWeb.mouseUp(with:event) }
            }
        }
        try await clickListText("ol > li:nth-child(3) > div")
        try await until("点击父项展开了子列表或撑高输入框") {
            (try? await outlineWeb.evaluateJavaScript("activeBlock?.field.value==='重复' && activeBlock.listPrefix==='12. ' && activeBlock.field.clientHeight<parseFloat(getComputedStyle(activeBlock.field).lineHeight)*1.5 && article.querySelectorAll('li:nth-child(3) li').length===3") as? Bool)==true
        }
        try await clickListText("ol > li:nth-child(3) > ul > li:last-child")
        try await until("从父项点击子项时没有切换到该行") {
            (try? await outlineWeb.evaluateJavaScript("activeBlock?.field.value==='小结' && activeBlock.listPrefix==='    - '") as? Bool)==true
        }
        try await listKey("\u{19}",48,.shift)
        let lifted=outline.replacingOccurrences(of:"    - 小结\n13. 末项",with:"13. 小结\n14. 末项")
        try await until("子项反缩进后没有回到顶层") { m.inlineNote?.text==lifted }
        try await listKey("\u{19}",48,.shift)
        let plain=lifted.replacingOccurrences(of:"13. 小结\n",with:"\n小结\n\n")
        try await until("再次反缩进没有得到独立普通段落") { m.snapshot.resolve(outlineEntry.id)?.body==plain }
        try check(try await outlineWeb.evaluateJavaScript("activeBlock.field.value==='小结' && activeBlock.tag==='P' && !activeBlock.holder.closest('li')") as? Bool==true,"退出列表后光标没有留在普通段落")
        try await listKey("z",6,.command)
        try await until("退出列表无法撤销") { m.inlineNote?.text==lifted }
        try await listKey("z",6,.command)
        try await until("无法恢复三级列表") { m.inlineNote?.text==outline }
        _ = try await outlineWeb.evaluateJavaScript("""
            closeBlock(false,false);
            const selectedRows=article.querySelectorAll(':scope > ol > li');
            getSelection().setBaseAndExtent(selectedRows[1].querySelector('strong').firstChild,1,
                selectedRows[2].querySelector('div').firstChild,2); true
            """)
        try await listKey("\u{19}",48,.shift)
        let plainRows="前文\n\n10. 父项\n\n**重复**\n\n重复\n\n- 子项\n  - 孙项\n- 小结\n\n13. 末项\n\n后文"
        try await until("多选顶层退出列表时没有保留子项、编号或强调") { m.inlineNote?.text==plainRows }
        try check(try await outlineWeb.evaluateJavaScript("getSelection().anchorNode.parentElement.tagName==='STRONG' && getSelection().anchorOffset===1 && getSelection().focusNode.parentElement.tagName==='P' && getSelection().focusOffset===2") as? Bool==true,"多项退出列表时选区变化")
        print("通过：单项和多项列表缩进、从首行开始的选区、子列表随动、反向选区以及一次撤销和重做")
        m.go(.entry(entry.id))
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
        m.beginInlineNote("memo.md", offset: seam + 2, mode: .paragraph)
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
        window.makeFirstResponder(readOnly)
        _ = try await readOnly.evaluateJavaScript("getSelection().selectAllChildren(article); true")
        try await pressDelete()
        try check(m.inlineNote==nil, "只读资料的选区触发了删除")
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
            _ = try await questionWeb.evaluateJavaScript("article.querySelector('.after-table-line').scrollIntoView({block:'nearest'})")
            try await until("原生窗口与网页布局尚未对齐") {
                guard let height = try await questionWeb.evaluateJavaScript("innerHeight") as? Double else { return false }
                return abs(height - questionWeb.bounds.height) < 2
            }
            let xy = try await questionWeb.evaluateJavaScript("""
                (()=>{const r=article.querySelector('.after-table-line').getBoundingClientRect();
                      return [r.left+16,r.top+r.height/2];})()
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
        let listSection = "## 仍未解决与判别条件\n\n- 第一条\n- 重复\n- 重复\n- **最后一条**"
        let rangeBody = "保留开头\n\n" + listSection + "\n\n保留结尾"
        let rangeQuestion=Entry(kind:.questions,title:"跨段删除",body:rangeBody)
        try m.store(rangeQuestion)
        m.go(.entry(rangeQuestion.id))
        try await until("跨段测试的问题未加载") {
            guard let view=find(WKWebView.self,in:window.contentView) else { return false }
            return (try? await view.evaluateJavaScript("article.querySelectorAll('li').length===4") as? Bool) == true
        }
        let rangeWeb=find(WKWebView.self,in:window.contentView)!
        window.makeFirstResponder(rangeWeb)
        _ = try await rangeWeb.evaluateJavaScript("""
            const title=article.querySelector('h2').firstChild, tail=article.querySelector('li:last-child strong').firstChild;
            getSelection().setBaseAndExtent(tail,tail.length,title,0); true
            """)
        try await pressDelete()
        try await until("选中小标题和四个列表项后未能一次删除并保存") { m.snapshot.resolve(rangeQuestion.id)?.body=="保留开头\n\n保留结尾" }
        try await shortcut("z",6)
        try await until("撤销未还原标题、格式和重复列表项") { m.inlineNote?.text==rangeBody }
        try await shortcut("z",6,shift:true)
        try await until("整段删除不能重做") { m.inlineNote?.text=="保留开头\n\n保留结尾" }
        _ = try await rangeWeb.evaluateJavaScript("activeBlock.field.blur(); true")
        try await until("整段删除后未恢复阅读状态") { m.inlineNote==nil }
        _ = try await rangeWeb.evaluateJavaScript("""
            const ps=article.querySelectorAll(':scope > p');
            getSelection().setBaseAndExtent(ps[0].firstChild,2,ps[1].firstChild,2); true
            """)
        try await pressDelete(forward:true)
        try await until("跨段删除误删未选中的首尾文字") { m.inlineNote?.text=="保留结尾" }
        try check(try await rangeWeb.evaluateJavaScript("!!article.querySelector('details.question-history')") as? Bool==true,"删除波及追问记录")
        try await shortcut("z",6)
        try await until("不能撤销跨段的部分文字删除") { m.inlineNote?.text=="保留开头\n\n保留结尾" }
        // Start in the expanded first paragraph and drag to the end of the next
        // paragraph through AppKit, just as a user would in the reader.
        let dragPoints=try await rangeWeb.evaluateJavaScript("""
            (()=>{ const f=activeBlock.field, p=article.querySelector(':scope > p');
              f.scrollIntoView({block:'nearest'});
              const a=f.getBoundingClientRect(), r=document.createRange();
              r.selectNodeContents(p); const b=r.getBoundingClientRect();
              return [a.left+1,a.top+a.height/2,b.right+1,b.top+b.height/2]; })()
            """) as! [Double]
        for (i,type) in [NSEvent.EventType.leftMouseDown,.leftMouseDragged,.leftMouseDragged,.leftMouseUp].enumerated() {
            let t=[0.0,0.55,1.0,1.0][i]
            let x=dragPoints[0]+(dragPoints[2]-dragPoints[0])*t, y=dragPoints[1]+(dragPoints[3]-dragPoints[1])*t
            let point=rangeWeb.convert(NSPoint(x:x, y:rangeWeb.isFlipped ? y : rangeWeb.bounds.height-y),to:nil)
            let event=NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,eventNumber:i+1,clickCount:1,pressure:1)!
            switch type {
            case .leftMouseDown: rangeWeb.mouseDown(with:event)
            case .leftMouseDragged: rangeWeb.mouseDragged(with:event)
            default: rangeWeb.mouseUp(with:event)
            }
            try await Task.sleep(for:.milliseconds(90))
        }
        try check(try await rangeWeb.evaluateJavaScript("getSelection().toString().includes('保留开头') && getSelection().toString().includes('保留结尾')") as? Bool==true,"鼠标从编辑段落拖向下一段时选区不完整")
        try await pressDelete()
        try await until("拖选全文后没有保留可输入的空正文") { m.inlineNote?.text=="" }
        _ = try await rangeWeb.evaluateJavaScript("document.execCommand('insertText',false,'新正文')")
        try await until("删除全部段落后不能继续写入") { m.snapshot.resolve(rangeQuestion.id)?.body=="新正文" }
        let styled=Entry(kind:.questions,title:"保留选区外的格式",body:"**重复开头**\n\n中间\n\n[重复结尾](https://example.org)")
        try m.store(styled)
        m.go(.entry(styled.id))
        try await until("格式选区测试未打开") {
            guard let view=find(WKWebView.self,in:window.contentView) else { return false }
            return (try? await view.evaluateJavaScript("!!article.querySelector('p > a') && !!article.querySelector('p > strong')") as? Bool)==true
        }
        let styledWeb=find(WKWebView.self,in:window.contentView)!
        window.makeFirstResponder(styledWeb)
        _ = try await styledWeb.evaluateJavaScript("""
            getSelection().setBaseAndExtent(article.querySelector('strong').firstChild,2,article.querySelector('a').firstChild,2); true
            """)
        try await pressDelete()
        try await until("选区两端的粗体或链接目标丢失") { m.inlineNote?.text=="**重复**[结尾](https://example.org)" }
        // Reuse this fixture to check the Edit menu, keyboard, clipboard conversion and undo.
        (styledWeb.navigationDelegate as? Reader.Bridge)?.pasteboard = board
        func selectStyledRange() async throws {
            _ = try await styledWeb.evaluateJavaScript("if(activeBlock) activeBlock.field?.blur(); true")
            try await until("未回到带格式的原文") {
                (try? await styledWeb.evaluateJavaScript("!activeBlock && article.querySelector('strong')?.textContent==='重复开头' && article.querySelector('a')?.textContent==='重复结尾'") as? Bool)==true
            }
            _ = try await styledWeb.evaluateJavaScript("""
                getSelection().setBaseAndExtent(article.querySelector('strong').firstChild,2,article.querySelector('a').firstChild,2); true
                """)
            try await until("跨段选区未能接收原生文字输入") { (try? await styledWeb.evaluateJavaScript("article.isContentEditable && !getSelection().isCollapsed") as? Bool)==true }
        }
        try await shortcut("z",6)
        try await selectStyledRange()
        guard let inputClient=window.firstResponder as? NSTextInputClient else { throw Failure("阅读器未接收中文输入") }
        let insertion=NSRange(location:NSNotFound,length:0)
        inputClient.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0),replacementRange:insertion)
        try await Task.sleep(for:.milliseconds(80))
        inputClient.insertText("中文",replacementRange:insertion)
        try await until("确认中文候选词后未完整替换") { m.inlineNote?.text=="**重复**中文[结尾](https://example.org)" }
        try await shortcut("z",6)
        try await selectStyledRange()
        try await shortcut("x",7)
        try await until("跨段剪切未移除内容") { m.inlineNote?.text=="**重复**[结尾](https://example.org)" }
        try check(board.string(forType: .string)=="**开头**\n\n中间\n\n[重复](https://example.org)", "剪切没有保留选区的 Markdown")
        try await shortcut("z",6)
        try await selectStyledRange()
        board.clearContents()
        board.setString("<table><tr><th>材料</th><th>结果</th></tr><tr><td>甲</td><td>乙</td></tr></table>",forType:.html)
        try await shortcut("v",9)
        try await until("粘贴的表格未替换所选段落") {
            guard let t=m.inlineNote?.text else { return false }
            return t.hasPrefix("**重复**\n\n|") && t.hasSuffix("\n\n[结尾](https://example.org)") && t.contains("材料") && !t.contains("中间")
        }
        try await shortcut("z",6)
        try await selectStyledRange()
        for char in ["a","b","c"] {
            let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,characters:char,charactersIgnoringModifiers:char,isARepeat:false,keyCode:0)!
            window.sendEvent(event)
        }
        try await until("快速连续输入未完整替换选区") { m.inlineNote?.text=="**重复**abc[结尾](https://example.org)" }
        m.go(.doc("memo.md"))
        try await until("切换 Memo 未复用阅读器") {
            guard find(WKWebView.self,in:window.contentView) === styledWeb else { return false }
            return (try? await styledWeb.evaluateJavaScript("state.file==='memo.md'") as? Bool)==true
        }
        m.navigate(.back)
        try await until("回到条目后未恢复正确内容") {
            (try? await styledWeb.evaluateJavaScript("!!article.querySelector('p > a') && article.textContent.includes('abc')") as? Bool)==true
        }
        m.expanded=["reports",Kind.entities.rawValue]
        let reopened=Workspace()
        reopened.root=folder
        reopened.open(project)
        try check(reopened.expanded==["reports",Kind.entities.rawValue],"重新打开项目丢失了侧栏折叠状态")
        reopened.expanded=[]
        reopened.open(project)
        try check(reopened.expanded.isEmpty,"全部收起的状态没有保留")
        let zoomWindow=NSWindow(contentRect:NSRect(x:90,y:100,width:820,height:540),
                                styleMask:[.titled,.resizable,.closable,.fullSizeContentView],backing:.buffered,defer:false)
        zoomWindow.titleVisibility = .hidden
        zoomWindow.titlebarAppearsTransparent = true
        zoomWindow.contentView=NSHostingView(rootView:MainView(model:reopened))
        zoomWindow.makeKeyAndOrderFront(nil)
        try await until("未找到页面顶部导航栏") { find(WindowTitleSurface.NavigationBar.self,in:zoomWindow.contentView) != nil }
        let surface=find(WindowTitleSurface.NavigationBar.self,in:zoomWindow.contentView)!
        func click(_ point: NSPoint, count: Int) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event=NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],
                    timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:zoomWindow.windowNumber,context:nil,
                    eventNumber:1,clickCount:count,pressure:type == .leftMouseDown ? 1 : 0)!
                NSApp.sendEvent(event)
            }
        }
        let initialFrame=zoomWindow.frame
        func doubleClickTopBar() {
            zoomWindow.contentView?.layoutSubtreeIfNeeded()
            click(surface.convert(NSPoint(x:surface.bounds.midX,y:surface.bounds.midY),to:nil),count:2)
        }
        func checkContentClicks() async throws {
            guard let reader=find(WKWebView.self,in:zoomWindow.contentView) else { throw Failure("未找到正文") }
            let bar=surface.convert(surface.bounds,to:nil)
            let points=[
                NSPoint(x:reader.convert(.zero,to:nil).x+85,y:bar.minY-35), // Page heading
                reader.convert(NSPoint(x:reader.bounds.midX,y:reader.bounds.midY),to:nil),
                NSPoint(x:70,y:bar.midY) // Sidebar branding
            ]
            for point in points {
                let frame=zoomWindow.frame
                click(point,count:2)
                try await Task.sleep(for:.milliseconds(120))
                try check(zoomWindow.frame.equalTo(frame),"页面内容或侧栏双击触发了窗口缩放")
            }
        }
        try await checkContentClicks()
        doubleClickTopBar()
        try await until("顶部栏未放大窗口") { zoomWindow.frame.width > initialFrame.width }
        try await checkContentClicks()
        doubleClickTopBar()
        try await until("顶部栏未恢复窗口原来的大小和位置") { zoomWindow.frame.equalTo(initialFrame) }
        func doubleClickNativeTitle() {
            let y=(zoomWindow.frame.height+zoomWindow.contentLayoutRect.maxY)/2
            click(NSPoint(x:zoomWindow.frame.width/2,y:y),count:2)
        }
        doubleClickNativeTitle()
        try await until("窗口最上沿双击未放大") { zoomWindow.frame.width > initialFrame.width }
        doubleClickNativeTitle()
        try await until("窗口最上沿双击未还原") { zoomWindow.frame.equalTo(initialFrame) }
        // A regular click on the sidebar control in the same row must still toggle the sidebar.
        let originalWidth=surface.bounds.width
        let dividerX = find(WKWebView.self,in:zoomWindow.contentView)!.convert(.zero,to:nil).x
        click(NSPoint(x:dividerX+28,y:surface.convert(surface.bounds,to:nil).midY),count:1)
        try await until("顶部栏遮住了切换大纲按钮") { surface.bounds.width > originalWidth+100 }
        zoomWindow.orderOut(nil)
        print("通过：跨段剪切、富文本粘贴替换、快速输入及侧栏重开状态")
        print("通过：跨段选区的退格、向前删除、自动保存、撤销和重做")
        print("通过：从阅读或单元格编辑状态点击表下空行、末尾和中间插段、空行离焦、问题历史及只读资料")
        print("通过：整表菜单、剪切和原位粘贴、撤销和重做、单元格和矩形选区剪切、删除最后一行和最后一列")
        print("通过：逐段编辑、鼠标切段、失焦排版、列表与代码块、键盘跨段、新段落、段首与段尾合并、撤销、资料只读、链接与截图粘贴、自动保存及冲突保护；上下键保列跨段、长段折行、可视表格编辑、增删行列、聊天表格粘贴到正文和网格、Markdown 与制表符粘贴、矩形粘贴与撤销")
    }
}
