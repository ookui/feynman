import SwiftUI

/// One type scale for the company pages: labels, body text and section titles.
enum UI {
    static let label = Font.system(size: 11)
    static let text = Font.system(size: 13)
    static let section = Font.system(size: 13, weight: .semibold)
}

// MARK: - Sidebar

struct CompanyOutline: View {
    @ObservedObject var m: Workspace

    private func row(_ title: String, _ symbol: String, _ category: PageCategory, _ place: Place,
                     count: Int? = nil, alert: Bool = false) -> some View {
        Button { m.go(place) } label: {
            HStack(spacing: 6) {
                Label { Text(verbatim: title).foregroundStyle(ink) } icon: { Image(systemName: symbol).foregroundStyle(category.color) }
                Spacer(minLength: 0)
                if alert { Circle().fill(Color.orange).frame(width: 7, height: 7) }
                if let count { Text(String(count)).font(UI.label).foregroundStyle(.secondary) }
            }
        }.buttonStyle(SidebarLinkStyle(selected: m.place == place, color: category.color, verticalInset: 7))
    }

    /// The question tree uses the same key the workspace expands when a question page opens.
    private var treeKey: String { Kind.questions.rawValue }

    private func item(_ entry: Entry, depth: Int, candidate: Bool = false) -> some View {
        Button { m.go(.entry(entry.id)) } label: {
            HStack(spacing: 5) {
                Text(entry.title).lineLimit(1).foregroundStyle(candidate ? Color.secondary : ink)
                Spacer(minLength: 2)
                if candidate { Text("候选").font(.system(size: 10)).foregroundStyle(CompanyPage.cruxes.category.color) }
                else if entry.answered { Image(systemName: "checkmark").font(.system(size: 9)).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(SidebarLinkStyle(selected: m.place == .entry(entry.id), color: CompanyPage.cruxes.category.color))
            .padding(.leading, CGFloat(10 + 16 * depth)).help(entry.title)
            .contextMenu { EntryActions(m: m, entry: entry) }
    }

    private func disclosure(_ open: Bool, key: String, name: String) -> some View {
        Button { if open { m.expanded.remove(key) } else { m.expanded.insert(key) } } label: {
            Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12)
        }.buttonStyle(SidebarLinkStyle(fullWidth: false, horizontalInset: 2)).help((open ? "收起" : "展开") + name)
    }

    private let flagKey = "checklist"

    var body: some View {
        let cruxes = m.cruxes, candidates = m.candidateCruxes
        let open = m.expanded.contains(treeKey)
        HStack(spacing: 2) {
            disclosure(open, key: treeKey, name: "关键问题")
            Button { m.go(.company(.cruxes)); m.expanded.insert(treeKey) } label: {
                HStack(spacing: 6) {
                    Label { Text(verbatim: CompanyPage.cruxes.title).foregroundStyle(ink) } icon: {
                        Image(systemName: CompanyPage.cruxes.symbol).foregroundStyle(CompanyPage.cruxes.category.color)
                    }
                    Spacer(minLength: 0)
                    if !candidates.isEmpty || m.company.changedDependencies > 0 { Circle().fill(Color.orange).frame(width: 7, height: 7) }
                    Text(String(cruxes.count)).font(UI.label).foregroundStyle(.secondary)
                }
            }.buttonStyle(SidebarLinkStyle(selected: m.place == .company(.cruxes), color: CompanyPage.cruxes.category.color, verticalInset: 7))
                .accessibilityIdentifier("company.cruxes")
        }
        if open {
            ForEach(cruxes) { crux in
                item(crux, depth: 1)
                ForEach(m.subQuestions(of: crux)) { sub in item(sub, depth: 2) }
            }
            ForEach(candidates) { candidate in item(candidate, depth: 1, candidate: true) }
            if cruxes.isEmpty && candidates.isEmpty {
                Text("尚无关键问题").font(UI.label).foregroundStyle(.secondary).padding(.leading, 26).padding(.vertical, 3)
            }
        }
        row(CompanyPage.snapshot.title, CompanyPage.snapshot.symbol, CompanyPage.snapshot.category, .company(.snapshot))
        checklistTree
        row(CompanyPage.scenarios.title, CompanyPage.scenarios.symbol, CompanyPage.scenarios.category, .company(.scenarios), count: m.company.scenarios.scenarios.count)
        row(CompanyPage.timeline.title, CompanyPage.timeline.symbol, CompanyPage.timeline.category, .company(.timeline), count: m.timeline.count)
        row(CompanyPage.reports.title, CompanyPage.reports.symbol, CompanyPage.reports.category, .company(.reports), count: m.snapshot.reports.count)
        row("投资判断", "text.book.closed", .judgment, .judgments, count: m.stockBook.history.count)
        row("References", "folder", .kind(.references), .group(.references),
            count: m.snapshot.entries.filter { $0.kind == .references }.count + m.snapshot.unlistedMaterials.count)
            .modifier(ReferenceFileDrop(m: m))
        if m.snapshot.documents.contains("log.md") { row("过程日志", "list.bullet.rectangle", .log, .doc("log.md")) }
    }
}

extension CompanyOutline {
    /// 排雷清单 with the questions raised from its items nested below, like the key-question tree.
    @ViewBuilder var checklistTree: some View {
        let questions = m.flagQuestions
        let flags = m.checklistItems.filter { m.checkStatus($0) == .flag }.count
        let current = questions.contains { m.place == .entry($0.id) }
        let open = m.expanded.contains(flagKey) || current
        HStack(spacing: 2) {
            disclosure(open, key: flagKey, name: "排雷问题")
            Button { m.go(.company(.checklist)); m.expanded.insert(flagKey) } label: {
                HStack(spacing: 6) {
                    Label { Text(verbatim: CompanyPage.checklist.title).foregroundStyle(ink) } icon: {
                        Image(systemName: CompanyPage.checklist.symbol).foregroundStyle(CompanyPage.checklist.category.color)
                    }
                    Spacer(minLength: 0)
                    if flags > 0 { Circle().fill(Color.orange).frame(width: 7, height: 7) }
                    Text(String(flags)).font(UI.label).foregroundStyle(.secondary)
                }
            }.buttonStyle(SidebarLinkStyle(selected: m.place == .company(.checklist), color: CompanyPage.checklist.category.color, verticalInset: 7))
        }
        if open {
            ForEach(questions) { question in
                let status = m.checklistItems.first { $0.id == question.check }.map { m.checkStatus($0) } ?? .flag
                Button { m.go(.entry(question.id)) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: status.symbol).font(.system(size: 9)).foregroundStyle(status.color)
                        Text(question.title.hasPrefix("排雷：") ? String(question.title.dropFirst(3)) : question.title).lineLimit(1).foregroundStyle(ink)
                        Spacer(minLength: 2)
                        if question.answered { Image(systemName: "checkmark").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(SidebarLinkStyle(selected: m.place == .entry(question.id), color: CompanyPage.checklist.category.color))
                    .padding(.leading, 26).help(question.title)
                    .contextMenu { EntryActions(m: m, entry: question) }
            }
            if questions.isEmpty {
                Text("尚无升级的问题").font(UI.label).foregroundStyle(.secondary).padding(.leading, 26).padding(.vertical, 3)
            }
        }
    }
}

// MARK: - Shared pieces

struct CompanyTaskMenu: View {
    @ObservedObject var m: Workspace
    var body: some View {
        Menu {
            ForEach(CompanyTask.allCases) { task in
                Button(task.title + "…") { m.launchCompany(task) }.help(task.help).disabled(task == .thesis && m.stockBook.history.isEmpty)
            }
        } label: { Label("AI 研究", systemImage: "sparkles") }.fixedSize()
    }
}

private struct FieldText: View {
    let label: String
    let value: String
    var placeholder = "—"
    var lines = 4
    /// When set, the field opens the editor on click; an empty field reads 「点击填写」.
    var edit: (() -> Void)? = nil
    /// Draws the field as a small card, used where several fields sit side by side.
    var boxed = false
    var body: some View {
        Group {
            if let edit {
                Button(action: edit) { content(editable: true) }.buttonStyle(.plain).help("编辑" + label)
            } else { content(editable: false) }
        }
        .padding(boxed ? 10 : 0)
        .background(boxed ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(boxed ? Color.secondary.opacity(0.16) : Color.clear))
    }
    private func content(editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label).font(UI.label).foregroundStyle(.secondary)
                if editable { Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(.tint) }
            }
            if editable { valueText(editable: true) } else { valueText(editable: false).textSelection(.enabled) }
        }.frame(maxWidth: .infinity, alignment: .topLeading).contentShape(Rectangle())
    }
    private func valueText(editable: Bool) -> some View {
        let empty = value.clean.isEmpty
        let style: AnyShapeStyle = empty ? (editable ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)) : AnyShapeStyle(ink)
        return Text(empty ? (editable ? "点击填写" : placeholder) : value.clean).font(UI.text)
            .foregroundStyle(style).lineLimit(lines).multilineTextAlignment(.leading).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RoleTag: View {
    let entry: Entry
    var body: some View {
        switch entry.role {
        case "crux": Tag(text: entry.candidate ? "候选关键问题" : "关键问题", color: PageCategory.kind(.questions).color)
        case "sub": Tag(text: "子问题", color: PageCategory.kind(.questions).color)
        case "flag": Tag(text: "排雷异常", color: CheckStatus.flag.color)
        default: Tag(text: "问题", color: .secondary)
        }
    }
}

private struct SourceLinks: View {
    let links: [SourceLink]
    var body: some View {
        ForEach(Array(links.enumerated()), id: \.offset) { _, link in
            let title = link.title.text.isEmpty ? link.url.text : link.title.text
            if let url = URL(string: link.url.text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                Button { NSWorkspace.shared.open(url) } label: {
                    Text(title + (link.date.text.isEmpty ? "" : " · " + link.date.text)).lineLimit(2).multilineTextAlignment(.leading)
                }.buttonStyle(.link).font(UI.label)
            } else if !title.isEmpty {
                Text(title + (link.date.text.isEmpty ? "" : " · " + link.date.text)).font(UI.label).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Board

struct CompanyHome: View {
    @ObservedObject var m: Workspace
    let company: ProjectAt
    @State private var identityEditor = false

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > 700
            VStack(spacing: 0) {
                PageHeading(title: "关键问题看板", category: .stock, metadata: company.stockLabel,
                            subtitle: company.info.intent.clean.isEmpty ? "" : "为什么现在看：" + company.info.intent.clean) {
                    PageActions {
                        if !m.snapshot.completed {
                            Button { m.launchCompany(.setup) } label: { Label("开题研究", systemImage: "sparkles") }
                                .buttonStyle(ResearchActionStyle()).help(CompanyTask.setup.help)
                        }
                        CompanyTaskMenu(m: m)
                        Button("添加关键问题") { m.newCrux() }
                        Button("编辑公司资料") { identityEditor = true }
                    }
                }
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            CruxBoard(m: m)
                            if !wide { sideCards }
                        }.padding(14)
                    }.frame(maxWidth: .infinity)
                    if wide {
                        ScrollView { sideCards.padding(.vertical, 14).padding(.trailing, 14) }
                            .frame(width: min(310, max(240, geometry.size.width * 0.3)))
                    }
                }
            }
        }.sheet(isPresented: $identityEditor) { StockIdentityEditor(m: m, company: company) }
    }

