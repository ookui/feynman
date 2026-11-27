import AppKit

enum Action: String, CaseIterable, Identifiable {
    case preflight = "预研", question = "追问", revise = "修订", publish = "回写", archive = "资料入库", company = "个股"
    var id: Self { self }
    var prompt: String {
        switch self {
        case .preflight: return "开展专题预研。先检查已有成果，补齐预研报告、关键问题、概念、实体、事件与参考资料。"
        case .question: return "结合项目资料回答这个问题。按问题本身的推理链写成连贯的论证：开头直接给出结论、把握程度和最关键的理由；证据和反证写在它们各自支撑或针对的那一环，注明日期、口径和出处，并说明反证是否改变结论；点明论证中最薄弱的一环；结尾只写会改变结论的未知事项及取得途径。不使用「当前结论」「支持证据」「反证」「缺口」「跟踪记录」等固定小节；需要分段时，小标题按内容命名。用具体数字、机制和可比案例把道理讲清楚，不用排比和渲染。"
        case .revise: return "结合项目资料修订所选内容，保留仍然成立的事实和来源。"
        case .archive: return "调用 LakeHouse 的归档流程，将所选原始资料保存到 Library。"
        case .publish: return "根据知识库现行规范，将所选研究成果写回适合的位置，记录来源项目和原文件，回读核对并更新研究日志。"
        case .company: return "按个股研究 skill 执行所选动作，只写当前公司目录；同步命题时按知识库规范写入 Theses。"
        }
    }
}
// Each edit refers to the same original Markdown, including when several sections move.
struct TextRevision: Decodable {
    struct Edit: Decodable { let original: String; let revised: String }
    let edits: [Edit]
    var answer: String? = nil

    func applying(to body: String) throws -> String {
        let source = body as NSString
        var changes: [(NSRange, String)] = []
        for edit in edits {
            let match = source.range(of: edit.original, options: .literal)
            let last = source.range(of: edit.original, options: [.literal, .backwards])
            guard !edit.original.clean.isEmpty, match.location != NSNotFound, match == last else {
                throw Failure("无法唯一定位修订段落，已保留原文。")
            }
            changes.append((match, edit.revised))
        }
        let result = NSMutableString(string: body)
        var boundary = source.length
        for (range, revised) in changes.sorted(by: { $0.0.location > $1.0.location }) {
            guard NSMaxRange(range) <= boundary else { throw Failure("修订段落重叠，已保留原文。") }
            result.replaceCharacters(in: range, with: revised)
            boundary = range.location
        }
        guard !(result as String).clean.isEmpty else { throw Failure("整合稿为空，已保留原文。") }
        return result as String
    }
}

enum ResearchTarget {
    case entry(Entry)
    case archive(id: String, source: String, localFile: URL?, lakehouse: URL, prefix: String)
    case report(path: String, original: String, destination: String)

    static func report(_ path: String, in project: ProjectAt, reports: [String]) throws -> ResearchTarget {
        guard reports.contains(path), let original = try Files.contents(Files.child(project.url, path)) else { throw Failure("找不到待修订的报告。") }
        let versions = reports.compactMap { path -> Int? in
            guard path.hasPrefix("reports/base-v"), path.hasSuffix(".md") else { return nil }
            return Int(path.dropFirst("reports/base-v".count).dropLast(3))
        }
        return .report(path: path, original: original, destination: "reports/base-v" + String((versions.max() ?? 1) + 1) + ".md")
    }

    // The excerpt or personal note preceding a question's answer stays outside the editable text.
    private var revisionText: (path: String, prefix: String, body: String)? {
        switch self {
        case .entry(let entry):
            if entry.kind == .questions {
                if let heading = entry.body.range(of: #"(?m)^## (?:解答|回答)[ \t]*$"#, options: .regularExpression) {
                    let tail = entry.body[heading.upperBound...]
                    let spacing = tail.prefix { $0.isNewline }
                    let prefix = String(entry.body[..<heading.upperBound]) + (spacing.isEmpty ? "\n\n" : String(spacing))
                    return (entry.path, prefix, String(tail.dropFirst(spacing.count)))
                }
                if !entry.answered, entry.questionHistory.isEmpty, entry.origin == "报告划选", !entry.body.clean.isEmpty {
                    return (entry.path, entry.body + "\n\n## 解答\n\n", "")
                }
            }
            return (entry.path, "", entry.body)
        case .report(let path, let original, _): return (path, "", Document(original).body)
        case .archive: return nil
        }
    }

