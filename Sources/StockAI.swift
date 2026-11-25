import SwiftUI

/// Only provider answer events are eligible for a section body. Diagnostics and tool output stay separate.
struct StockAnswerStream {
    private var pending = Data()
    var text = ""
    var failure: String?

    mutating func consume(_ data: Data, provider: ResearchProvider, final: Bool = false) {
        pending.append(data)
        if final { pending.append(10) }
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]
            pending = Data(pending[pending.index(after: newline)...])
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let type = event["type"] as? String
            switch provider {
            case .codex:
                if let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message",
                   let value = item["text"] as? String { text = value }
                if type == "turn.failed" { failure = (event["error"] as? [String: Any])?["message"] as? String ?? "Codex 研究失败。" }
            case .claude:
                if type == "stream_event", let detail = event["event"] as? [String: Any],
                   let delta = detail["delta"] as? [String: Any], let value = delta["text"] as? String { text += value }
                if type == "result", let value = event["result"] as? String {
                    if event["is_error"] as? Bool == true { failure = value } else { text = value }
                }
            case .gemini:
                if type == "message", event["role"] as? String == "assistant", let value = event["content"] as? String {
                    if event["delta"] as? Bool == true { text += value } else { text = value }
                }
                if type == "result", event["status"] as? String == "error" { failure = (event["error"] as? [String: Any])?["message"] as? String ?? "Gemini 研究失败。" }
            }
        }
    }
}

@MainActor final class StockResearchRun: ObservableObject, Identifiable {
    let id = UUID()
    let company: ProjectAt
    let modules: [StockModule]
    let provider: ResearchProvider
    @Published var instructions: [StockModule: String] = [:]
    @Published var prompt: String
    @Published private(set) var completed = 0
    @Published private(set) var running = false
    @Published private(set) var status = ""
    @Published private(set) var preview = ""
    private weak var workspace: Workspace?
    private var originals: [StockModule: String] = [:]
    private var process: ResearchPTY?
    private var monitor: Task<Void, Never>?
    private var events: FileHandle?
    private var stream = StockAnswerStream()
    private var parser: StockReportParser?
    private var sectionPreviews: [StockModule: String] = [:]
    @Published private(set) var reportFile: URL?
    var wholeReport: Bool { modules.count > 1 }
    private var diagnostics = ""
    private var folder: URL?
    private let knowledge: URL?
    private var generation = UUID()
    var current: StockModule? { modules.dropFirst(completed).first }

    init(workspace: Workspace, company: ProjectAt, module: StockModule?) {
        self.workspace = workspace
        self.company = company
        provider = ResearchProvider.selected
        modules = module.map { [$0] } ?? StockModule.allCases
        let template = modules.map(\.template).joined(separator: "\n\n")
        let linked = workspace.projects.filter { topic in company.info.stock?.links.contains { $0.projectID == topic.id } == true }.map { $0.info.title }
        let knowledge = workspace.root
        self.knowledge = knowledge
        let materials = Self.materials(company.url)
        var context = ["研究公司：\(company.stockLabel)", "研究范围：\(module?.heading ?? "全公司深研")", "截至日期：\(Date().formatted(.iso8601.year().month().day()))"]
        if !linked.isEmpty { context.append("关联专题：" + linked.joined(separator: "、")) }
        if let model = workspace.stockBook.mainModel { context.append("主财务模型：" + model) }
        let local = materials.isEmpty
            ? "工作目录为本公司的深研目录，目前没有已有章节或资料，直接依据外部资料研究。"
            : "工作目录为本公司的深研目录。先读取已有资料：" + materials.joined(separator: "、") + "。保留已有正文中的有效研究、图片、证据链接与手工记录。" + (materials.contains("analysis/business.md") ? "业务拆分及竞争格局以 analysis/business.md 的当前正文为准。" : "")
        let library = knowledge.map { "知识库根目录为 " + $0.path + "，可读取其中与本公司及关联专题相关的 Theses、Sources、Mechanisms 和 Library 资料。" } ?? ""
        prompt = context.joined(separator: "\n") + "\n" + local + library + """

        外部资料按 sling-search 的路由检索（anysearch、Tavily、Exa）；卖方研报、会议纪要和一致预期使用 alphapai-research；财务数字以公司公告和监管文件（SEC EDGAR、HKEXnews、巨潮资讯）为准，并给出可点击的原文链接。所有数字取自本次读取或检索到的资料，不使用模型记忆中的数据。
        按下列模板写中文投资研究。示例仅用于说明字段，业务和指标应适配本公司。给出日期、财年、币种、单位、盈利口径和来源，区分披露、一致预期和自己的估算。检索后仍无法取得的数字，在对应位置标明缺口及其对结论的影响。报告只写研究内容，不描述会话、工具、权限或检索过程。不得编造用户的持仓、交易、预期差或当时的决策。只返回 Markdown，文件由 Feynman 保存。

        \(template)
        """
        if module == nil {
            prompt += """

            一次返回完整 Markdown 报告，按 0–13 的顺序逐字使用模板中的二级标题，每章均写正文。章内小标题用三级或更深层级。末尾独占一行写 <!-- feynman-report-end -->。
            图片、动图、SVG、表格、图表代码及其说明与引用保留在所属章节。已有本地图像和附件沿用有效路径，所有相对链接均以公司 analysis/ 目录为基准。没有实际文件的图示可用自包含 SVG 或 Mermaid。跨章节链接请使用以下 Markdown 文件名。
            """ + "\n" + modules.map { $0.heading + " → " + ($0.note! as NSString).lastPathComponent }.joined(separator: "\n")
            prompt += "\n第 10、12 章只写有依据的新增记录，没有新增时仅写 [无新增]。"
        }
    }

