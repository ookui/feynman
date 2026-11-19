import AppKit
import WebKit
import UniformTypeIdentifiers
import ImageIO

@MainActor final class ReaderImagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { close(); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func close() {
        let owner = parent
        owner?.removeChildWindow(self)
        super.close()
        contentViewController = nil
        contentView = nil
        owner?.makeKey()
    }

    init(url: URL, title: String, scale: CGFloat?, owner: NSWindow) {
        let screen = owner.screen?.visibleFrame ?? owner.frame
        let size = NSSize(width: min(1100, screen.width * 0.9), height: min(820, screen.height * 0.87))
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled,.closable,.resizable,.utilityWindow],
                   backing: .buffered, defer: false)
        self.title = title.isEmpty ? "图片预览" : title
        isReleasedWhenClosed = false
        minSize = NSSize(width: 320, height: 220)
        let preview = ReaderImagePreview()
        preview.view.frame = NSRect(origin:.zero,size:size)
        contentViewController = preview
        preview.loadImage(url, scale:scale)
        setFrameOrigin(NSPoint(x: max(screen.minX,min(owner.frame.midX-frame.width/2,screen.maxX-frame.width)),
                               y: max(screen.minY,min(owner.frame.midY-frame.height/2,screen.maxY-frame.height))))
        owner.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
    }
}

@MainActor private final class ReaderImagePreview: NSViewController {
    private let viewport = PreviewImageScroll()
    private let percentage = NSTextField(labelWithString:"")
    private let zoomButton = NSButton()
    private var loading: Task<Void,Never>?

    override func loadView() {
        view = NSView()
        let fit = NSButton(title:"适应窗口",target:self,action:#selector(fitImage))
        let original = NSButton(title:"原始大小",target:self,action:#selector(originalSize))
        zoomButton.bezelStyle = .rounded
        zoomButton.target = self
        zoomButton.action = #selector(toggleZoom)
        percentage.alignment = .center
        percentage.font = .monospacedDigitSystemFont(ofSize:NSFont.systemFontSize,weight:.regular)
        let controls = NSStackView(views:[zoomButton,percentage,fit,original])
        controls.spacing = 10
        for child in [viewport,controls] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            viewport.topAnchor.constraint(equalTo:view.topAnchor), viewport.leadingAnchor.constraint(equalTo:view.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo:view.trailingAnchor), viewport.bottomAnchor.constraint(equalTo:controls.topAnchor,constant:-9),
            controls.centerXAnchor.constraint(equalTo:view.centerXAnchor), controls.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-10),
            percentage.widthAnchor.constraint(greaterThanOrEqualToConstant:48)
        ])
        controls.isHidden = true
        viewport.onZoomChange = { [weak self,weak controls] in
            guard let self else { return }
            controls?.isHidden = false
            let plus = viewport.offersZoomIn
            let label = plus ? "放大" : "缩小"
            zoomButton.image = NSImage(systemSymbolName:plus ? "plus.magnifyingglass" : "minus.magnifyingglass",accessibilityDescription:label)
            zoomButton.toolTip = label
            zoomButton.setAccessibilityLabel(label)
            percentage.stringValue = Double(viewport.scale).formatted(.percent.precision(.fractionLength(0...1)))
        }
    }

    func loadImage(_ url: URL, scale: CGFloat?) {
        let status = NSTextField(labelWithString:"正在载入图片…")
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        NSLayoutConstraint.activate([status.centerXAnchor.constraint(equalTo:view.centerXAnchor),status.centerYAnchor.constraint(equalTo:view.centerYAnchor)])
        loading = Task { [weak self] in
            do {
                let bytes = try await ReaderImageAsset.bytes(url)
                guard !Task.isCancelled, let self else { return }
                guard let image = NSImage(data:bytes), image.size.width > 0, image.size.height > 0 else { throw Failure("无法读取图片。") }
                status.removeFromSuperview()
                view.layoutSubtreeIfNeeded()
                viewport.show(image,scale:scale)
                view.window?.makeFirstResponder(viewport)
            } catch { status.stringValue = error.localizedDescription }
        }
    }
    deinit { loading?.cancel() }
    @objc private func fitImage() { viewport.zoom(to:nil) }
    @objc private func originalSize() { viewport.zoom(to:1) }
    @objc private func toggleZoom() { viewport.toggleZoom() }
}