    var isQuestion: Bool {
        if case .entry(let entry) = self { return entry.kind == .questions }
        return false
    }

    var responseSchema: String? {
        if isQuestion { return "question-response-schema.json" }
        return requiresTextEdits ? "revision-schema.json" : nil
    }

    func turnAnswer(_ response: String) throws -> String {
        guard let answer = decode(TextRevision.self, response.clean)?.answer, !answer.clean.isEmpty else {
            throw Failure("未收到本轮完整回答，原总结与追问记录已保留。")
        }
        return answer
    }

    var requiresTextEdits: Bool { revisionText.map { !$0.body.clean.isEmpty } ?? false }

    func submission(_ request: String) -> String {
        guard let text = revisionText else { return request }
        let task = request + "\n\n工作台将保存本轮结果。请先通读项目文件 " + text.path + " 的完整原文和已有问答。研究用户补充的问题，将答案融入相应论点，串联结论、证据及限定条件。保留仍成立的事实、数据、出处链接和手工笔记；有证据推翻旧判断时交代理由。合并重复论述和旧版逐轮问答。直接陈述整合后的判断，每条信息只讲一次，省去对修改过程的说明。"
        let history = isQuestion ? "另外，在 JSON 的 answer 字段中给出针对本轮用户问题的完整 Markdown 回答，包含本轮的解释、证据与出处，供用户逐轮回看。edits 用于更新整合总结。question_history 是历史记录，仅供参考。" : ""
        guard !text.body.clean.isEmpty else {
            return task + (isQuestion ? "只输出 JSON 对象，edits 为空数组，answer 为本轮完整 Markdown 回答。" : "只返回新回答的 Markdown 正文。")
        }
        return task + """
        
        按原文提交局部修订。仅输出 JSON 对象，edits 数组的每项含 original 和 revised 两个字符串。original 必须逐字引用原 Markdown 中唯一出现的连续文字，revised 写入整合后的 Markdown。补充观点时在对应段落中融入新内容；需要去重或重排时可修改多处。各处均以本轮开始时的原文为准，不能重叠。未涉及的段落由工作台原样保留。编辑范围仅限正文，不含文件元数据。
        """ + history + (text.prefix.isEmpty ? "" : "问题的回答标题及其之前的引文和备注由工作台保留，只修订标题之后的回答。")
    }

    func materializedAnswer(_ response: String) throws -> String {
        guard let text = revisionText else { return response }
        if text.body.clean.isEmpty {
            guard !response.clean.isEmpty else { throw Failure("研究终端没有返回正文。") }
            return text.prefix + (isQuestion ? try turnAnswer(response) : response)
        }
        guard let revision = decode(TextRevision.self, response.clean) else {
            throw Failure("未收到可合并到原文的修订，已保留原文。")
        }
        return text.prefix + (try revision.applying(to: text.body))
    }

