import SwiftUI
import WebKit
import Darwin

// The slave becomes the child's controlling terminal. Only descriptors 0–2 are inherited.
final class ResearchPTY {
    private let master: Int32
    private let pid: pid_t
    private let reader: DispatchSourceRead
    private let writer = DispatchQueue(label: "Feynman.terminal.input")
    private var finished = false
    private var stopping = false

    init(cli: URL, directory: URL, arguments: [String], inputFile: URL? = nil, outputFile: URL? = nil, cols: Int, rows: Int,
         output: @escaping (Data) -> Void, ended: @escaping (Int32) -> Void) throws {
        var fd: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 1024)
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&fd, &slave, &name, nil, &size) == 0 else { throw Failure("无法创建本机终端。") }
        defer { close(slave) }
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        guard let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("FeynmanTTY") else {
            close(fd); throw Failure("无法定位终端组件。")
        }
        let command = outputFile != nil ? #"input_file="$1"; answer_file="$2"; shift 2; exec "$@" < "$input_file" > "$answer_file""# : inputFile == nil ? #"exec "$@""# : #"input_file="$1"; shift; exec "$@" < "$input_file""#
        let args = [helper.path, "/bin/zsh", "-lc", command, "feynman"] + (inputFile.map { [$0.path] } ?? []) + (outputFile.map { [$0.path] } ?? []) + [cli.path] + arguments
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let argv = args.map { strdup($0) } + [nil]
        let envp = env.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for p in argv + envp { free(p) } }
        var child: pid_t = 0
        let result = posix_spawn(&child, helper.path, &actions, &attr, argv, envp)
        guard result == 0 else { close(fd); throw Failure("无法启动终端：" + String(cString: strerror(result))) }
        pid = child; master = fd
        reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .userInitiated))
        reader.setEventHandler { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 32768)
            let n = read(fd, &bytes, bytes.count)
            if n > 0 { let data = Data(bytes.prefix(n)); DispatchQueue.main.async { output(data) } }
            else if n == 0 || errno != EINTR { self?.reader.cancel() }
        }
        reader.setCancelHandler { close(fd) }
        reader.resume()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            let result = status
            DispatchQueue.main.async { [weak self] in
                self?.finished = true
                ended(result)
            }
        }
    }

    deinit { reader.cancel() }

    func input(_ bytes: Data) {
        guard !finished, !stopping else { return }
        // A dedicated duplicate remains valid even if the tab closes during a write.
        let fd = dup(master)
        guard fd >= 0 else { return }
        writer.async {
            defer { close(fd) }
            bytes.withUnsafeBytes { buffer in
                var sent = 0
                while sent < buffer.count {
                    let n = write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                    if n > 0 { sent += n } else if n == -1 && errno == EINTR { continue } else { break }
                }
            }
        }
    }
    func resize(cols: Int, rows: Int) {
        guard !finished, !stopping else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }
    func stop() {
        guard !finished, !stopping else { return }
        stopping = true
        kill(-pid, SIGHUP)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            if !finished { kill(-pid, SIGKILL) }
        }
        reader.cancel()
    }
}

@MainActor final class ResearchSession: NSObject, ObservableObject, Identifiable, WKScriptMessageHandler, WKNavigationDelegate {
    let id = UUID()
    let project: ProjectAt
    let action: Action
    let context: String?
    let provider: ResearchProvider
    let directory: URL
    let cli: URL
    let arguments: [String]
    let draft: String
    @Published var status = "正在打开终端"
    enum Phase { case draft, running, followUp, stopping, exited }
    @Published private(set) var phase = Phase.draft
    var exited: Bool { phase == .exited }
    var handlesEscape: Bool { exited || action == .question }
    private(set) var target: ResearchTarget?
    private var pendingTurn: ResearchTurn?
    var onSaved: (() -> Void)?
    private let runDirectory = fm.temporaryDirectory.appendingPathComponent("Feynman-run-" + UUID().uuidString)
    private var outputURL: URL { runDirectory.appendingPathComponent("回答.md") }
    @Published private(set) var retainedAnswer: URL?
    private let page: URL?
    private var process: ResearchPTY?
    private(set) var web: WKWebView?
    private var closed = false