// The document stays at least as large as the clip view so small images can be
// centered and large images use AppKit's regular two-axis scrolling.
final class PreviewImageScroll: NSScrollView {
    private let canvas = PreviewImageCanvas()
    private(set) var scale: CGFloat = 1
    private var fitting = false
    var onZoomChange: (() -> Void)?
    private var fitScale: CGFloat {
        guard let size = canvas.image?.size else { return 1 }
        return min(1, max(1,contentSize.width)/size.width, max(1,contentSize.height)/size.height)
    }
    var offersZoomIn: Bool { scale <= fitScale * 1.00001 }
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame:.zero)
        hasHorizontalScroller = true
        hasVerticalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .windowBackgroundColor
        documentView = canvas
    }
    required init?(coder:NSCoder) { fatalError() }

    func show(_ image:NSImage, scale:CGFloat?) {
        canvas.image = image
        zoom(to:scale)
        contentView.scroll(to:NSPoint(x:(canvas.frame.width-contentSize.width)/2,y:(canvas.frame.height-contentSize.height)/2))
        reflectScrolledClipView(contentView)
    }
    override func tile() {
        super.tile()
        guard canvas.image != nil else { return }
        if fitting { scale = fitScale }
        layoutImage()
    }

    private func layoutImage() {
        guard let image = canvas.image else { return }
        let size = NSSize(width:image.size.width*scale,height:image.size.height*scale)
        let frameSize = NSSize(width:max(size.width,contentSize.width),height:max(size.height,contentSize.height))
        if canvas.frame.size != frameSize { canvas.setFrameSize(frameSize) }
        canvas.imageRect = NSRect(x:(frameSize.width-size.width)/2,y:(frameSize.height-size.height)/2,width:size.width,height:size.height)
        canvas.needsDisplay = true
        window?.invalidateCursorRects(for:canvas)
        onZoomChange?()
    }

    func zoom(to requested:CGFloat?, at anchor:NSPoint? = nil) {
        guard canvas.image != nil else { return }
        let clip = contentView.bounds
        let point = anchor ?? NSPoint(x:clip.midX,y:clip.midY)
        let imagePoint = NSPoint(x:(point.x-canvas.imageRect.minX)/scale,y:(point.y-canvas.imageRect.minY)/scale)
        fitting = requested == nil
        scale = min(16,max(min(0.05,fitScale),requested ?? fitScale))
        layoutImage()
        let origin = NSPoint(x:canvas.imageRect.minX+imagePoint.x*scale-(point.x-clip.minX),
                             y:canvas.imageRect.minY+imagePoint.y*scale-(point.y-clip.minY))
        pan(to:origin)
    }
    fileprivate func pan(to origin:NSPoint) {
        var bounds = contentView.bounds
        bounds.origin = origin
        contentView.scroll(to:contentView.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(contentView)
    }
    func toggleZoom(at point:NSPoint? = nil) {
        zoom(to:offersZoomIn ? (scale < 1 ? 1 : 2) : nil,at:point)
    }
    override func scrollWheel(with event:NSEvent) {
        guard event.modifierFlags.contains(.command), canvas.image != nil else { super.scrollWheel(with:event); return }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let change = delta * (event.hasPreciseScrollingDeltas ? 0.012 : 0.18)
        var location = event.locationInWindow
        if event.window == nil, let window { location = window.convertPoint(fromScreen:location) }
        zoom(to:scale * exp(min(1,max(-1,change))),at:canvas.convert(location,from:nil))
    }
    override func keyDown(with event:NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "+","=": zoom(to:scale*1.25)
        case "-": zoom(to:scale/1.25)
        default: super.keyDown(with:event)
        }
    }
}