    private var sideCards: some View {
        VStack(spacing: 10) {
            SnapshotCard(m: m)
            ValuationCard(m: m)
            FlagsCard(m: m)
            JudgmentCard(m: m)
            StockTopics(m: m, company: company)
        }
    }
}

struct CruxBoard: View {
    @ObservedObject var m: Workspace
    var body: some View {
        let candidates = m.candidateCruxes, cruxes = m.cruxes
        VStack(alignment: .leading, spacing: 12) {
            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI 起草的候选问题 · " + String(candidates.count)).font(UI.section)
                    Text("采纳后进入看板。删除的问题保留记录，之后 AI 不会再提。").font(UI.label).foregroundStyle(.secondary)
                }
                cardGrid(candidates)
                Divider()
            }
            Text("关键问题 · " + String(cruxes.count)).font(UI.section)
            if cruxes.isEmpty {
                Text(m.snapshot.completed || !candidates.isEmpty ? "尚无已确认的关键问题。采纳上方候选，或手工添加。" : "尚无关键问题。点「开题研究」由 AI 起草，或手工添加。")
                    .foregroundStyle(.secondary)
            }
            if cruxes.count > 5 { Text("已确认 " + String(cruxes.count) + " 个关键问题，考虑合并或降为子问题。").font(UI.label).foregroundStyle(.orange) }
            cardGrid(cruxes)
            let others = m.otherQuestions
            if !others.isEmpty {
                Divider()
                Text("其他问题 · " + String(others.count)).font(UI.section)
                ForEach(others) { question in
                    Button { m.go(.entry(question.id)) } label: {
                        HStack { Text(question.title).lineLimit(2).foregroundStyle(ink); Spacer(); Text(question.answered ? "已回答" : "待回答").font(UI.label).foregroundStyle(.secondary) }
                    }.buttonStyle(SidebarLinkStyle(color: PageCategory.kind(.questions).color)).contextMenu { EntryActions(m: m, entry: question) }
                }
            }
        }
    }
    private func cardGrid(_ items: [Entry]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(items) { CruxCard(m: m, crux: $0) }
        }
    }
}

struct CruxCard: View {
    @ObservedObject var m: Workspace
    let crux: Entry
    @State private var editing = false
    var body: some View {
        let changed = (m.company.dependencies[crux.id] ?? []).filter { $0.status != .current }
        let events = m.events(affecting: crux)
        let subs = m.subQuestions(of: crux).count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Button { m.go(.entry(crux.id)) } label: {
                    Text(crux.title).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.leading).foregroundStyle(ink).lineSpacing(1)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if crux.candidate { Tag(text: "候选", color: PageCategory.kind(.questions).color) }
                else { QuestionStatusButton(m: m, question: crux) }
            }
            FieldText(label: "市场隐含", value: crux.marketView)
            FieldText(label: "我的判断", value: crux.myView, edit: { editing = true })
            FieldText(label: "判断不同时的影响", value: crux.impact, lines: 3)
            HStack(spacing: 6) {
                if let strength = EvidenceStrength(rawValue: crux.evidence) { Tag(text: strength.label) }
                if subs > 0 { Tag(text: "子问题 " + String(subs)) }
                if !events.isEmpty {
                    let support = events.filter { $0.1.direction == ImpactDirection.support.rawValue }.count
                    let weaken = events.filter { $0.1.direction == ImpactDirection.weaken.rawValue }.count
                    Tag(text: "事件 " + String(events.count) + (support + weaken > 0 ? "（支持 \(support) / 削弱 \(weaken)）" : ""), color: PageCategory.kind(.events).color)
                }
                Spacer(minLength: 0)
            }
            if !changed.isEmpty {
                Label("行业依据已更新 · " + changed.map(\.title).joined(separator: "、"), systemImage: "exclamationmark.circle")
                    .font(UI.label).foregroundStyle(.orange).lineLimit(2)
            }
            if crux.candidate {
                HStack {
                    Button("采纳") { m.confirmCrux(crux.id) }.buttonStyle(Primary())
                    Button("删除") { m.dismissCrux(crux.id) }
                    Spacer()
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(crux.candidate ? PageCategory.kind(.questions).color.opacity(0.55) : Color.secondary.opacity(0.18),
                                                               style: StrokeStyle(lineWidth: 1, dash: crux.candidate ? [4, 3] : [])))
        .contextMenu { EntryActions(m: m, entry: crux) }
        .sheet(isPresented: $editing) { CruxEditor(m: m, question: crux) }
    }
}