    func save(_ answer: String, in project: ProjectAt, turn: ResearchTurn? = nil) throws -> String {
        guard !answer.clean.isEmpty else { throw Failure("研究终端没有返回正文。") }
        switch self {
        case .archive(let id, let source, let localFile, let lakehouse, let prefix):
            struct Receipt: Decodable { var libraryPath: String }
            guard let path = decode(Receipt.self, answer.clean)?.libraryPath, path.hasPrefix("Library/") else {
                throw Failure("没有收到 Library 文件路径，原引用已保留。")
            }
            let destination = try Files.child(lakehouse, path)
            let library = try Files.child(lakehouse, "Library")
            let info = try destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard destination.path.hasPrefix(library.path + "/"), info.isRegularFile == true, (info.fileSize ?? 0) > 0 else {
                throw Failure("未找到已归档的 Library 文件，原引用已保留。")
            }
            let snapshot = try Files.scan(project.url)
            guard var item = snapshot.resolve(id), item.id == id, item.kind == .references else { throw Failure("参考资料已删除或合并。") }
            let link = prefix + path
            if item.archivedSources[source] == link { try Files.updateArchivedAssets(in: project.url); return "资料已保存到 " + path }
            guard item.archivedSources[source] == nil,
                  source == "project:" + item.path || snapshot.materialSources[id]?.contains(source) == true else {
                throw Failure("原资料引用已修改，请重新选择。")
            }
            if let localFile, !fm.contentsEqual(atPath: localFile.path, andPath: destination.path) {
                throw Failure("Library 文件与所选原件内容不一致，原引用已保留。")
            }
            item.assets.removeAll { $0 == source }
            if !item.assets.contains(link) { item.assets.append(link) }
            item.archivedSources[source] = link
            try Files.write(item, in: project.url)
            try Files.updateArchivedAssets(in: project.url)
            return "资料已保存到 " + path + "，项目引用已更新"
        case .entry(let start):
            guard var item = try Files.scan(project.url).resolve(start.id), item.id == start.id,
                  item.path == start.path, item.title == start.title, item.body == start.body,
                  item.questionHistory == start.questionHistory else {
                throw Failure("研究期间条目已被编辑、合并或删除。回答已单独保留。")
            }
            item.body = answer
            if item.kind == .questions {
                if let turn, !item.questionHistory.contains(where: { $0.id == turn.id }) { item.questionHistory.append(turn) }
            }
            try Files.write(item, in: project.url)
            return item.kind == .questions ? "回答已保存到当前问题" : "已更新条目正文"
        case .report(let path, let original, let destination):
            guard try Files.contents(Files.child(project.url, path)) == original else { throw Failure("原报告已修改。修订稿已单独保留。") }
            try Files.save(Files.child(project.url, destination), Document(original).header + answer, expected: nil)
            return "修订稿已保存到 " + destination
        }
    }
}