    /// Lists only materials that exist, so the prompt never asks the model to read missing files.
    static func materials(_ company: URL) -> [String] {
        func filled(_ path: String) -> Bool {
            guard let text = try? Files.contents(company.appendingPathComponent(path)) else { return false }
            return !text.clean.isEmpty
        }
        func populated(_ folder: String) -> Bool {
            let items = (try? fm.contentsOfDirectory(atPath: company.appendingPathComponent(folder).path)) ?? []
            return items.contains { !$0.hasPrefix(".") }
        }
        var found = ["project.json"]
        if filled("research.json") { found.append("research.json") }
        found += StockModule.allCases.compactMap(\.note).filter(filled)
        found += ["references", "documents"].filter(populated).map { $0 + "/" }
        return found.count == 1 ? [] : found
    }

    func instruction(for module: StockModule) -> String {
        if let edited = instructions[module] { return edited }
        let policy = module.appendOnly ? "只提交有依据、尚未记录的新增条目。无新增时仅返回 [无新增]。决策日志仅可使用用户明确提供的实际决策。" : "提交该节可独立阅读的完整正文。保留已有的有效细节、引文与图片，并使用相对于目标文件的链接。"
        return "本次写入第「" + module.heading + "」节（" + (module.note ?? "") + "）。" + policy + " 不重复最外层章节标题，不输出其他章节。"
    }

    func start() {
        guard !running, current != nil, !prompt.clean.isEmpty, let workspace, workspace.finishInlineNote() else { return }
        do {
            let cli = try Terminal.executable(UserDefaults.standard.string(forKey: provider.pathKey) ?? "", provider: provider)
            for module in modules.dropFirst(completed) {
                originals[module] = try Files.contents(Files.child(company.url, module.note!))
            }
            if wholeReport { parser = try StockReportParser() }
            sectionPreviews = [:]
            reportFile = nil
            running = true
            try launch(cli)
        } catch { finish(error.localizedDescription) }
    }