struct SnapshotCard: View {
    @ObservedObject var m: Workspace
    var body: some View {
        StockSection(title: "快照") {
            if let s = m.company.snapshot {
                Text(s.stamp).font(UI.label).foregroundStyle(.secondary)
                if let line = s.priceLine { Text(line).font(UI.section) }
                if let line = s.marketCapLine { Text(line).font(UI.text) }
                let valuation = Array((s.valuation ?? []).prefix(3))
                ForEach(valuation.indices, id: \.self) { i in Text(valuation[i].line).font(UI.text) }
                let implied = Array((s.implied ?? []).prefix(2))
                ForEach(implied.indices, id: \.self) { i in Text(implied[i].name.text + "　" + implied[i].value.text).font(UI.text.weight(.medium)) }
                Button("查看快照") { m.go(.company(.snapshot)) }.buttonStyle(.link)
            } else if let issue = m.company.snapshotIssue {
                Text(issue).font(UI.label).foregroundStyle(.red)
            } else {
                Text("尚无快照").foregroundStyle(.secondary)
                Button("刷新快照") { m.launchCompany(.snapshot) }
            }
        }
    }
}

struct ValuationCard: View {
    @ObservedObject var m: Workspace
    var body: some View {
        let book = m.company.scenarios
        StockSection(title: "情景估值") {
            if let w = book.weighted {
                Text("概率加权 " + numberText(w.target) + (book.unit.isEmpty ? "" : " " + book.unit)).font(.title3.weight(.semibold))
                Text("相对现价 " + percentText(w.upside) + " · " + String(book.scenarios.count) + " 个情景").font(UI.text)
                if abs(w.probability - 100) > 0.5 { Text("概率合计 " + numberText(w.probability) + "%").font(UI.label).foregroundStyle(.orange) }
            } else {
                Text(book.scenarios.isEmpty ? "尚未建立情景" : "情景数据不完整").foregroundStyle(.secondary)
            }
            Button(book.scenarios.isEmpty ? "建立情景" : "编辑情景") { m.go(.company(.scenarios)) }.buttonStyle(.link)
        }
    }
}

struct FlagsCard: View {
    @ObservedObject var m: Workspace
    var body: some View {
        let items = m.checklistItems
        let flags = items.filter { m.checkStatus($0) == .flag }
        let watch = items.filter { m.checkStatus($0) == .watch }.count
        let unchecked = items.filter { m.checkStatus($0) == .unchecked }.count
        StockSection(title: "排雷异常") {
            if let issue = m.company.checklistIssue { Text(issue).font(UI.label).foregroundStyle(.red) }
            else if items.isEmpty { Text("尚未运行排雷清单").font(UI.text).foregroundStyle(.secondary) }
            else if flags.isEmpty { Text("共 " + String(items.count) + " 项，无异常").font(UI.text).foregroundStyle(.secondary) }
            ForEach(flags) { item in
                Button {
                    if let question = m.flagQuestions(for: item).first { m.go(.entry(question.id)) } else { m.go(.company(.checklist)) }
                } label: {
                    Label { Text(item.title.text).font(UI.text).lineLimit(2).foregroundStyle(ink) } icon: {
                        Image(systemName: CheckStatus.flag.symbol).foregroundStyle(CheckStatus.flag.color)
                    }
                }.buttonStyle(SidebarLinkStyle(color: CheckStatus.flag.color))
            }
            if watch + unchecked > 0 {
                Text([watch > 0 ? String(watch) + " 项关注" : "", unchecked > 0 ? String(unchecked) + " 项未核查" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(UI.label).foregroundStyle(.secondary)
            }
            if items.isEmpty { Button("运行排雷清单") { m.launchCompany(.checklist) } }
            else { Button("查看清单") { m.go(.company(.checklist)) }.buttonStyle(.link).font(UI.text) }
        }
    }
}

struct JudgmentCard: View {
    @ObservedObject var m: Workspace
    var body: some View {
        StockSection(title: "投资判断") {
            if let latest = m.stockBook.history.first {
                HStack {
                    Text(latest.date.formatted(date: .abbreviated, time: .omitted)).font(UI.label).foregroundStyle(.secondary)
                    if let d = latest.direction.flatMap(JudgmentDirection.init(rawValue:)), d != .none { Tag(text: d.label, color: PageCategory.judgment.color) }
                }
                Text(latest.conclusion).font(UI.section).textSelection(.enabled)
            } else {
                Text(m.stockBook.draft == nil ? "尚未发布判断" : "有一份待发布的草稿").foregroundStyle(.secondary)
            }
            HStack {
                Button(m.stockBook.draft != nil ? "继续编辑草稿" : m.stockBook.history.isEmpty ? "写下首次判断" : "更新判断") {
                    m.attempt { try m.startJudgment() }
                }
                Button("历史") { m.go(.judgments) }.buttonStyle(.link)
            }
        }
    }
}

// MARK: - Pages

struct CompanyPageView: View {
    @ObservedObject var m: Workspace
    let company: ProjectAt
    let page: CompanyPage
    var body: some View {
        switch page {
        case .cruxes: CruxListPage(m: m)
        case .snapshot: SnapshotPage(m: m)
        case .checklist: ChecklistPage(m: m)
        case .scenarios: ScenarioPage(m: m)
        case .timeline: TimelinePage(m: m)
        case .reports: ReportsPage(m: m, company: company)
        }
    }
}

private struct PageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(.horizontal, 24).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CruxListPage: View {
    @ObservedObject var m: Workspace
    var body: some View {
        VStack(spacing: 0) {
            PageHeading(title: "关键问题", category: CompanyPage.cruxes.category, metadata: "每个问题写明市场隐含的假设和判断不同时的股价影响") {
                PageActions {
                    Button("添加关键问题") { m.newCrux() }
                    Button("补充关键问题…") { m.launchCompany(.cruxes) }.help(CompanyTask.cruxes.help)
                }
            }
            Divider()
            PageScroll {
                CruxBoard(m: m)
                ForEach(m.cruxes) { crux in
                    let subs = m.subQuestions(of: crux)
                    if !subs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(crux.title + " · 子问题").font(UI.section)
                            ForEach(subs) { sub in
                                Button { m.go(.entry(sub.id)) } label: {
                                    HStack { Text(sub.title).foregroundStyle(ink).lineLimit(2); Spacer(); Text(sub.answered ? "已回答" : "待回答").font(UI.label).foregroundStyle(.secondary) }
                                }.buttonStyle(SidebarLinkStyle(color: PageCategory.kind(.questions).color)).padding(.leading, 12)
                            }
                        }
                    }
                }
                let dismissed = m.dismissedCruxes.count
                if dismissed > 0 { Text("已删除 " + String(dismissed) + " 个问题，记录保留在 questions/ 中，AI 不会重新起草。").font(UI.label).foregroundStyle(.secondary) }
            }
        }
    }
}