private final class PreviewImageCanvas: NSView {
    var image: NSImage?
    var imageRect = NSRect.zero
    private var press: (point:NSPoint, origin:NSPoint, time:TimeInterval)?
    private var dragged = false
    private var viewport: PreviewImageScroll? { enclosingScrollView as? PreviewImageScroll }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect:NSRect) {
        image?.draw(in:imageRect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    }
    private var imageCursor: NSCursor {
        if press != nil { return .closedHand }
        let plus = viewport?.offersZoomIn == true
        if #available(macOS 15.0, *) { return plus ? .zoomIn : .zoomOut }
        let symbol = plus ? "plus.magnifyingglass" : "minus.magnifyingglass"
        guard let icon = NSImage(systemSymbolName:symbol,accessibilityDescription:nil) else { return .arrow }
        return NSCursor(image:icon,hotSpot:NSPoint(x:icon.size.width/2,y:icon.size.height/2))
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect.intersection(imageRect),cursor:imageCursor)
    }
    override func mouseDown(with event:NSEvent) {
        guard let viewport, image != nil, imageRect.contains(convert(event.locationInWindow,from:nil)) else { return }
        window?.makeFirstResponder(viewport)
        press = (event.locationInWindow,viewport.contentView.bounds.origin,event.timestamp)
        dragged = false
        window?.invalidateCursorRects(for:self)
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event:NSEvent) {
        guard let press else { return }
        let dx = event.locationInWindow.x-press.point.x, dy = event.locationInWindow.y-press.point.y
        if !dragged && hypot(dx,dy) < 3 { return }
        dragged = true
        viewport?.pan(to:NSPoint(x:press.origin.x-dx,y:press.origin.y+dy))
        NSCursor.closedHand.set()
    }
    override func mouseUp(with event:NSEvent) {
        guard let press else { return }
        self.press = nil
        let point = convert(event.locationInWindow,from:nil)
        if !dragged && event.timestamp-press.time < NSEvent.doubleClickInterval && imageRect.contains(point) {
            viewport?.toggleZoom(at:point)
        }
        window?.invalidateCursorRects(for:self)
        if imageRect.contains(convert(event.locationInWindow,from:nil)) { imageCursor.set() } else { NSCursor.arrow.set() }
    }
}

private enum ReaderImageAsset {
    static func bytes(_ url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf:url,options:.mappedIfSafe) }
        let (bytes,response) = try await URLSession.shared.data(from:url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              CGImageSourceCreateWithData(bytes as CFData,nil) != nil else { throw Failure("无法读取网络图片。") }
        return bytes
    }
}