    init(project: ProjectAt, root: URL, action: Action, context: String?, cli: URL, provider: ResearchProvider = .codex, draft: String, target: ResearchTarget? = nil, resources: URL? = Bundle.main.resourceURL) {
        self.project = project; self.action = action; self.context = context
        self.provider = provider
        directory = action == .archive && provider != .codex ? root : project.url
        self.cli = cli; self.draft = draft; self.target = target
        if action == .question, case .entry(let item) = target, item.answered || !item.questionHistory.isEmpty { phase = .followUp }
        page = resources?.appendingPathComponent("console.html")
        arguments = provider.arguments(action: action, root: root, project: project.url, batch: target != nil)
    }
    func view() -> WKWebView {
        if let web { return web }
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "console")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        self.web = view
        if let html = page {
            view.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        return view
    }
    func closeSession() {
        closed = true
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "console")
        process?.stop()
        web = nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.standardizedFileURL == page?.standardizedFileURL ? .allow : .cancel)
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closed, message.frameInfo.isMainFrame, let msg = message.body as? [String: Any] else { return }
        let cols = min(1000, max(10, msg["cols"] as? Int ?? 80))
        let rows = min(400, max(4, msg["rows"] as? Int ?? 16))
        switch msg["action"] as? String {
        case "ready":
            if exited { showExit(status); return }
            if phase == .followUp { offerFollowUp(); return }
            guard phase == .draft else { return }
            if let value = try? json(draft) { web?.evaluateJavaScript("setDraft(" + value + ")" + (action == .archive ? "; submit()" : "")) }
            status = "提示词可编辑 · 等待发送"
        case "submit":
            guard phase == .draft || phase == .followUp, let text = msg["text"] as? String, !text.clean.isEmpty else { return }
            do {
                var prompt = text
                if action == .question, case .entry(let entry) = target {
                    pendingTurn = ResearchTurn(question: phase == .draft && text == draft ? entry.title : text, answer: "")
                }
                if phase == .followUp {
                    guard case .entry(let previous) = target,
                          let item = try Files.scan(project.url).resolve(previous.id), item.id == previous.id,
                          item.kind == .questions, item.path == context else { throw Failure("问题已合并、移动或删除，请重新选择。") }
                    target = .entry(item)
                    prompt = Terminal.questionPrompt(item, followUp: text)
                }
                var args = arguments
                var input: URL?
                if let target {
                    prompt = target.submission(prompt)
                    try fm.createDirectory(at: runDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    let file = runDirectory.appendingPathComponent("prompt.txt")
                    try Data(prompt.utf8).write(to: file, options: .atomic)
                    input = file
                    if provider == .codex {
                        args += ["exec", "--sandbox", action == .archive ? "workspace-write" : "read-only", "--skip-git-repo-check"]
                        if let schema = target.responseSchema, let page {
                            args += ["--output-schema", page.deletingLastPathComponent().appendingPathComponent(schema).path]
                        }
                        args += ["--output-last-message", outputURL.path, "-"]
                    } else if provider == .gemini {
                        args += ["-p", "执行标准输入中的任务。"]
                    }
                } else {
                    args += provider == .gemini ? ["--prompt-interactive", text] : ["--", text]
                }
                process = try ResearchPTY(cli: cli, directory: directory, arguments: args, inputFile: input, outputFile: input != nil && provider != .codex ? outputURL : nil, cols: cols, rows: rows) { [weak self] data in
                    self?.web?.evaluateJavaScript("receive('" + data.base64EncodedString() + "')")
                } ended: { [weak self] code in self?.finish(code) }
                phase = .running
                status = action == .archive ? "正在归档 · 完成后更新引用" : target == nil ? provider.rawValue + " CLI" : "研究中 · 完成后自动保存"
            } catch { showExit(error.localizedDescription); try? fm.removeItem(at: runDirectory) }
        case "resize": process?.resize(cols: cols, rows: rows)
        case "input":
            if let value = msg["data"] as? String { process?.input(Data(value.utf8)) }
        default: break
        }
    }
    private func offerFollowUp() {
        phase = .followUp
        status = "回答已保存 · 可继续追问"
        web?.evaluateJavaScript("offerFollowUp()")
    }
    private func showExit(_ message: String) {
        phase = .exited
        status = message
        if let value = try? json(message) { web?.evaluateJavaScript("showExit(" + value + ")") }
    }
    func endConversation() {
        guard action == .question, !exited, phase != .stopping else { return }
        if phase == .running, let process {
            phase = .stopping
            status = "正在结束 " + provider.rawValue
            process.stop()
        } else {
            showExit("本次对话已结束")
        }
    }
    private func finish(_ code: Int32) {
        try? fm.removeItem(at: runDirectory.appendingPathComponent("prompt.txt"))
        defer { if retainedAnswer == nil { try? fm.removeItem(at: runDirectory) } }
        guard !closed else { return }
        if phase == .stopping { showExit(provider.rawValue + " 已退出"); return }
        guard code == 0 else { showExit(provider.rawValue + " 已中断，详见终端"); return }
        guard let target else { showExit(provider.rawValue + " 已退出"); onSaved?(); return }
        do {
            let response = try String(contentsOf: outputURL, encoding: .utf8)
            if target.isQuestion { pendingTurn?.answer = try target.turnAnswer(response) }
            let body = try target.materializedAnswer(response)
            let retained = pendingTurn.map { "## 本轮问题\n\n" + $0.question + "\n\n## 本轮回答\n\n" + $0.answer + "\n\n## 整合总结\n\n" + body } ?? body
            if retained != response { try Data(retained.utf8).write(to: outputURL, options: .atomic) }
            let message = try target.save(body, in: project, turn: pendingTurn)
            onSaved?()
            if action == .question { offerFollowUp() }
            else { showExit(message) }
        } catch {
            if fm.fileExists(atPath: outputURL.path) {
                retainedAnswer = outputURL
                do {
                    let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    let folder = support.appendingPathComponent("Feynman/未写入的回答")
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    let copy = folder.appendingPathComponent(id.uuidString + ".md")
                    try fm.moveItem(at: outputURL, to: copy)
                    retainedAnswer = copy
                    try? fm.removeItem(at: runDirectory)
                } catch { /* The original reply remains available in the session directory. */ }
            }
            showExit(error.localizedDescription)
        }
    }

}