struct SnapshotPage: View {
    @ObservedObject var m: Workspace
    var body: some View {
        let s = m.company.snapshot
        VStack(spacing: 0) {
            PageHeading(title: "快照", category: CompanyPage.snapshot.category, metadata: s?.pageStamp ?? "尚未生成") {
                Button { m.launchCompany(.snapshot) } label: { Label("刷新快照", systemImage: "sparkles") }.buttonStyle(ResearchActionStyle())
            }
            Divider()
            PageScroll {
                if let issue = m.company.snapshotIssue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
                if let s {
                    if !s.positioning.text.isEmpty { Text(s.positioning.text).font(.title3).textSelection(.enabled) }
                    if let line = s.priceLine { Text(line + (s.marketCapLine.map { "　" + $0 } ?? "")).font(UI.section).textSelection(.enabled) }
                    metrics("估值", s.valuation)
                    metrics("反推的隐含预期", s.implied)
                    metrics("一致预期", s.consensus)
                    if let segments = s.segments, !segments.isEmpty { segmentTable(segments) }
                    if let series = s.quarterly, let rows = series.rows, !rows.isEmpty { quarterTable(series.periods ?? [], rows) }
                    list("市场主流说法", s.narrative)
                    list("数据缺口", s.gaps)
                    if let sources = s.sources, !sources.isEmpty {
                        Text("出处").font(UI.section)
                        SourceLinks(links: sources)
                    }
                } else if m.company.snapshotIssue == nil {
                    Text("尚未生成快照。开题时会一并生成，也可以单独刷新。").foregroundStyle(.secondary)
                }
            }
        }
    }
    @ViewBuilder private func metrics(_ title: String, _ items: [CompanySnapshot.Metric]?) -> some View {
        if let items, !items.isEmpty {
            Text(title).font(UI.section)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, metric in
                    GridRow {
                        Text(metric.name.text).foregroundStyle(.secondary)
                        Text(metric.value.text).font(.body.monospacedDigit().weight(.medium))
                        Text(metric.detail).font(UI.label).foregroundStyle(.secondary)
                    }
                }
            }.textSelection(.enabled)
        }
    }
    private func segmentTable(_ segments: [CompanySnapshot.Segment]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("业务分部").font(UI.section)
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { ForEach(["分部", "期间", "收入", "占比", "增速", "利润率", "说明"], id: \.self) { Text($0).bold() } }
                    Divider()
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        GridRow {
                            Text(seg.name.text); Text(seg.period.text); Text(seg.revenue.text).monospacedDigit(); Text(seg.share.text).monospacedDigit()
                            Text(seg.growth.text).monospacedDigit(); Text(seg.margin.text).monospacedDigit(); Text(seg.note.text).font(UI.label).foregroundStyle(.secondary)
                        }
                    }
                }.textSelection(.enabled)
            }
        }
    }
    private func quarterTable(_ periods: [Loose], _ rows: [CompanySnapshot.Row]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("季度序列").font(UI.section)
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("指标").bold()
                        ForEach(Array(periods.enumerated()), id: \.offset) { _, p in Text(p.text).bold() }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name.text)
                                if !(row.unit.text + row.note.text).isEmpty { Text([row.unit.text, row.note.text].filter { !$0.isEmpty }.joined(separator: " · ")).font(UI.label).foregroundStyle(.secondary) }
                            }
                            ForEach(Array(periods.indices), id: \.self) { i in
                                Text(i < (row.values ?? []).count ? (row.values ?? [])[i].text : "").monospacedDigit()
                            }
                        }
                    }
                }.textSelection(.enabled)
            }
        }
    }
    @ViewBuilder private func list(_ title: String, _ items: [Loose]?) -> some View {
        if let items, !items.isEmpty {
            Text(title).font(UI.section)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text("• " + item.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ChecklistPage: View {
    @ObservedObject var m: Workspace
    var body: some View {
        let list = m.company.checklist
        let items = m.checklistItems
        VStack(spacing: 0) {
            PageHeading(title: "排雷清单", category: CompanyPage.checklist.category, metadata: list?.stamp ?? "",
                        subtitle: "AI 在后台跑完整张清单。你可以按研究结果调整每一项的等级：升级为问题，或降为关注、正常。") {
                Button { m.launchCompany(.checklist) } label: { Label("运行排雷清单", systemImage: "sparkles") }.buttonStyle(ResearchActionStyle())
            }
            Divider()
            PageScroll {
                if let issue = m.company.checklistIssue { Text(issue).font(UI.text).foregroundStyle(.red).textSelection(.enabled) }
                if items.isEmpty && m.company.checklistIssue == nil { Text("尚未运行排雷清单。").font(UI.text).foregroundStyle(.secondary) }
                if !items.isEmpty {
                    HStack(spacing: 14) {
                        ForEach(CheckStatus.allCases, id: \.self) { status in
                            let n = items.filter { m.checkStatus($0) == status }.count
                            if n > 0 { Label(status.label + " " + String(n), systemImage: status.symbol).foregroundStyle(status.color) }
                        }
                    }.font(UI.text)
                    if let modules = list?.modules, !modules.isEmpty {
                        Text("类型模块：" + modules.map(\.text).joined(separator: "、")).font(UI.label).foregroundStyle(.secondary)
                    }
                }
                ForEach(CheckStatus.allCases, id: \.self) { status in
                    let group = items.filter { m.checkStatus($0) == status }
                    if !group.isEmpty {
                        Text(status.label + " · " + String(group.count)).font(UI.section).foregroundStyle(status.color).padding(.top, 6)
                        VStack(spacing: 0) {
                            ForEach(group) { item in
                                CheckRow(m: m, item: item, detailed: status == .flag || status == .watch || status == .unchecked)
                                if item.id != group.last?.id { Divider() }
                            }
                        }
                        .padding(.horizontal, 12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.16)))
                    }
                }
            }
        }
    }
}

private struct CheckRow: View {
    static func comparison(_ item: Checklist.Item, _ decision: ChecklistReview.Decision) -> String {
        let mine = CheckStatus(rawValue: decision.status)?.label ?? decision.status
        let date = decision.date.isEmpty ? "" : "（" + decision.date + "）"
        return "AI 判断：" + item.state.label + "　你的判断：" + mine + date
    }
    @ObservedObject var m: Workspace
    let item: Checklist.Item
    let detailed: Bool
    @State private var expanded = false
    @State private var noting = false

    private var open: Bool { detailed || expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if open { detail }
            questionList
        }
        .padding(.vertical, 9)
        .sheet(isPresented: $noting) { CheckNoteEditor(m: m, item: item) }
    }

    private var header: some View {
        let status = m.checkStatus(item)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: status.symbol).foregroundStyle(status.color).frame(width: 16)
            Button { expanded.toggle() } label: { headerTitle }.buttonStyle(.plain).disabled(detailed)
            CheckLevelMenu(m: m, item: item, note: { noting = true })
        }
    }

    private var headerTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.title.text.isEmpty ? item.id : item.title.text).font(UI.section).foregroundStyle(ink)
            Text(item.group.text).font(UI.label).foregroundStyle(.secondary)
            if !open { Text(item.finding.text).font(UI.text).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 0)
        }.contentShape(Rectangle())
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.finding.text.isEmpty ? "—" : item.finding.text).font(UI.text).foregroundStyle(ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            if let evidence = item.evidence, !evidence.isEmpty { SourceLinks(links: evidence) }
            if let decision = m.checkDecision(item) {
                Text(Self.comparison(item, decision)).font(UI.label).foregroundStyle(.secondary)
                if !decision.note.isEmpty {
                    Text("备注：" + decision.note).font(UI.text).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.padding(.leading, 24)
    }

    @ViewBuilder private var questionList: some View {
        let questions = m.flagQuestions(for: item)
        if !questions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(questions) { question in
                    Button { m.go(.entry(question.id)) } label: { QuestionLink(question: question) }.buttonStyle(.link)
                }
            }.padding(.leading, 24)
        }
    }
}

private struct QuestionLink: View {
    let question: Entry
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(question.title).font(UI.text).lineLimit(1)
            Text(question.answered ? "已回答" : "待回答").font(UI.label).foregroundStyle(.secondary)
        }
    }
}

/// Grading controls for one checklist item.
struct CheckLevelMenu: View {
    @ObservedObject var m: Workspace
    let item: Checklist.Item
    var note: (() -> Void)? = nil
    var body: some View {
        let status = m.checkStatus(item)
        let hasQuestion = !m.flagQuestions(for: item).isEmpty
        Menu {
            Button(hasQuestion ? "升级为异常并打开问题" : "升级为问题") { m.attempt { try m.upgradeCheck(item) } }
            Divider()
            ForEach([CheckStatus.flag, .watch, .ok, .na, .unchecked], id: \.self) { level in
                Button { m.attempt { try m.setCheck(item, to: level) } } label: {
                    if level == status { Label(level.label, systemImage: "checkmark") } else { Text(level.label) }
                }
            }
            if m.checkDecision(item) != nil {
                Divider()
                Button("恢复 AI 的判断（" + item.state.label + "）") { m.attempt { try m.resetCheck(item) } }
            }
            if let note {
                Divider()
                Button("写备注…", action: note)
            }
        } label: {
            Text("调整").font(UI.label)
        }.menuStyle(.borderlessButton).fixedSize().help("调整这一项的等级；降为正常或不适用时，关联的问题标为已回答")
    }
}