private final class ImageMenuItem: NSMenuItem {
    let perform: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        perform = action
        super.init(title:title,action:#selector(run),keyEquivalent:"")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { perform() }
}

extension Reader.Bridge {
    func handleImageMessage(_ message: [String:Any], in web: WKWebView) {
        guard let path = data?.file, let string = message["src"] as? String, let owner = web.window else { return }
        let request = URL(string:string)
        let asset: URL?
        if let request, request.scheme == "feynman-image" { asset = try? localImage(request).0 }
        else if let request, ["http","https"].contains(request.scheme?.lowercased() ?? ""), request.host != nil { asset = request }
        else { asset = nil }
        let title = message["title"] as? String ?? ""
        func preview(_ scale: CGFloat? = nil) {
            guard let asset else { model.error = "无法读取图片。"; return }
            imagePreview?.close()
            imagePreview = ReaderImagePanel(url:asset,title:title,scale:scale,owner:owner)
        }
        if message["action"] as? String == "previewImage" { preview(1); return }
        guard let raw = message["raw"] as? String, let body = message["body"] as? String else { return }
        let start = message["start"] as? Int
        let editable = start != nil && data?.editable == true && model.canEditNote(path)
        let local = asset?.isFileURL == true
        let managed = local && asset.flatMap { try? model.documentKey(for:$0) }.map {
            !$0.hasPrefix("library:") && !$0.hasPrefix("lakehouse:")
        } == true
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ name: String, to parent: NSMenu? = nil, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ImageMenuItem(name,action:action)
            item.isEnabled = enabled
            (parent ?? menu).addItem(item)
        }
        func submenu(_ name: String) -> NSMenu {
            let item = NSMenuItem(title:name,action:nil,keyEquivalent:"")
            let sub = NSMenu(); sub.autoenablesItems = false
            item.submenu = sub; menu.addItem(item)
            return sub
        }
        func copyText(_ value: String) {
            pasteboard.clearContents()
            pasteboard.setString(value,forType:.string)
        }
        func splice(_ value: String) {
            guard editable, let start else { return }
            web.callAsyncJavaScript("return replaceSelectedImage(fileName,body,start,raw,value)",
                arguments:["fileName":path,"body":body,"start":start,"raw":raw,"value":value],
                in:nil,in:.page,completionHandler:nil)
        }
        func saveCopy() {
            guard let asset else { return }
            Task { @MainActor in
                do {
                    let bytes = try await ReaderImageAsset.bytes(asset)
                    let panel = NSSavePanel()
                    if let source = CGImageSourceCreateWithData(bytes as CFData,nil),
                       let id = CGImageSourceGetType(source) { panel.allowedContentTypes = [UTType(id as String)].compactMap { $0 } }
                    panel.nameFieldStringValue = asset.lastPathComponent.isEmpty ? "图片" : asset.lastPathComponent
                    if panel.runModal() == .OK, let url = panel.url { try bytes.write(to:url,options:.atomic) }
                } catch { self.model.error = error.localizedDescription }
            }
        }
        add(local ? "在 Finder 中显示" : "打开图片位置",enabled:asset != nil) {
            guard let asset else { return }
            if local { NSWorkspace.shared.activateFileViewerSelecting([asset]) } else { NSWorkspace.shared.open(asset) }
        }
        add("复制图片文件到…",enabled:asset != nil,saveCopy)
        add("重命名或移动图片…",enabled:editable && managed) {
            guard let asset, let start else { return }
            self.model.attempt { try self.moveOrTrashImage(asset,path:path,body:body,start:start,raw:raw,alt:title,trash:false) }
        }
        add("上传图片…",enabled:local) {
            guard let asset else { return }
            self.uploadImage(asset)
        }
        let zoom = submenu("缩放预览")
        for (label,scale) in [("适应窗口",nil),("50%",0.5),("100%",1.0),("200%",2.0)] as [(String,CGFloat?)] {
            add(label,to:zoom,enabled:asset != nil) { preview(scale) }
        }
        let src = request.flatMap { url in local || url.scheme == "feynman-image"
            ? URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{ $0.name=="src" })?.value
            : asset?.absoluteString }
        if let src {
            func htmlAttribute(_ text: String) -> String {
                text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"<",with:"&lt;")
            }
            let syntax = submenu("切换图片语法")
            add("Markdown",to:syntax,enabled:editable) { splice(NotePaste.imageMarkdown(title,src)) }
            add("HTML",to:syntax,enabled:editable) { splice("<img src=\""+htmlAttribute(src)+"\" alt=\""+htmlAttribute(title)+"\">") }
        }
        add("将图片文件移到废纸篓…",enabled:editable && managed) {
            guard let asset, let start else { return }
            self.model.attempt { try self.moveOrTrashImage(asset,path:path,body:body,start:start,raw:raw,alt:title,trash:true) }
        }
        menu.addItem(.separator())
        add("剪切",enabled:editable) { copyText(raw); splice("") }
        add("复制图片源码") { copyText(raw) }
        add("复制图片内容",enabled:asset != nil) {
            guard let asset else { return }
            Task { @MainActor in
                do {
                    let bytes = try await ReaderImageAsset.bytes(asset)
                    guard let img = NSImage(data:bytes) else { throw Failure("无法读取图片。") }
                    self.pasteboard.clearContents()
                    if !self.pasteboard.writeObjects([img]) { throw Failure("无法复制图片。") }
                } catch { self.model.error = error.localizedDescription }
            }
        }
        if let src { add("复制图片地址") { copyText(src) } }
        add("粘贴",enabled:editable) {
            self.model.attempt {
                if let text = try NotePaste.markdown(from:self.pasteboard,beside:self.model.documentURL(path)), !text.isEmpty { splice(text) }
            }
        }
        menu.addItem(.separator())
        add("图片另存为…",enabled:asset != nil,saveCopy)
        if let asset { menu.addItem(NSSharingServicePicker(items:[asset]).standardShareMenuItem) }
        let point = NSPoint(x:message["x"] as? Double ?? 0,y:message["y"] as? Double ?? 0)
        menu.popUp(positioning:nil,at:NSPoint(x:point.x,y:web.isFlipped ? point.y : web.bounds.height-point.y),in:web)
    }

    private func uploadImage(_ source: URL) {
        let prompt = NSAlert()
        prompt.messageText = "上传“" + source.lastPathComponent + "”"
        prompt.informativeText = "粘贴存储服务提供的 HTTPS PUT 上传地址。"
        let address = NSTextField(frame:NSRect(x:0,y:0,width:380,height:24))
        address.placeholderString = "https://…"
        prompt.accessoryView = address
        prompt.window.initialFirstResponder = address
        prompt.addButton(withTitle:"上传")
        prompt.addButton(withTitle:"取消")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        guard let url = URL(string:address.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            model.error = "请输入完整的 HTTPS 上传地址。"; return
        }
        var request = URLRequest(url:url)
        request.httpMethod = "PUT"
        request.setValue(UTType(filenameExtension:source.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                         forHTTPHeaderField:"Content-Type")
        Task { @MainActor in
            do {
                let (_,response) = try await URLSession.shared.upload(for:request,fromFile:source)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw Failure("上传服务未接受图片，请检查地址是否有效。")
                }
                model.notice = "已上传“" + source.lastPathComponent + "”。"
            } catch { model.error = error.localizedDescription }
        }
    }

    private func moveOrTrashImage(_ source: URL, path: String, body: String, start: Int, raw: String, alt: String, trash: Bool) throws {
        let directory = try model.documentURL(path).deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        var replacement = ""
        var destination: URL?
        if trash {
            let confirm = NSAlert()
            confirm.messageText = "将“" + source.lastPathComponent + "”移到废纸篓？"
            confirm.informativeText = "同时移除正文中选中的图片引用。其他引用此文件的位置将无法显示图片。"
            confirm.addButton(withTitle:"取消")
            confirm.addButton(withTitle:"移到废纸篓")
            guard confirm.runModal() == .alertSecondButtonReturn else { return }
        } else {
            let panel = NSSavePanel()
            panel.title = "重命名或移动图片"
            panel.message = "当前引用会随文件更新。其他引用此文件的位置需要单独更新。"
            panel.directoryURL = source.deletingLastPathComponent()
            panel.nameFieldStringValue = source.lastPathComponent
            if let type = UTType(filenameExtension:source.pathExtension) { panel.allowedContentTypes = [type] }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let target = url.standardizedFileURL.resolvingSymlinksInPath()
            guard source != target else { return }
            let key = try model.documentKey(for:target)
            guard !key.hasPrefix("lakehouse:"), !key.hasPrefix("library:") else { throw Failure("请选择项目内的位置。") }
            var base = directory.pathComponents, tail = target.pathComponents
            while base.first != nil && base.first == tail.first { base.removeFirst(); tail.removeFirst() }
            let relative = (Array(repeating:"..",count:base.count)+tail).joined(separator:"/")
            guard let encoded = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn:"%?#"))) else {
                throw Failure("无法生成图片相对路径。")
            }
            replacement = NotePaste.imageMarkdown(alt,encoded)
            destination = target
        }
        let length = (raw as NSString).length
        guard start >= 0, start <= (body as NSString).length, length <= (body as NSString).length-start else {
            throw Failure("图片位置无效。")
        }
        let range = NSRange(location:start,length:length)
        guard data?.file == path, model.canEditNote(path),
              (body as NSString).substring(with:range) == raw,
              model.inlineNote.map({ $0.path == path && $0.text == body && !$0.needsReview }) ??
                ((try? model.text(path)).map { Document($0).body == body } ?? false) else { throw Failure("正文已更新，请重新选择图片。") }
        if let destination { try fm.copyItem(at:source,to:destination) }
        if model.inlineNote == nil { model.beginInlineNote(path,offset:start,mode:.paragraph) }
        guard let draft = model.inlineNote, draft.path == path, draft.text == body else { throw Failure("无法更新图片引用。") }
        draft.text = (body as NSString).replacingCharacters(in:range,with:replacement)
        draft.caret = start
        guard model.finishInlineNote() else { throw Failure("无法保存图片引用，已保留原文件。") }
        try fm.trashItem(at:source,resultingItemURL:nil)
    }
}