struct ConsoleWebView: NSViewRepresentable {
    let session: ResearchSession
    func makeNSView(context: Context) -> WKWebView { session.view() }
    func updateNSView(_ web: WKWebView, context: Context) {}
}

struct ResearchPanel: View {
    @ObservedObject var model: Workspace
    @ObservedObject var session: ResearchSession
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("终端", systemImage: "terminal").font(.headline)
                Menu {
                    ForEach(model.consoles.filter { $0.project.id == session.project.id }) { candidate in
                        Button(candidate.action.rawValue + " · " + (candidate.context ?? candidate.project.info.title)) {
                            model.selectedConsole = candidate.id
                        }
                    }
                } label: { Text(session.action.rawValue + " · " + (session.context.map { model.snapshot.entry(at: $0)?.title ?? $0 } ?? session.project.info.title)).lineLimit(1) }
                .fixedSize(horizontal: false, vertical: true)
                Text(session.status).foregroundStyle(.secondary).font(.caption).lineLimit(1)
                if let url = session.retainedAnswer { Button(session.action == .archive ? "查看归档结果" : "查看保留的回答") { NSWorkspace.shared.open(url) } }
                Spacer()
                Button { model.selectedConsole = nil } label: { Image(systemName:"chevron.down") }.help("收起终端，保留会话")
                Button { model.closeConsole(session) } label: { Image(systemName:"xmark") }.help("关闭本次终端会话")
            }.padding(.horizontal,12).frame(height:34).buttonStyle(.borderless)
            ConsoleWebView(session: session).id(session.id)
        }
    }
}