private struct CheckNoteEditor: View {
    @ObservedObject var m: Workspace
    let item: Checklist.Item
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title.text).font(.title3.bold())
            Text("说明你为什么这样定级，之后 AI 再跑清单时会读到。").font(UI.label).foregroundStyle(.secondary)
            TextEditor(text: $note).font(UI.text).frame(height: 120).padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.25)))
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { m.attempt { try m.noteCheck(item, note: note) }; dismiss() }.buttonStyle(Primary()).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 460)
        .onAppear { note = m.checkDecision(item)?.note ?? "" }
    }
}

struct ScenarioPage: View {
    @ObservedObject var m: Workspace
    @State private var draft = ScenarioBook()
    @State private var loaded: ScenarioBook?

    private var dirty: Bool { loaded != nil && draft != loaded }

    var body: some View {
        VStack(spacing: 0) {
            PageHeading(title: "情景估值", category: CompanyPage.scenarios.category,
                        metadata: dirty ? "有未保存的修改" : "每个情景对应一组关键问题的答案") {
                PageActions {
                    Button("添加情景") {
                        let names = ["乐观", "基准", "悲观"], n = draft.scenarios.count
                        draft.scenarios.append(Scenario(name: n < names.count ? names[n] : "情景 " + String(n + 1)))
                    }
                    Button("还原") { draft = m.company.scenarios }.disabled(!dirty)
                    Button("保存") { m.attempt { try m.saveScenarios(draft); loaded = draft } }.buttonStyle(Primary()).disabled(!dirty)
                        .keyboardShortcut("s")
                }
            }
            Divider()
            PageScroll {
                if let issue = m.company.scenariosIssue { Text(issue).foregroundStyle(.red) }
                baseFields
                Divider()
                ForEach($draft.scenarios) { $scenario in
                    ScenarioCard(m: m, book: draft, scenario: $scenario) { draft.scenarios.removeAll { $0.id == scenario.id } }
                }
                if draft.scenarios.isEmpty { Text("尚未建立情景。通常写乐观、基准、悲观三个，每个对应关键问题的一组答案。").foregroundStyle(.secondary) }
                summary
            }
        }
        .onAppear { draft = m.company.scenarios; loaded = draft }
        .onChange(of: m.company.scenarios) { _, latest in
            if !dirty { draft = latest }
            loaded = latest
        }
    }

    private func field(_ title: String, _ value: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(UI.label).foregroundStyle(.secondary)
            TextField(prompt, text: value).textFieldStyle(.roundedBorder).frame(minWidth: 110)
        }
    }

    private var baseFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("共同参数").font(UI.section)
            Text("收入、净现金按同一单位填写，股本按对应单位换算成每股价值，例如收入以亿元计、股本以亿股计。").font(UI.label).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10, alignment: .top)], alignment: .leading, spacing: 8) {
                field("现价", $draft.price)
                field("价格日期", $draft.priceDate, prompt: "YYYY-MM-DD")
                field("单位说明", $draft.unit, prompt: "如 元/股，收入为亿元")
                field("股本", $draft.shares)
                field("净现金", $draft.netCash, prompt: "净负债填负数")
                field("估值年份", $draft.year, prompt: "如 FY2028")
                field("折现率 %", $draft.discountRate, prompt: "选填")
                field("折现年数", $draft.years, prompt: "选填")
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            if let w = draft.weighted {
                Text("概率加权价值 " + numberText(w.target) + (draft.unit.isEmpty ? "" : " " + draft.unit) + "，相对现价 " + percentText(w.upside)).font(.title3.weight(.semibold))
                if abs(w.probability - 100) > 0.5 { Text("概率合计 " + numberText(w.probability) + "%，加权时按合计归一。").font(UI.label).foregroundStyle(.orange) }
            } else if !draft.scenarios.isEmpty {
                Text("填写概率和估值参数后显示加权价值。").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ScenarioCard: View {
    @ObservedObject var m: Workspace
    let book: ScenarioBook
    @Binding var scenario: Scenario
    let remove: () -> Void

    private func field(_ title: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(UI.label).foregroundStyle(.secondary)
            TextField("", text: value).textFieldStyle(.roundedBorder).frame(minWidth: 90)
        }
    }

    var body: some View {
        let method = ValuationMethod(rawValue: scenario.method) ?? .pe
        let value = book.value(scenario)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("情景名称", text: $scenario.name).font(UI.section).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Spacer()
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }.buttonStyle(.borderless).help("删除情景")
            }
            if !m.cruxes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("关键问题的答案").font(UI.label).foregroundStyle(.secondary)
                    ForEach(m.cruxes) { crux in
                        Picker(crux.title, selection: Binding(get: { scenario.answers[crux.id] ?? "" },
                                                              set: { scenario.answers[crux.id] = $0.isEmpty ? nil : $0 })) {
                            Text("未定").tag("")
                            ForEach(CruxAnswer.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                        }.pickerStyle(.menu)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10, alignment: .top)], alignment: .leading, spacing: 8) {
                field("概率 %", $scenario.probability)
                VStack(alignment: .leading, spacing: 2) {
                    Text("估值方法").font(UI.label).foregroundStyle(.secondary)
                    Picker("", selection: $scenario.method) {
                        ForEach(ValuationMethod.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                    }.labelsHidden()
                }
                field((book.year.isEmpty ? "" : book.year + " ") + "收入", $scenario.revenue)
                if method != .evSales { field(method.marginLabel, $scenario.margin) }
                field(method.label + " 倍数", $scenario.multiple)
            }
            TextField("关键假设与依据", text: $scenario.note, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
            HStack(spacing: 14) {
                Text(method.formula).font(UI.label).foregroundStyle(.secondary)
                Spacer()
                if value.missing.isEmpty {
                    Text("每股价值 " + numberText(value.perShare)).monospacedDigit()
                    if value.present != value.perShare { Text("折现后 " + numberText(value.present)).monospacedDigit() }
                    Text("相对现价 " + percentText(value.upside)).monospacedDigit().fontWeight(.semibold)
                } else {
                    Text("缺少：" + value.missing.joined(separator: "、")).font(UI.label).foregroundStyle(.orange)
                }
            }
        }
        .padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.18)))
    }
}

struct TimelinePage: View {
    @ObservedObject var m: Workspace
    var body: some View {
        let events = m.timeline
        VStack(spacing: 0) {
            PageHeading(title: "时间线", category: CompanyPage.timeline.category, metadata: "季报与公告标明影响了哪个关键问题、往哪个方向") {
                PageActions {
                    Button("记录事件") { m.newEvent() }
                    Button { m.launchCompany(.timeline) } label: { Label("更新时间线", systemImage: "sparkles") }.buttonStyle(ResearchActionStyle())
                }
            }
            Divider()
            PageScroll {
                if events.isEmpty { Text("尚无事件。").foregroundStyle(.secondary) }
                ForEach(events) { event in EventRow(m: m, event: event) }
            }
        }
    }
}

private struct EventRow: View {
    @ObservedObject var m: Workspace
    let event: Entry
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(event.date.isEmpty ? "日期未填" : event.date).font(UI.text.monospacedDigit()).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Button { m.go(.entry(event.id)) } label: { Text(event.title).fontWeight(.semibold).foregroundStyle(ink).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                ImpactChips(m: m, impacts: event.impacts)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 6).contextMenu { EntryActions(m: m, entry: event) }
        Divider()
    }
}