    private func launch(_ cli: URL) throws {
        guard let module = current else { finish("研究完成，已处理全部章节。"); return }
        try checkCompany()
        let run = fm.temporaryDirectory.appendingPathComponent("Feynman-stock-" + UUID().uuidString)
        try fm.createDirectory(at: run, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        folder = run
        let input = run.appendingPathComponent("prompt.txt"), output = run.appendingPathComponent("events.jsonl")
        let request = wholeReport ? prompt : prompt + "\n\n" + instruction(for: module)
        try Data(request.utf8).write(to: input)
        try Data().write(to: output)
        events = try FileHandle(forReadingFrom: output)
        let args: [String]
        switch provider {
        case .codex:
            args = ["--search", "-C", company.url.path, "exec", "--sandbox", "read-only", "--skip-git-repo-check", "--json", "--output-last-message", run.appendingPathComponent("answer.md").path, "-"]
        case .claude:
            args = ["-p", "--verbose", "--output-format", "stream-json", "--include-partial-messages"] + ResearchProvider.claudeResearch(knowledge: knowledge)
        case .gemini:
            args = ["--output-format", "stream-json", "--approval-mode", "plan", "-p", "执行标准输入中的研究任务。"]
        }
        generation = UUID()
        let token = generation
        stream = StockAnswerStream(); diagnostics = ""; preview = ""
        status = wholeReport ? "正在生成完整报告" : "正在研究 " + module.heading
        process = try ResearchPTY(cli: cli, directory: company.url, arguments: args, inputFile: input, outputFile: output, cols: 100, rows: 24) { [weak self] bytes in
            guard let self, generation == token else { return }
            diagnostics = String((diagnostics + String(decoding: bytes, as: UTF8.self)).suffix(1500))
        } ended: { [weak self] code in
            guard let self, generation == token, running else { return }
            do {
                try readEvents(final: true)
                if let failure = stream.failure { throw Failure(failure) }
                guard code == 0 else { throw Failure(diagnostics.clean.isEmpty ? provider.rawValue + " 未能完成此节，请检查登录状态和 AI 设置。" : diagnostics.clean) }
                let answer = provider == .codex ? try Files.contents(run.appendingPathComponent("answer.md")) : stream.text
                guard let answer, !answer.clean.isEmpty else { throw Failure("没有收到完整正文，此节未写入。") }
                preview = answer
                try checkCompany()
                let version = try Files.child(company.url, "versions/AI/" + UUID().uuidString)
                let sections: [StockModule: String]
                if let parser {
                    try fm.createDirectory(at: version, withIntermediateDirectories: true)
                    let raw = version.appendingPathComponent("report.md")
                    try Files.save(raw, answer, expected: nil)
                    reportFile = raw
                    sections = try parser.sections(answer, final: true)
                } else { sections = [module: answer] }
                try save(sections, version: version)
                completed = modules.count
                if workspace?.project?.id == company.id { workspace?.refresh() }
                finish(wholeReport ? "全文已按模板写入 14 个章节。" : "本章研究已保存。")
            } catch { finish(error.localizedDescription) }
        }
        monitor = Task { [weak self] in
            while let self, !Task.isCancelled, generation == token {
                do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation(); try readEvents() }
                catch { return }
            }
        }
        workspace?.objectWillChange.send()
    }

    private func readEvents(final: Bool = false) throws {
        stream.consume(try events?.readToEnd() ?? Data(), provider: provider, final: final)
        if preview != stream.text {
            preview = stream.text
            if let parser {
                sectionPreviews = (try? parser.sections(preview, final: false)) ?? [:]
                status = "正在生成完整报告 · 已识别 " + String(sectionPreviews.count) + " / " + String(modules.count) + " 章"
            }
            if workspace?.project?.id == company.id { workspace?.objectWillChange.send() }
        }
    }

    private func checkCompany() throws {
        let raw = try Files.contents(Files.child(company.url, "project.json"))
        guard decode(Project.self, raw)?.id == company.id else { throw Failure("公司目录已移动或变更，请重新打开公司。") }
    }