enum ResearchProvider: String, CaseIterable {
    case codex = "Codex", gemini = "Gemini", claude = "Claude"
    static var selected: Self { Self(rawValue: UserDefaults.standard.string(forKey: "researchProvider") ?? "") ?? .codex }
    var binary: String { rawValue.lowercased() }
    var pathKey: String { self == .codex ? "cli" : "cli." + binary }
    /// Non-interactive Claude runs cannot answer permission prompts, so every tool the research needs is pre-approved.
    /// The set stays read-only: no Edit/Write tools, and Bash is limited to the data scripts of the search and Alpha派 skills.
    static let claudeTools = "Read,Grep,Glob,WebSearch,WebFetch,Skill,Bash"
    static let claudeAllowed = ["Read", "Grep", "Glob", "WebSearch", "WebFetch", "Skill",
                                "mcp__claude_ai_Tavily", "mcp__claude_ai_Exa", "mcp__anysearch",
                                "Bash(python3 *alphapai_client.py*)", "Bash(python *alphapai_client.py*)",
                                "Bash(python3 *anysearch_cli.py*)", "Bash(python *anysearch_cli.py*)"]
    /// Extra rules, comma separated, e.g. `defaults write local.feynman.research claude.allowedTools "mcp__wind-tools"`.
    static func claudeResearch(knowledge: URL?) -> [String] {
        let extra = (UserDefaults.standard.string(forKey: "claude.allowedTools") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var args = ["--tools", claudeTools, "--allowedTools", (claudeAllowed + extra).joined(separator: ",")]
        if let knowledge { args += ["--add-dir", knowledge.path] }
        return args
    }
    func arguments(action: Action, root: URL, project: URL, batch: Bool) -> [String] {
        switch self {
        case .codex: return Terminal.arguments(project: project, root: root, action: action)
        case .claude:
            var args = batch ? ["-p", "--output-format", "text"] : []
            if batch && action != .archive { args += Self.claudeResearch(knowledge: root) }
            else if action == .publish || action == .company { args += ["--add-dir", root.path] }
            if action == .archive { args += ["--add-dir", project.path] }
            return args
        case .gemini:
            var args = batch ? ["--output-format", "text", "--approval-mode", action == .archive ? "default" : "plan"] : []
            if action == .publish || action == .company || action == .archive { args += ["--include-directories", action == .archive ? project.path : root.path] }
            return args
        }
    }
}

enum Terminal {
    static let defaults = UserDefaults.standard
    static func instruction(_ action: Action) -> String {
        let saved = defaults.string(forKey: "prompt." + action.rawValue)
        // Earlier defaults asked for a fixed evidence / counter-evidence / gaps layout; a saved copy of one follows the new default.
        let retired = ["集中回答当前问题。核实证据，说明反证和仍未解决之处，更新问题正文并关联相关条目。", "结合项目资料回答这个问题，给出依据、反证和仍待核实之处。"]
        if action == .question, let saved, retired.contains(saved) { return action.prompt }
        return saved ?? action.prompt
    }
    static func skill(_ action: Action) -> String {
        if action == .question { return "" }
        let configured = defaults.string(forKey: "skill." + action.rawValue)
        if action != .preflight, configured?.trimmingCharacters(in: CharacterSet(charactersIn: "$ ")) == "sling-thematic-study" { return "" }
        if action == .company { return configured ?? "sling-company-study" }
        return configured ?? (action == .preflight ? "sling-thematic-study" : (action == .publish || action == .archive) ? "sling-lakehouse-protocol" : "")
    }
    static func executable(_ override: String, provider: ResearchProvider = .codex) throws -> URL {
        func valid(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return path.hasPrefix("/") && fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue && fm.isExecutableFile(atPath: path)
        }
        if !override.clean.isEmpty {
            let path = (override.clean as NSString).expandingTildeInPath
            guard valid(path) else { throw Failure("所选 CLI 文件不可执行，请在设置中重新选择。") }
            return URL(fileURLWithPath: path)
        }
        let env = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/" + provider.binary }
        let paths = env + ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"].map { $0 + "/" + provider.binary }
        if let found = paths.first(where: valid) { return URL(fileURLWithPath: found) }
        for name in ["Codex","ChatGPT"] where provider == .codex {
            let app = "/Applications/" + name + ".app/Contents/Resources/"
            for suffix in ["codex","codex-cli/CodexCLI.app/Contents/MacOS/codex"] where valid(app + suffix) { return URL(fileURLWithPath: app + suffix) }
        }
        throw Failure("尚未找到 \(provider.rawValue) CLI，请在设置中选择 \(provider.binary) 可执行文件。")
    }
    static func arguments(project: URL, root: URL, action: Action) -> [String] {
        if action == .archive { return ["-C", root.path] }
        var args = ["-C", project.path]
        if action == .publish || action == .company { args += ["--add-dir", root.path] }
        return args
    }
    static func prompt(_ action: Action, project: ProjectAt, root: URL, context: String?, entry: Entry? = nil) throws -> String {
        let guide = """
        本专题已在当前工作目录创建，project.json 载有标题和研究意图。以本目录作为专题的唯一产出位置，读取已有成果后增量操作。知识库根目录为 \(root.path)。遵循所选 skill 的研究方法，项目文件的保存位置与格式按下列约定：
        • reports/base-v1.md 是预研报告；已有版本保留原文，修订另存 base-v2.md 等。引用请给出来源。
        • questions/、concepts/、entities/、events/、references/ 中每个对象独立一个 UTF-8 Markdown。以唯一稳定 ID 命名（如 concept-001），同一项目内跨类型唯一；在开头 --- 分隔的 frontmatter 中写 id、title、origin，字符串使用双引号，origin 为 "预研提取"。正文写解答、定义、简介或事件日期等。新对象自动进入左栏。新问题默认待回答，answered 由用户手动切换。先查同义条目与已合并 aliases、deleted 状态，避免重复或复活已删除项。
        • 报告划选直接创建问题、概念、实体、事件或关联到同类已有条目。将原文位置写入该条目的 anchors。
        • links 是同项目关联 ID 的单行 JSON 数组。创建或补充问题时，关联它实际讨论的概念、实体及事件 ID；任一方向保存一次即可，工作台将双向显示。anchors 是单行 JSON 数组，成员含 report（如 reports/base-v1.md）、section、quote、prefix、suffix，均为字符串，quote 为报告中可见的原文。参考资料 assets 是单行 JSON 数组，用 "library:Library/..." 或 "library:Sources/..." 引用库内相对路径，本项目附件放 references/files/ 并以 "project:references/files/..." 引用。勿把本机绝对路径写入共享文件。每份参考资料只登记一次；报告和条目使用 [来源标题](feynman:参考资料ID) 定位到参考资料汇总页，可用 report_links 单行 JSON 数组关联报告路径。
        • 保留手工内容与现有元数据。memo.md 由用户执笔。log.md 仅追加本轮简记、改动与未解事项。预研的报告和条目均已写入并读回核对后，最后创建或更新 preflight.done。中断后读取现有文件继续。
        """
        var parts: [String] = []
        switch action {
        case .preflight:
            parts = [instruction(action), guide]
        case .question:
            guard let entry, entry.kind == .questions else { throw Failure("请选择要研究的问题。") }
            return questionPrompt(entry)
        case .revise:
            guard let context else { throw Failure("请选择要研究的问题或要修订的内容。") }
            if let entry {
                parts.append("修订「" + entry.title + "」的正文。")
                if !entry.body.clean.isEmpty { parts.append("当前内容（全文见文件）\n" + String(entry.body.prefix(3200))) }
                if !entry.anchors.isEmpty { parts.append("关联原文\n" + entry.anchors.prefix(4).map { $0.report + " · " + String($0.quote.prefix(300)) }.joined(separator: "\n")) }
            } else { parts.append("继续研究专题「" + project.info.title + "」，修订报告 " + context + "。") }
            parts += [instruction(action), "读取 " + context + " 的完整内容、关联条目及出处。把补充问题的答案融入原文，整理成完整、精练的总结。"]
        case .archive: throw Failure("请选择要保存到 Library 的资料。")
        case .company: throw Failure("请从公司首页选择研究动作。")
        case .publish:
            guard let context else { throw Failure("请选择要回写的内容。") }
            parts = ["将「" + (entry?.title ?? context) + "」回写到知识库。", instruction(action),
                     "从项目文件 " + context + " 读取所选成果。知识库根目录为 " + root.path + "。实际完成入库，并在专题中记录目标相对路径与来源之间的引用。"]
        }
        if !skill(action).clean.isEmpty {
            let invocation = "使用 $" + skill(action).clean + " skill。"
            parts.insert(invocation, at: action == .preflight ? 0 : 1)
        }
        parts.append("项目：" + project.info.title + (project.info.intent.isEmpty ? "" : "\n研究意图：" + project.info.intent))
        return parts.joined(separator: "\n\n")
    }
    static func questionPrompt(_ entry: Entry, followUp: String? = nil) -> String {
        var parts = [entry.title]
        if let followUp { parts.append("本轮追问\n" + followUp) }
        parts.append("直接回答本轮问题。不要调用研究 skill 或启动专题预研。")
        if followUp == nil, !entry.body.clean.isEmpty {
            parts.append("当前内容\n" + String(entry.body.prefix(3200)))
        }
        if !entry.anchors.isEmpty {
            parts.append("关联原文\n" + entry.anchors.prefix(4).map { $0.report + " · " + String($0.quote.prefix(300)) }.joined(separator: "\n"))
        }
        parts += [instruction(.question), "先读取 " + entry.path + " 中的完整正文、历次问答和相关出处。把本轮发现融入已有回答，放进它所影响的那一环，保留相关证据与出处，合并重复表述。已有正文仍按「当前结论」「支持证据」「反证」「缺口」「跟踪记录」等固定小节组织时，本轮把它整体改写为连贯论证（edits 可用一项引用整段原文），保留全部数字、出处和仍成立的判断。各轮问答由工作台另行保存，正文不追加流水记录。"]
        return parts.joined(separator: "\n\n")
    }
    static func version(_ executable: URL) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = ["--version"]
        process.standardOutput = pipe
        try process.run()
        let result = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("无法读取 CLI 版本。") }
        return String(decoding: result, as: UTF8.self).clean
    }
}