private struct ImpactChips: View {
    @ObservedObject var m: Workspace
    let impacts: [EventImpact]
    var body: some View {
        if !impacts.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(impacts, id: \.self) { impact in
                    let direction = ImpactDirection(rawValue: impact.direction) ?? .neutral
                    let title = m.snapshot.resolve(impact.question)?.title ?? "问题已删除"
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Tag(text: direction.label, color: direction.color)
                        Button(title) { if let q = m.snapshot.resolve(impact.question) { m.go(.entry(q.id)) } }.buttonStyle(.link).lineLimit(1)
                        if !impact.note.isEmpty { Text(impact.note).font(UI.label).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            }
        }
    }
}

struct ReportsPage: View {
    @ObservedObject var m: Workspace
    let company: ProjectAt
    var body: some View {
        VStack(spacing: 0) {
            PageHeading(title: "研究底稿", category: CompanyPage.reports.category, metadata: m.snapshot.completed ? "开题已完成" : "尚未开题",
                        subtitle: "开题时生成的长篇材料。在正文划选文字可以建立问题或事件。") {
                if !m.snapshot.completed {
                    Button { m.launchCompany(.setup) } label: { Label("开题研究", systemImage: "sparkles") }.buttonStyle(ResearchActionStyle())
                }
            }
            Divider()
            PageScroll {
                if m.snapshot.reports.isEmpty { Text("尚无研究底稿。").foregroundStyle(.secondary) }
                ForEach(m.snapshot.reports.reversed(), id: \.self) { path in
                    Button { m.go(.doc(path)) } label: {
                        HStack { Label(documentLabel(path), systemImage: "doc.text").foregroundStyle(ink); Spacer(); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                    }.buttonStyle(SidebarLinkStyle(color: PageCategory.report.color, verticalInset: 7))
                }
            }
        }
    }
}

// MARK: - Entry panels

/// The right-hand pane of a company question: its judgment fields, or the usual relation graph.
struct CompanyQuestionPane: View {
    @ObservedObject var m: Workspace
    let entry: Entry
    let graphWidth: CGFloat
    @AppStorage("companyQuestionPane") private var tab = "judgment"
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("判断").tag("judgment")
                Text("关系图").tag("graph")
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 240)
                .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            ScrollView {
                if tab == "graph" { EntryRelations(model: m, entry: entry, graphWidth: graphWidth).padding(16) }
                else {
                    CruxInspector(m: m, question: entry).id(entry.id)
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Shown above the body when the right pane is hidden, so the question still shows its state.
struct CruxSummaryBar: View {
    @ObservedObject var m: Workspace
    let question: Entry
    var body: some View {
        HStack(spacing: 10) {
            RoleTag(entry: question)
            if question.candidate {
                Button("采纳") { m.confirmCrux(question.id) }.buttonStyle(Primary())
                Button("删除") { m.dismissCrux(question.id) }
            }
            if question.role != "flag" {
                Text("我的判断：" + (question.myView.clean.isEmpty ? "未填写" : question.myView.clean))
                    .font(UI.text).foregroundStyle(question.myView.clean.isEmpty ? Color.secondary : ink).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("显示判断栏") { m.showEntryRelations = true }.controlSize(.small)
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
    }
}

struct CruxInspector: View {
    @ObservedObject var m: Workspace
    let question: Entry
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RoleTag(entry: question)
                Spacer()
                if question.role != "flag" {
                    Button("编辑…") { editing = true }.controlSize(.small).help("填写我的判断、证伪条件，或修改市场假设与跟踪指标")
                }
            }.padding(.bottom, 12)
            if question.candidate {
                HStack(spacing: 8) {
                    Text("AI 起草的候选问题").font(UI.text).foregroundStyle(.secondary)
                    Spacer()
                    Button("采纳") { m.confirmCrux(question.id) }.buttonStyle(Primary())
                    Button("删除") { m.dismissCrux(question.id) }
                }.padding(.bottom, 12)
            }
            if question.role == "sub", let parent = m.snapshot.resolve(question.parent) {
                Button("所属关键问题：" + parent.title) { m.go(.entry(parent.id)) }.buttonStyle(.link).font(UI.text)
                    .multilineTextAlignment(.leading).padding(.bottom, 12)
            }
            if question.role == "flag" {
                InspectorSection(title: "排雷清单") { FlagItemBar(m: m, question: question) }
            } else {
                InspectorSection(title: "我的观点") {
                    InspectorField(label: "我的判断", value: question.myView, edit: { editing = true })
                    InspectorField(label: "证伪条件", value: question.kill, edit: { editing = true })
                }
                InspectorSection(title: "市场") {
                    InspectorField(label: "市场隐含", value: question.marketView, edit: { editing = true })
                    InspectorField(label: "判断不同时的影响", value: question.impact, edit: { editing = true })
                }
                InspectorSection(title: "跟踪") {
                    InspectorField(label: "跟踪指标", value: question.tracking, edit: { editing = true })
                    evidence
                }
            }
            dependencies
            events
            if question.role == "crux" { subQuestions }
        }
        .sheet(isPresented: $editing) { CruxEditor(m: m, question: question) }
    }

    private var evidence: some View {
        HStack {
            Text("证据强度").font(UI.label).foregroundStyle(.secondary)
            Spacer()
            Menu(EvidenceStrength(rawValue: question.evidence)?.label ?? "未评估") {
                ForEach(EvidenceStrength.allCases, id: \.self) { strength in
                    Button(strength.label) { m.attempt { try m.updateEntry(question.id) { $0.evidence = strength.rawValue } } }
                }
                Divider()
                Button("未评估") { m.attempt { try m.updateEntry(question.id) { $0.evidence = "" } } }
            }.menuStyle(.borderlessButton).fixedSize().font(UI.text)
        }
    }

    private var dependencies: some View {
        let states = m.company.dependencies[question.id] ?? []
        return InspectorSection(title: "行业依据", count: states.count) {
            Button("关联行业依据…") { m.dialog = .dependency(question) }
            Button("新建行业问题…") { m.dialog = .submit(question) }
        } content: {
            if states.isEmpty { InspectorEmpty(text: "尚未引用专题条目") }
            ForEach(states) { state in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    switch state.status {
                    case .current: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    case .changed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    case .missing: Image(systemName: "xmark.circle").foregroundStyle(.red)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Button { m.openDependency(state) } label: { LeadingTitle(text: state.title) }.buttonStyle(.link)
                            .disabled(state.status == .missing)
                        Text(state.topic + (state.status == .changed ? " · 已更新" : "")).font(UI.label)
                            .foregroundStyle(state.status == .changed ? Color.orange : Color.secondary)
                        if state.status == .changed {
                            Button("已核对") { m.attempt { try m.acknowledge(state, for: question.id) } }.controlSize(.small)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { m.attempt { try m.removeDependency(state.dependency, from: question.id) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("移除这条依据")
                }.font(UI.text)
            }
        }
    }

    private var events: some View {
        let related = m.events(affecting: question)
        return InspectorSection(title: "时间线", count: related.count) {
            Button("记录事件…") { m.newEvent(affecting: question) }
        } content: {
            if related.isEmpty { InspectorEmpty(text: "尚无相关事件") }
            ForEach(Array(related.prefix(8).enumerated()), id: \.offset) { _, pair in
                let (event, impact) = pair
                let direction = ImpactDirection(rawValue: impact.direction) ?? .neutral
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(event.date).font(UI.label.monospacedDigit()).foregroundStyle(.secondary)
                        Tag(text: direction.label, color: direction.color)
                    }
                    Button { m.go(.entry(event.id)) } label: { LeadingTitle(text: event.title) }.buttonStyle(.link).font(UI.text)
                }
            }
            if related.count > 8 { Button("全部 " + String(related.count) + " 个事件") { m.go(.company(.timeline)) }.buttonStyle(.link).font(UI.label) }
        }
    }

    private var subQuestions: some View {
        let subs = m.subQuestions(of: question)
        return InspectorSection(title: "子问题", count: subs.count) {
            Button("添加…") { m.newSubQuestion(of: question) }
        } content: {
            if subs.isEmpty { InspectorEmpty(text: "尚无子问题") }
            ForEach(subs) { sub in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: sub.answered ? "checkmark.circle" : "circle").foregroundStyle(.secondary).font(UI.label)
                    Button { m.go(.entry(sub.id)) } label: { LeadingTitle(text: sub.title) }.buttonStyle(.link)
                }.font(UI.text)
            }
        }
    }
}

/// A section of the judgment pane: a hairline, a title with its actions, then the content. No boxes.
private struct InspectorSection<Actions: View, Content: View>: View {
    let title: String
    var count = 0
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 6) {
                Text(title).font(UI.section).foregroundStyle(ink)
                if count > 0 { Text(String(count)).font(UI.label).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                HStack(spacing: 10) { actions() }.buttonStyle(.borderless).font(UI.label).foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 12) { content() }
        }.padding(.bottom, 16)
    }
}