    private func save(_ sections: [StockModule: String], version: URL) throws {
        struct Edit {
            let file: URL
            let path: String
            let old: String?
            let new: String
        }
        try Files.locked(company.url) {
            var edits: [Edit] = []
            for module in modules {
                guard let answer = sections[module], let path = module.note else { throw Failure("缺少章节：" + module.heading) }
                if module.appendOnly && answer.clean == "[无新增]" { continue }
                let file = try Files.child(company.url, path)
                let old = originals[module]
                guard !(workspace?.inlineNote?.project.id == company.id && workspace?.inlineNote?.path == path),
                      try Files.contents(file) == old else { throw Failure(module.heading + " 正在编辑或已修改，本次结果未写入。") }
                let doc = Document(old ?? "")
                let prefix = module.appendOnly && !doc.body.isEmpty ? doc.body + "\n\n" : ""
                let new = doc.header + prefix + answer + (answer.hasSuffix("\n") ? "" : "\n")
                if old != new { edits.append(Edit(file: file, path: path, old: old, new: new)) }
            }
            for edit in edits {
                if let old = edit.old {
                    let backup = try Files.child(version, edit.path)
                    try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Files.save(backup, old, expected: nil)
                }
            }
            var saved: [Edit] = []
            do {
                for edit in edits {
                    try fm.createDirectory(at: edit.file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Files.save(edit.file, edit.new, expected: edit.old)
                    saved.append(edit)
                }
            } catch {
                var conflicts: [String] = []
                for edit in saved.reversed() {
                    do {
                        if let old = edit.old { try Files.save(edit.file, old, expected: edit.new) }
                        else if try Files.contents(edit.file) == edit.new { try fm.removeItem(at: edit.file) }
                        else { conflicts.append(edit.path) }
                    } catch { conflicts.append(edit.path) }
                }
                if !conflicts.isEmpty { throw Failure("恢复时文件发生变更，请对照原稿检查 " + conflicts.joined(separator: "、")) }
                throw error
            }
        }
    }

    func liveText(module: StockModule, original: String) -> String? {
        guard running else { return nil }
        let text = wholeReport ? sectionPreviews[module] : (current == module ? preview : nil)
        guard let text, !text.isEmpty else { return nil }
        if module.appendOnly {
            if text.clean == "[无新增]" { return original }
            return original + (original.isEmpty ? "" : "\n\n") + text
        }
        return text
    }

    private func releaseRun() {
        monitor?.cancel(); monitor = nil
        try? events?.close(); events = nil
        process = nil
        if let folder { try? fm.removeItem(at: folder); self.folder = nil }
    }
    private func finish(_ message: String) {
        running = false; status = message
        releaseRun()
        workspace?.objectWillChange.send()
    }
    func cancel() {
        guard running else { return }
        generation = UUID()
        process?.stop()
        finish("研究已停止，本次生成未写入。")
    }
}

extension Workspace {
    func prepareStockResearch(_ module: StockModule?) {
        guard let company = project, company.info.stock != nil, finishInlineNote() else { return }
        if let job = stockRun, job.running { dialog = .stockResearch(job.id); return }
        let job = StockResearchRun(workspace: self, company: company, module: module)
        stockRun = job
        dialog = .stockResearch(job.id)
    }
}

struct StockResearchButton: View {
    @ObservedObject var m: Workspace
    var module: StockModule?
    var body: some View {
        Button { m.prepareStockResearch(module) } label: {
            Label(m.stockRun?.running == true ? "AI研究进度" : "AI研究", systemImage: "sparkles")
        }.help(module == nil ? "编辑提示词并研究整家公司" : "编辑提示词并研究本章")
    }
}

struct StockResearchPanel: View {
    @ObservedObject var job: StockResearchRun
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(job.company.stockLabel + " · AI研究").font(.title2.bold())
            Text(job.provider.rawValue + " · " + (job.modules.count == 1 ? job.modules[0].heading : "整家公司 · 14 节")).foregroundStyle(.secondary)
            if !job.running && job.completed < job.modules.count {
                Text("研究提示词").font(.headline)
                TextEditor(text: $job.prompt).font(.body).padding(5).border(.secondary.opacity(0.3))
                if !job.wholeReport, let module = job.current {
                    Text("本章指令").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { job.instruction(for: module) }, set: { job.instructions[module] = $0 }))
                        .font(.callout).padding(4).frame(height: 66).border(.secondary.opacity(0.3))
                }
            }
            if !job.status.isEmpty { Text(job.status).textSelection(.enabled).lineLimit(4) }
            if job.running || !job.preview.isEmpty {
                if job.running { ProgressView().controlSize(.small) }
                ScrollView { Text(verbatim: job.preview).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            HStack {
                if let file = job.reportFile { Button("显示全文原稿") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
                Text("已写入 \(job.completed) / \(job.modules.count) 节").foregroundStyle(.secondary)
                Spacer()
                if job.running { Button("停止研究") { job.cancel() } }
                Button(job.running ? "后台继续" : "关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                if !job.running, job.current != nil {
                    Button("开始研究") { job.start() }
                        .keyboardShortcut(.defaultAction).disabled(job.prompt.clean.isEmpty)
                }
            }
        }.padding(22).frame(minWidth: 520, idealWidth: 640, minHeight: 400, idealHeight: 510)
    }
}