extension InspectorSection where Actions == EmptyView {
    init(title: String, count: Int = 0, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, count: count, actions: { EmptyView() }, content: content)
    }
}

/// One field: a small label, then the text; long text folds after five lines.
private struct InspectorField: View {
    let label: String
    let value: String
    var edit: (() -> Void)? = nil
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label).font(UI.label).foregroundStyle(.secondary)
                Spacer()
                if let edit, !value.clean.isEmpty {
                    Button(action: edit) { Image(systemName: "pencil") }.buttonStyle(.borderless)
                        .font(.system(size: 10)).foregroundStyle(.tint).help("编辑" + label)
                }
            }
            if value.clean.isEmpty {
                if let edit { Button("点击填写", action: edit).buttonStyle(.link).font(UI.text) }
                else { Text("—").font(UI.text).foregroundStyle(.secondary) }
            } else {
                Text(value.clean).font(UI.text).foregroundStyle(ink).lineSpacing(2)
                    .lineLimit(expanded ? nil : 5).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if value.clean.count > 110 {
                    Button(expanded ? "收起" : "展开全文") { expanded.toggle() }.buttonStyle(.link).font(UI.label)
                }
            }
        }
    }
}

/// A link title that wraps onto a second line flush left, not centred.
private struct LeadingTitle: View {
    let text: String
    var body: some View {
        Text(text).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorEmpty: View {
    let text: String
    var body: some View { Text(text).font(UI.text).foregroundStyle(.secondary) }
}

/// On a red-flag question: the checklist item it came from, with the user's grading controls.
private struct FlagItemBar: View {
    @ObservedObject var m: Workspace
    let question: Entry
    var body: some View {
        if let item = m.checklistItems.first(where: { $0.id == question.check }) {
            let status = m.checkStatus(item)
            HStack(spacing: 8) {
                Image(systemName: status.symbol).foregroundStyle(status.color)
                Button(item.title.text) { m.go(.company(.checklist)) }.buttonStyle(.link).lineLimit(2)
                Tag(text: status.label, color: status.color)
                Spacer()
                CheckLevelMenu(m: m, item: item)
            }.font(UI.text)
            if !item.finding.text.isEmpty { InspectorField(label: "AI 的发现", value: item.finding.text) }
            if let note = m.checkDecision(item)?.note, !note.isEmpty { InspectorField(label: "我的备注", value: note) }
        } else if !question.check.isEmpty {
            Text("排雷清单项 " + question.check + " 已不在清单中").font(UI.text).foregroundStyle(.secondary)
        }
    }
}

struct CruxEditor: View {
    @ObservedObject var m: Workspace
    let question: Entry
    @Environment(\.dismiss) private var dismiss
    @State private var marketView = ""
    @State private var myView = ""
    @State private var impact = ""
    @State private var kill = ""
    @State private var tracking = ""
    @State private var evidence = ""
    @State private var message = ""

    private func area(_ title: String, _ text: Binding<String>, _ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(UI.label).foregroundStyle(.secondary)
            TextField(prompt, text: text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...6)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.title).font(.title3.bold()).lineLimit(3)
            area("我的判断", $myView, "你和市场哪里不同，依据是什么")
            area("证伪条件", $kill, "出现什么数据就认错")
            area("市场隐含", $marketView, "当前股价隐含的假设，写成可检验的陈述")
            area("判断不同时的影响", $impact, "方向、幅度及推算方式")
            area("跟踪指标", $tracking, "指标、来源和检查频率")
            Picker("证据强度", selection: $evidence) {
                Text("未评估").tag("")
                ForEach(EvidenceStrength.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
            }.pickerStyle(.segmented)
            if !message.isEmpty { Text(message).foregroundStyle(.red).font(UI.label) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        try m.updateEntry(question.id) { e in
                            e.myView = myView.clean; e.kill = kill.clean; e.marketView = marketView.clean
                            e.impact = impact.clean; e.tracking = tracking.clean; e.evidence = evidence
                        }
                        dismiss()
                    } catch { message = error.localizedDescription }
                }.buttonStyle(Primary()).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 560)
        .onAppear {
            marketView = question.marketView; myView = question.myView; impact = question.impact
            kill = question.kill; tracking = question.tracking; evidence = question.evidence
        }
    }
}

struct EventPanel: View {
    @ObservedObject var m: Workspace
    let event: Entry
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(event.date.isEmpty ? "日期未填" : event.date).font(UI.text.monospacedDigit())
                if let url = URL(string: event.source), MaterialLinks.isWeb(event.source) {
                    Button("原始出处") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                }
                Spacer()
                Button("编辑日期与影响…") { editing = true }
            }
            if event.impacts.isEmpty { Text("尚未标明影响的关键问题").font(UI.text).foregroundStyle(.secondary) }
            ImpactChips(m: m, impacts: event.impacts)
        }
        .padding(.horizontal, 24).padding(.vertical, 10).background(rail.opacity(0.55))
        .sheet(isPresented: $editing) { ImpactEditor(m: m, event: event) }
    }
}

struct ImpactEditor: View {
    @ObservedObject var m: Workspace
    let event: Entry
    @Environment(\.dismiss) private var dismiss
    @State private var date = ""
    @State private var source = ""
    @State private var directions: [String: String] = [:]
    @State private var notes: [String: String] = [:]
    @State private var message = ""

    private var questions: [Entry] { m.cruxes + m.flagQuestions + m.snapshot.entries.filter { $0.kind == .questions && $0.role == "sub" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(event.title).font(.title3.bold()).lineLimit(2)
            HStack {
                TextField("日期 YYYY-MM-DD", text: $date).textFieldStyle(.roundedBorder).frame(width: 160)
                TextField("原始出处链接", text: $source).textFieldStyle(.roundedBorder)
            }
            Text("影响的问题（方向相对于你的判断；尚未填写判断时相对于市场隐含假设）").font(UI.label).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(questions) { q in
                        VStack(alignment: .leading, spacing: 3) {
                            Picker(q.title, selection: Binding(get: { directions[q.id] ?? "" }, set: { directions[q.id] = $0 })) {
                                Text("无关").tag("")
                                ForEach(ImpactDirection.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                            }.pickerStyle(.menu)
                            if !(directions[q.id] ?? "").isEmpty {
                                TextField("一句话说明", text: Binding(get: { notes[q.id] ?? "" }, set: { notes[q.id] = $0 })).textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    if questions.isEmpty { Text("尚无关键问题。").foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 300)
            if !message.isEmpty { Text(message).foregroundStyle(.red).font(UI.label) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        let known = Set(questions.map(\.id))
                        try m.updateEntry(event.id) { e in
                            e.date = date.clean; e.source = source.clean
                            let kept = e.impacts.filter { !known.contains($0.question) }
                            e.impacts = kept + questions.compactMap { q in
                                guard let d = directions[q.id], !d.isEmpty else { return nil }
                                return EventImpact(question: q.id, direction: d, note: (notes[q.id] ?? "").clean)
                            }
                        }
                        dismiss()
                    } catch { message = error.localizedDescription }
                }.buttonStyle(Primary()).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 560)
        .onAppear {
            date = event.date; source = event.source
            for impact in event.impacts { directions[impact.question] = impact.direction; notes[impact.question] = impact.note }
        }
    }
}

// MARK: - Dialogs

@MainActor private func topicChoices(_ m: Workspace) -> [ProjectAt] {
    let linked = Set((m.project?.info.stock?.links ?? []).map(\.projectID))
    return m.projects.filter { linked.contains($0.id) } + m.projects.filter { !linked.contains($0.id) }
}

struct DependencyPanel: View {
    @ObservedObject var m: Workspace
    let question: Entry
    @State private var topicID = ""
    @State private var entries: [Entry] = []
    @State private var query = ""
    @State private var message = ""

    var body: some View {
        let existing = Set((m.snapshot.resolve(question.id)?.depends ?? []).map { $0.project + "/" + $0.entry })
        VStack(alignment: .leading, spacing: 12) {
            Text("关联行业依据").font(.title2.bold())
            Text("「" + question.title + "」依赖专题中的哪些判断？专题条目更新后，看板会提示你复核。").foregroundStyle(.secondary)
            Picker("专题", selection: $topicID) {
                Text("选择专题").tag("")
                ForEach(topicChoices(m)) { Text($0.info.title).tag($0.id) }
            }
            TextField("查找问题、概念、实体或事件", text: $query).textFieldStyle(.roundedBorder)
            List(entries.filter { $0.kind != .references && (query.clean.isEmpty || $0.title.localizedCaseInsensitiveContains(query.clean)) }) { entry in
                HStack {
                    Tag(text: entry.kind.label, color: entry.kind.tint)
                    Text(entry.title).lineLimit(2)
                    Spacer()
                    if existing.contains(topicID + "/" + entry.id) { Text("已引用").font(UI.label).foregroundStyle(.secondary) }
                    else {
                        Button("引用") {
                            guard let topic = m.projects.first(where: { $0.id == topicID }) else { return }
                            do { try m.addDependency(to: question.id, topic: topic, entry: entry); message = "" }
                            catch { message = error.localizedDescription }
                        }
                    }
                }
            }.frame(height: 230)
            if !message.isEmpty { Text(message).foregroundStyle(.red) }
            HStack { Spacer(); Button("完成") { m.dialog = nil }.keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 520)
        .onAppear { if topicID.isEmpty, let first = topicChoices(m).first { topicID = first.id } }
        .onChange(of: topicID, initial: true) { _, id in
            entries = []
            guard let topic = m.projects.first(where: { $0.id == id }) else { return }
            do { entries = try Files.scan(topic.url, indexSources: false).entries; message = "" }
            catch { message = error.localizedDescription }
        }
    }
}

struct SubmitToTopicPanel: View {
    @ObservedObject var m: Workspace
    let entry: Entry
    @State private var topicID = ""
    @State private var title = ""
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提交到专题").font(.title2.bold())
            Text("把行业层面的发现写成专题中的" + entry.kind.label + "，正文附回到本公司的链接。" + (entry.kind == .questions ? "本问题会自动引用这条专题条目，专题中的回答更新后，看板会提示复核。" : ""))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("专题", selection: $topicID) {
                Text("选择专题").tag("")
                ForEach(topicChoices(m)) { Text($0.info.title).tag($0.id) }
            }
            TextField("在专题中的标题", text: $title).textFieldStyle(.roundedBorder)
            if !message.isEmpty { Text(message).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { m.dialog = nil }.keyboardShortcut(.cancelAction)
                Button("提交") {
                    guard let topic = m.projects.first(where: { $0.id == topicID }) else { return }
                    do {
                        try m.submitToTopic(entry, topic: topic, title: title)
                        m.dialog = nil
                        m.notice = "已写入专题「" + topic.info.title + "」"
                    } catch { message = error.localizedDescription }
                }.buttonStyle(Primary()).keyboardShortcut(.defaultAction).disabled(topicID.isEmpty)
            }
        }.padding(22).frame(width: 480)
        .onAppear {
            title = entry.title
            if topicID.isEmpty, let first = topicChoices(m).first { topicID = first.id }
        }
    }
}

/// From a company question: an empty question in one of the company's topics, related to the company there.
struct NewTopicQuestionPanel: View {
    @ObservedObject var m: Workspace
    let question: Entry
    @State private var topicID = ""
    @State private var title = ""
    @State private var message = ""
    var body: some View {
        let topics = m.linkedTopics()
        VStack(alignment: .leading, spacing: 12) {
            Text("新建行业问题").font(.title2.bold())
            Text("在本公司所属的行业专题中新建一个问题，自动关联专题里的本公司实体；本问题会把它作为行业依据，专题中的回答更新后提示你复核。正文留空，需要沿用的内容请自行粘贴。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if topics.isEmpty {
                Text("本公司尚未关联行业专题。请先在专题的公司实体页用「个股深研…」关联本公司。").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("专题", selection: $topicID) {
                    ForEach(topics, id: \.topic.id) { Text($0.topic.info.title).tag($0.topic.id) }
                }
                TextField("行业问题的标题", text: $title).textFieldStyle(.roundedBorder)
            }
            if !message.isEmpty { Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消") { m.dialog = nil }.keyboardShortcut(.cancelAction)
                Button("新建并打开") {
                    guard let topic = topics.first(where: { $0.topic.id == topicID })?.topic else { return }
                    do {
                        let created = try m.newTopicQuestion(for: question, topic: topic, title: title)
                        m.dialog = nil
                        m.open(topic, at: .entry(created.id))
                    } catch { message = error.localizedDescription }
                }.buttonStyle(Primary()).keyboardShortcut(.defaultAction).disabled(topicID.isEmpty || title.clean.isEmpty)
            }
        }.padding(22).frame(width: 480)
        .onAppear {
            if title.isEmpty { title = question.title }
            if topicID.isEmpty, let first = topics.first { topicID = first.topic.id }
        }
    }
}

// MARK: - Topic side

struct CompanySummary {
    var latest: Judgment?
    var cruxes: [Entry]
    static func load(_ stock: ProjectAt) -> CompanySummary {
        let book = (try? StockFiles.load(stock))?.0
        let entries = (try? Files.scan(stock.url, indexSources: false))?.entries ?? []
        let cruxes = entries.filter { $0.kind == .questions && $0.role == "crux" && !$0.candidate }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return CompanySummary(latest: book?.history.first, cruxes: cruxes)
    }
}

/// Shown on a topic's company entity: the stock project's current judgment and question status, without its content.
struct LinkedStockCard: View {
    @ObservedObject var m: Workspace
    let stock: ProjectAt
    @State private var summary: CompanySummary?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "circle.fill").foregroundStyle(PageCategory.stock.color).font(UI.label)
                Text("个股研究 · " + stock.stockLabel).font(UI.section)
                Spacer()
                Button("打开个股") { m.open(stock, at: .overview) }
            }
            if let latest = summary?.latest {
                HStack(spacing: 6) {
                    Text(latest.date.formatted(date: .abbreviated, time: .omitted)).font(UI.label).foregroundStyle(.secondary)
                    if let d = latest.direction.flatMap(JudgmentDirection.init(rawValue:)), d != .none { Tag(text: d.label, color: PageCategory.judgment.color) }
                    Text(latest.conclusion).font(UI.section).lineLimit(2)
                }
            } else if summary != nil {
                Text("尚未发布投资判断").font(UI.text).foregroundStyle(.secondary)
            }
            ForEach((summary?.cruxes ?? []).prefix(6)) { crux in
                HStack(spacing: 6) {
                    Text(crux.title).font(UI.text).lineLimit(1)
                    Spacer(minLength: 4)
                    if let strength = EvidenceStrength(rawValue: crux.evidence) { Text(strength.label).font(UI.label).foregroundStyle(.secondary) }
                    Text(crux.answered ? "已回答" : "待回答").font(UI.label).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(PageCategory.stock.color.opacity(0.06))
        .task(id: stock.id + ":" + String(m.revision)) { summary = CompanySummary.load(stock) }
    }
}
