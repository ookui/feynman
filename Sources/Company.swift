import SwiftUI
import CryptoKit

// MARK: - Entry metadata shared with the sling-company-study skill

/// A company question that relies on a topic item. `seen` is the topic item's fingerprint when last reviewed.
struct TopicDependency: Codable, Hashable {
    var project: String
    var entry: String
    var title = ""
    var seen = ""
}

/// How one event bears on one question, relative to the user's view (or the market view before the user writes one).
struct EventImpact: Codable, Hashable {
    var question: String
    var direction = ""
    var note = ""

    init(question: String, direction: String = "", note: String = "") {
        self.question = question; self.direction = direction; self.note = note
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try c.decode(String.self, forKey: .question)
        direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

enum ImpactDirection: String, CaseIterable {
    case support, weaken, neutral
    var label: String {
        switch self { case .support: return "支持"; case .weaken: return "削弱"; case .neutral: return "中性" }
    }
    var color: Color {
        switch self {
        case .support: return Color(red: 0.12, green: 0.52, blue: 0.33)
        case .weaken: return Color(red: 0.78, green: 0.25, blue: 0.18)
        case .neutral: return .secondary
        }
    }
}

enum EvidenceStrength: String, CaseIterable {
    case strong, medium, weak
    var label: String {
        switch self { case .strong: return "证据强"; case .medium: return "证据中等"; case .weak: return "证据弱" }
    }
}

enum CruxAnswer: String, CaseIterable {
    case yes, partial, no
    var label: String {
        switch self { case .yes: return "成立"; case .partial: return "部分成立"; case .no: return "不成立" }
    }
}

// MARK: - Files written by the skill

/// Accepts strings, numbers or booleans, so hand-edited or AI-written JSON stays readable.
struct Loose: Codable, Hashable {
    var text: String
    init(_ text: String) { self.text = text }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(String.self) { text = value }
        else if let value = try? c.decode(Double.self) {
            text = value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        } else if let value = try? c.decode(Bool.self) { text = value ? "true" : "false" }
        else { text = "" }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}
extension Optional where Wrapped == Loose {
    var text: String { self?.text ?? "" }
}

struct SourceLink: Codable, Hashable {
    var title: Loose?
    var url: Loose?
    var date: Loose?
}

struct CompanySnapshot: Codable, Equatable {
    struct Price: Codable, Equatable { var value: Loose?; var date: Loose?; var marketCap: Loose?; var currency: Loose? }
    struct Segment: Codable, Equatable { var name: Loose?; var period: Loose?; var revenue: Loose?; var share: Loose?; var growth: Loose?; var margin: Loose?; var note: Loose? }
    struct Row: Codable, Equatable { var name: Loose?; var unit: Loose?; var values: [Loose]?; var note: Loose? }
    struct Series: Codable, Equatable { var periods: [Loose]?; var rows: [Row]? }
    struct Metric: Codable, Equatable { var name: Loose?; var value: Loose?; var percentile: Loose?; var method: Loose?; var source: Loose?; var note: Loose? }
    var asOf: Loose?
    var source: Loose?
    var currency: Loose?
    var unit: Loose?
    var positioning: Loose?
    var price: Price?
    var segments: [Segment]?
    var quarterly: Series?
    var valuation: [Metric]?
    var implied: [Metric]?
    var consensus: [Metric]?
    var narrative: [Loose]?
    var gaps: [Loose]?
    var sources: [SourceLink]?
}

extension CompanySnapshot {
    var stamp: String {
        var parts: [String] = []
        if !asOf.text.isEmpty { parts.append("截至 " + asOf.text) }
        if !source.text.isEmpty { parts.append(source.text) }
        return parts.joined(separator: " · ")
    }
    var pageStamp: String {
        var parts = stamp.isEmpty ? [] : [stamp]
        if !unit.text.isEmpty { parts.append(unit.text) }
        return parts.joined(separator: " · ")
    }
    var priceLine: String? {
        guard let price, !price.value.text.isEmpty else { return nil }
        var text = "股价 " + price.value.text
        if !price.currency.text.isEmpty { text += " " + price.currency.text }
        if !price.date.text.isEmpty { text += "（" + price.date.text + "）" }
        return text
    }
    var marketCapLine: String? {
        guard let cap = price?.marketCap.text, !cap.isEmpty else { return nil }
        return "市值 " + cap
    }
}

extension CompanySnapshot.Metric {
    var line: String {
        var text = name.text + "　" + value.text
        if !percentile.text.isEmpty { text += "（" + percentile.text + "）" }
        return text
    }
    var detail: String {
        [percentile.text, method.text, source.text, note.text].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

extension Checklist {
    var stamp: String {
        var parts: [String] = []
        if !profile.text.isEmpty { parts.append(profile.text) }
        if !updated.text.isEmpty { parts.append("更新于 " + updated.text) }
        return parts.joined(separator: " · ")
    }
}

enum CheckStatus: String, CaseIterable {
    case flag, unchecked, ok, na
    var label: String {
        switch self { case .flag: return "异常"; case .unchecked: return "未核查"; case .ok: return "正常"; case .na: return "不适用" }
    }
    var symbol: String {
        switch self { case .flag: return "exclamationmark.triangle.fill"; case .unchecked: return "questionmark.circle"; case .ok: return "checkmark.circle"; case .na: return "minus.circle" }
    }
    var color: Color {
        switch self {
        case .flag: return Color(red: 0.80, green: 0.35, blue: 0.05)
        case .unchecked: return Color(red: 0.55, green: 0.45, blue: 0.10)
        case .ok: return Color(red: 0.12, green: 0.52, blue: 0.33)
        case .na: return .secondary
        }
    }
}

struct Checklist: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id: String
        var group: Loose?
        var title: Loose?
        var status: Loose?
        var finding: Loose?
        var evidence: [SourceLink]?
        var question: Loose?
        var state: CheckStatus { CheckStatus(rawValue: status.text.lowercased()) ?? .unchecked }
    }
    var updated: Loose?
    var profile: Loose?
    var modules: [Loose]?
    var items: [Item]?
}

struct LakehouseLink: Codable, Equatable {
    var thesis: String?
    var synced: String?
    var judgment: String?
}

// MARK: - Scenario valuation, kept by the user in the app

enum ValuationMethod: String, CaseIterable {
    case pe, evEbit, evSales
    var label: String {
        switch self { case .pe: return "PE"; case .evEbit: return "EV/EBIT"; case .evSales: return "EV/Sales" }
    }
    var marginLabel: String { self == .pe ? "净利率 %" : self == .evEbit ? "经营利润率 %" : "利润率（不参与计算）" }
    var formula: String {
        switch self {
        case .pe: return "收入 × 净利率 × PE ÷ 股本"
        case .evEbit: return "（收入 × 经营利润率 × 倍数 ＋ 净现金）÷ 股本"
        case .evSales: return "（收入 × 倍数 ＋ 净现金）÷ 股本"
        }
    }
}

struct Scenario: Codable, Equatable, Identifiable {
    var id = UUID().uuidString.lowercased()
    var name = ""
    var probability = ""
    var answers: [String: String] = [:]
    var revenue = ""
    var margin = ""
    var method = ValuationMethod.pe.rawValue
    var multiple = ""
    var note = ""

    init(name: String = "") { self.name = name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { (try? c.decodeIfPresent(Loose.self, forKey: key)).text }
        id = text(.id).isEmpty ? UUID().uuidString.lowercased() : text(.id)
        name = text(.name); probability = text(.probability); revenue = text(.revenue); margin = text(.margin)
        multiple = text(.multiple); note = text(.note)
        method = ValuationMethod(rawValue: text(.method)) == nil ? ValuationMethod.pe.rawValue : text(.method)
        answers = (try? c.decodeIfPresent([String: String].self, forKey: .answers)) ?? [:]
    }
}

struct ScenarioValue: Equatable {
    var perShare: Double?
    var present: Double?
    var upside: Double?
    var missing: [String] = []
}

struct ScenarioBook: Codable, Equatable {
    var price = ""
    var priceDate = ""
    var unit = ""
    var shares = ""
    var netCash = ""
    var year = ""
    var discountRate = ""
    var years = ""
    var scenarios: [Scenario] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { (try? c.decodeIfPresent(Loose.self, forKey: key)).text }
        price = text(.price); priceDate = text(.priceDate); unit = text(.unit); shares = text(.shares)
        netCash = text(.netCash); year = text(.year); discountRate = text(.discountRate); years = text(.years)
        scenarios = try c.decodeIfPresent([Scenario].self, forKey: .scenarios) ?? []
    }

    static func number(_ text: String) -> Double? {
        var value = text.clean
        for token in [",", "，", " ", "%", "％", "x", "X", "倍"] { value = value.replacingOccurrences(of: token, with: "") }
        guard !value.isEmpty, let number = Double(value), number.isFinite else { return nil }
        return number
    }

    func value(_ s: Scenario) -> ScenarioValue {
        let method = ValuationMethod(rawValue: s.method) ?? .pe
        let revenue = Self.number(s.revenue), margin = Self.number(s.margin).map { $0 / 100 }
        let multiple = Self.number(s.multiple), shares = Self.number(self.shares)
        var result = ScenarioValue()
        if revenue == nil { result.missing.append("收入") }
        if method != .evSales && margin == nil { result.missing.append("利润率") }
        if multiple == nil { result.missing.append("倍数") }
        if shares == nil || shares == 0 { result.missing.append("股本") }
        guard result.missing.isEmpty, let revenue, let multiple, let shares else { return result }
        let cash = Self.number(netCash) ?? 0
        let equity: Double
        switch method {
        case .pe: equity = revenue * (margin ?? 0) * multiple
        case .evEbit: equity = revenue * (margin ?? 0) * multiple + cash
        case .evSales: equity = revenue * multiple + cash
        }
        let perShare = equity / shares
        var present = perShare
        if let rate = Self.number(discountRate).map({ $0 / 100 }), let years = Self.number(years), years > 0, rate > -1 {
            present = perShare / pow(1 + rate, years)
        }
        result.perShare = perShare
        result.present = present
        if let price = Self.number(price), price > 0 { result.upside = present / price - 1 }
        return result
    }

    /// Probability-weighted present value over the scenarios that have both a probability and a value.
    var weighted: (target: Double, probability: Double, upside: Double?)? {
        var total = 0.0, sum = 0.0
        for s in scenarios {
            guard let p = Self.number(s.probability), p > 0, let v = value(s).present else { continue }
            total += p; sum += p * v
        }
        guard total > 0 else { return nil }
        let target = sum / total
        let upside = Self.number(price).flatMap { $0 > 0 ? target / $0 - 1 : nil }
        return (target, total, upside)
    }
}

func numberText(_ value: Double?, digits: Int = 2) -> String {
    guard let value, value.isFinite else { return "—" }
    return value.formatted(.number.precision(.fractionLength(0...digits)).grouping(.automatic))
}
func percentText(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return (value >= 0 ? "+" : "") + (value * 100).formatted(.number.precision(.fractionLength(0...1))) + "%"
}

// MARK: - Pages and AI tasks

enum CompanyPage: String, CaseIterable {
    case cruxes, snapshot, checklist, scenarios, timeline, reports
    var title: String {
        switch self {
        case .cruxes: return "关键问题"
        case .snapshot: return "快照"
        case .checklist: return "排雷清单"
        case .scenarios: return "情景估值"
        case .timeline: return "时间线"
        case .reports: return "研究底稿"
        }
    }
    var symbol: String {
        switch self {
        case .cruxes: return "questionmark.diamond"
        case .snapshot: return "gauge.with.dots.needle.50percent"
        case .checklist: return "exclamationmark.shield"
        case .scenarios: return "function"
        case .timeline: return "clock.arrow.circlepath"
        case .reports: return "doc.text"
        }
    }
    var category: PageCategory { .company(self) }
    var englishLabel: String {
        switch self {
        case .cruxes: return "Key Questions"
        case .snapshot: return "Snapshot"
        case .checklist: return "Red Flags"
        case .scenarios: return "Scenarios"
        case .timeline: return "Timeline"
        case .reports: return "Research Notes"
        }
    }
}

enum CompanyTask: String, CaseIterable, Identifiable {
    case setup, snapshot, checklist, cruxes, timeline, thesis
    var id: String { rawValue }
    var title: String {
        switch self {
        case .setup: return "开题"
        case .snapshot: return "刷新快照"
        case .checklist: return "运行排雷清单"
        case .cruxes: return "补充关键问题"
        case .timeline: return "更新时间线"
        case .thesis: return "同步命题"
        }
    }
    var help: String {
        switch self {
        case .setup: return "AI 生成快照、研究底稿、候选关键问题和首轮排雷"
        case .snapshot: return "按 Wind 与公司披露更新快照"
        case .checklist: return "在后台跑完排雷清单，只把异常升级为问题"
        case .cruxes: return "补充候选关键问题，或挑战已确认的问题"
        case .timeline: return "把最近的季报、公告和新闻记到时间线上"
        case .thesis: return "把最新发布的判断同步到 LakeHouse Theses"
        }
    }
}

// MARK: - Loading

struct DependencyState: Equatable, Identifiable {
    enum Status: Equatable { case current, changed, missing }
    var dependency: TopicDependency
    var status: Status
    var topic: String
    var title: String
    var fingerprint: String
    var resolvedID: String
    var id: String { dependency.project + "/" + dependency.entry }
}

struct CompanyState {
    var snapshot: CompanySnapshot?
    var snapshotIssue: String?
    var checklist: Checklist?
    var checklistIssue: String?
    var scenarios = ScenarioBook()
    var scenariosRaw: String?
    var scenariosIssue: String?
    var lakehouse: LakehouseLink?
    var dependencies: [String: [DependencyState]] = [:]
    var changedDependencies: Int { dependencies.values.flatMap { $0 }.filter { $0.status != .current }.count }
}

enum CompanyFiles {
    static func fingerprint(_ entry: Entry) -> String {
        let digest = SHA256.hash(data: Data((entry.title + "\u{1F}" + entry.body + "\u{1F}" + String(entry.answered)).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func read<T: Decodable>(_ type: T.Type, _ name: String, in company: ProjectAt) -> (T?, String?, String?) {
        do {
            guard let raw = try Files.contents(Files.child(company.url, name)) else { return (nil, nil, nil) }
            do { return (try JSONDecoder().decode(type, from: Data(raw.utf8)), raw, nil) }
            catch { return (nil, raw, name + " 格式无法读取：" + error.localizedDescription) }
        } catch { return (nil, nil, name + "：" + error.localizedDescription) }
    }

    static func load(_ company: ProjectAt, snapshot: Snapshot, topics: [ProjectAt]) -> CompanyState {
        var state = CompanyState()
        (state.snapshot, _, state.snapshotIssue) = read(CompanySnapshot.self, "snapshot.json", in: company)
        (state.checklist, _, state.checklistIssue) = read(Checklist.self, "checklist.json", in: company)
        let (book, raw, issue) = read(ScenarioBook.self, "scenarios.json", in: company)
        state.scenarios = book ?? ScenarioBook(); state.scenariosRaw = raw; state.scenariosIssue = issue
        state.lakehouse = read(LakehouseLink.self, "lakehouse.json", in: company).0
        state.dependencies = dependencies(in: snapshot, topics: topics)
        return state
    }

    static func dependencies(in snapshot: Snapshot, topics: [ProjectAt]) -> [String: [DependencyState]] {
        let owners = snapshot.entries.filter { !$0.depends.isEmpty }
        guard !owners.isEmpty else { return [:] }
        var scans: [String: Snapshot?] = [:]
        var result: [String: [DependencyState]] = [:]
        for owner in owners {
            result[owner.id] = owner.depends.map { dependency in
                let topic = topics.first { $0.id == dependency.project }
                if scans[dependency.project] == nil {
                    scans[dependency.project] = .some(topic.flatMap { try? Files.scan($0.url, indexSources: false) })
                }
                guard let topic, let found = scans[dependency.project]??.resolve(dependency.entry) else {
                    return DependencyState(dependency: dependency, status: .missing, topic: topic?.info.title ?? "专题已移走",
                                           title: dependency.title, fingerprint: "", resolvedID: dependency.entry)
                }
                let mark = fingerprint(found)
                return DependencyState(dependency: dependency, status: mark == dependency.seen ? .current : .changed,
                                       topic: topic.info.title, title: found.title, fingerprint: mark, resolvedID: found.id)
            }
        }
        return result
    }

    static func saveScenarios(_ book: ScenarioBook, in company: ProjectAt, expected: String?) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(book), as: UTF8.self) + "\n"
        try Files.save(Files.child(company.url, "scenarios.json"), text, expected: expected)
        return text
    }
}

// MARK: - Workspace operations

extension Workspace {
    var isCompany: Bool { project?.info.stock != nil }

    private func ordered(_ items: [Entry]) -> [Entry] {
        items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var cruxes: [Entry] { ordered(snapshot.entries.filter { $0.kind == .questions && $0.role == "crux" && !$0.candidate }) }
    var candidateCruxes: [Entry] { ordered(snapshot.entries.filter { $0.kind == .questions && $0.role == "crux" && $0.candidate }) }
    var flagQuestions: [Entry] { ordered(snapshot.entries.filter { $0.kind == .questions && $0.role == "flag" }) }
    var otherQuestions: [Entry] {
        ordered(snapshot.entries.filter { $0.kind == .questions && !["crux", "flag", "sub"].contains($0.role) })
    }
    var dismissedCruxes: [Entry] { snapshot.all.filter { $0.kind == .questions && $0.deleted && $0.role == "crux" } }
    func subQuestions(of parent: Entry) -> [Entry] {
        let ids = Set([parent.id] + parent.aliases)
        return ordered(snapshot.entries.filter { $0.kind == .questions && $0.role == "sub" && ids.contains($0.parent) })
    }
    var timeline: [Entry] {
        snapshot.entries.filter { $0.kind == .events }.sorted {
            $0.date == $1.date ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.date > $1.date
        }
    }
    func events(affecting question: Entry) -> [(Entry, EventImpact)] {
        let ids = Set([question.id] + question.aliases)
        return timeline.compactMap { event in event.impacts.first { ids.contains($0.question) }.map { (event, $0) } }
    }
    func flagQuestion(for item: Checklist.Item) -> Entry? {
        snapshot.entries.first { $0.kind == .questions && $0.role == "flag" && $0.check == item.id }
            ?? item.question.text.nilIfEmpty.flatMap { snapshot.resolve($0) }
    }

    /// Reads the live file, applies the change and saves it, so edits never overwrite a newer AI write.
    func updateEntry(_ id: String, _ change: (inout Entry) throws -> Void) throws {
        guard let project else { throw Failure("请先打开项目。") }
        if let entry = snapshot.resolve(id), inlineNote?.path == entry.path, !finishInlineNote() { throw Failure("请先处理正文的保存冲突。") }
        guard var live = try Files.scan(project.url, indexSources: false).resolve(id) else { throw Failure("条目已合并或删除。") }
        try change(&live)
        try store(live)
    }

    func confirmCrux(_ id: String) { attempt { try updateEntry(id) { $0.candidate = false } } }
    /// The file remains with `deleted: true`, so later AI runs know the user rejected this question.
    func dismissCrux(_ id: String) { attempt { try updateEntry(id) { $0.deleted = true } } }

    func newCrux() {
        var entry = Entry(kind: .questions, title: "")
        entry.role = "crux"
        dialog = .editor(Editor(entry: entry))
    }
    func newSubQuestion(of parent: Entry) {
        var entry = Entry(kind: .questions, title: "")
        entry.role = isCompany ? "sub" : ""
        entry.parent = isCompany ? parent.id : ""
        entry.links = [parent.id]
        dialog = .editor(Editor(entry: entry))
    }
    func newEvent(affecting question: Entry? = nil) {
        var entry = Entry(kind: .events, title: "")
        entry.date = Date().formatted(.iso8601.year().month().day())
        if let question { entry.impacts = [EventImpact(question: question.id, direction: ImpactDirection.neutral.rawValue)] }
        dialog = .editor(Editor(entry: entry))
    }

    func addDependency(to questionID: String, topic: ProjectAt, entry: Entry) throws {
        try updateEntry(questionID) { question in
            guard !question.depends.contains(where: { $0.project == topic.id && $0.entry == entry.id }) else { return }
            question.depends.append(TopicDependency(project: topic.id, entry: entry.id, title: entry.title, seen: CompanyFiles.fingerprint(entry)))
        }
    }
    func acknowledge(_ state: DependencyState, for questionID: String) throws {
        try updateEntry(questionID) { question in
            guard let i = question.depends.firstIndex(of: state.dependency) else { return }
            question.depends[i].entry = state.resolvedID
            question.depends[i].title = state.title
            question.depends[i].seen = state.fingerprint
        }
    }
    func removeDependency(_ dependency: TopicDependency, from questionID: String) throws {
        try updateEntry(questionID) { $0.depends.removeAll { $0 == dependency } }
    }
    func openDependency(_ state: DependencyState) {
        guard let topic = projects.first(where: { $0.id == state.dependency.project }) else { error = "专题已移走。"; return }
        open(topic, at: .entry(state.resolvedID))
    }

    func researchLink(project: ProjectAt, target: String) -> String {
        var components = URLComponents()
        components.scheme = "feynman"
        components.host = "research"
        components.queryItems = [URLQueryItem(name: "project", value: project.id), URLQueryItem(name: "target", value: target)]
        return components.url?.absoluteString ?? ""
    }

    /// Writes an industry-level finding into a topic and makes the company question rely on it.
    @discardableResult
    func submitToTopic(_ item: Entry, topic: ProjectAt, title: String) throws -> Entry {
        guard let company = project, company.info.stock != nil else { throw Failure("请在个股项目中提交。") }
        guard [.questions, .events].contains(item.kind) else { throw Failure("只能提交问题或事件。") }
        if inlineNote?.path == item.path, !finishInlineNote() { throw Failure("请先处理正文的保存冲突。") }
        guard let live = try Files.scan(company.url, indexSources: false).resolve(item.id) else { throw Failure("条目已合并或删除。") }
        let link = researchLink(project: company, target: Place.entry(live.id).key)
        let safeTitle = (company.stockLabel + " · " + live.title).replacingOccurrences(of: "]", with: "\\]")
        var copy = Entry(kind: live.kind, title: title.clean.isEmpty ? live.title : title.clean,
                         body: live.body.clean + "\n\n> 来源：[" + safeTitle + "](<" + link + ">)\n", origin: "个股提交")
        copy.date = live.kind == .events ? live.date : ""
        try Files.write(copy, in: topic.url)
        if live.kind == .questions { try addDependency(to: live.id, topic: topic, entry: copy) }
        return copy
    }

    func createFlagQuestion(_ item: Checklist.Item) throws {
        var question = Entry(kind: .questions, title: "排雷：" + (item.title.text.isEmpty ? item.id : item.title.text), origin: "排雷清单")
        question.role = "flag"
        question.check = item.id
        let links = (item.evidence ?? []).compactMap { link -> String? in
            guard !link.url.text.isEmpty else { return nil }
            return "- [" + (link.title.text.isEmpty ? link.url.text : link.title.text) + "](" + link.url.text + ")" + (link.date.text.isEmpty ? "" : "，" + link.date.text)
        }
        question.body = item.finding.text + (links.isEmpty ? "" : "\n\n## 证据\n\n" + links.joined(separator: "\n")) + "\n"
        try store(question)
        go(.entry(question.id))
    }

    func saveScenarios(_ book: ScenarioBook) throws {
        guard let company = project, company.info.stock != nil else { throw Failure("请先打开个股项目。") }
        let raw = try CompanyFiles.saveScenarios(book, in: company, expected: self.company.scenariosRaw)
        self.company.scenarios = book
        self.company.scenariosRaw = raw
    }

    /// The first draft of a judgment, built only from what the user already wrote in the board and the scenarios.
    func thesisOutline() -> String {
        var lines = ["## 命题陈述", "", "", "## 与市场的分歧", ""]
        for crux in cruxes {
            lines.append("- **" + crux.title + "**")
            lines.append("  - 市场隐含：" + (crux.marketView.clean.isEmpty ? "—" : crux.marketView.clean))
            lines.append("  - 我的判断：" + (crux.myView.clean.isEmpty ? "（待填写）" : crux.myView.clean))
        }
        if cruxes.isEmpty { lines.append("") }
        lines += ["", "## 情景与估值", ""]
        let book = company.scenarios
        if !book.scenarios.isEmpty {
            lines += ["| 情景 | 概率 | 每股价值 | 相对现价 | 关键假设 |", "| --- | --- | --- | --- | --- |"]
            for s in book.scenarios {
                let v = book.value(s)
                let answers = cruxes.compactMap { crux in s.answers[crux.id].flatMap(CruxAnswer.init(rawValue:)).map { crux.title + "：" + $0.label } }
                let assumptions = (answers + [s.note.clean].filter { !$0.isEmpty }).joined(separator: "；")
                let probability = ScenarioBook.number(s.probability).map { numberText($0) + "%" } ?? "—"
                lines.append("| " + [s.name, probability, numberText(v.present), percentText(v.upside), assumptions.isEmpty ? "—" : assumptions].joined(separator: " | ") + " |")
            }
            if let w = book.weighted { lines += ["", "概率加权价值 " + numberText(w.target) + "，相对现价 " + percentText(w.upside) + "。"] }
        }
        lines += ["", "## 证伪条件", ""]
        lines += cruxes.filter { !$0.kill.clean.isEmpty }.map { "- " + $0.title + "：" + $0.kill.clean }
        lines += ["", "## 跟踪指标", ""]
        lines += cruxes.filter { !$0.tracking.clean.isEmpty }.map { "- " + $0.title + "：" + $0.tracking.clean }
        lines += ["", "## 仓位与执行", "", ""]
        return lines.joined(separator: "\n")
    }

    /// A LakeHouse-relative path as a document key of the current workspace.
    func lakehouseKey(_ path: String) -> String {
        let lakehouse = try? lakehouseRoot()
        let same = lakehouse != nil && lakehouse == root?.resolvingSymlinksInPath().standardizedFileURL
        return (same ? "library:" : "lakehouse:") + path
    }

    func companyAccent(for place: Place) -> PageCategory? {
        guard isCompany else { return nil }
        switch place {
        case .overview: return .stock
        case .company(let page): return page.category
        case .judgments, .judgmentEditor: return .judgment
        case .group(let kind): return .kind(kind)
        case .webLinks: return .kind(.references)
        case .entry(let id): return snapshot.resolve(id).map { .kind($0.kind) }
        case .doc(let path):
            if path.hasPrefix("reports/") { return CompanyPage.reports.category }
            if path == "log.md" { return .log }
            return .kind(.references)
        default: return .stock
        }
    }
}

extension String {
    var nilIfEmpty: String? { clean.isEmpty ? nil : self }
}

extension Terminal {
    @MainActor static func companyPrompt(_ task: CompanyTask, company: ProjectAt, root: URL, workspace m: Workspace, note: String = "") -> String {
        let skill = Terminal.skill(.company).clean
        let name = skill.isEmpty ? "sling-company-study" : skill
        var parts = ["使用 $" + name + " skill 执行「" + task.title + "」。Claude Code 的 skill 位于 ~/.claude/skills/" + name + "/SKILL.md；没有自动加载该 skill 时，先读取这个文件再执行。"]
        let folder = company.url.lastPathComponent
        parts.append("公司：" + company.stockLabel + "。当前工作目录是本公司的个股项目（Feynman/stocks/" + folder + "），文件格式按 skill 的「个股项目文件约定」。知识库根目录为 " + root.path + "。截至日期：" + Date().formatted(.iso8601.year().month().day()) + "。")
        parts.append("研究缘起：" + (company.info.intent.clean.isEmpty ? "未填写" : company.info.intent.clean))
        let links = company.info.stock?.links ?? []
        let topics = m.projects.filter { topic in links.contains { $0.projectID == topic.id } }
        parts.append("关联专题：" + (topics.isEmpty ? "暂无" : topics.map { $0.info.title + "（Feynman/" + $0.url.lastPathComponent + "）" }.joined(separator: "、")))
        func list(_ entries: [Entry]) -> String { entries.map { "- " + $0.title + "（" + $0.path + "）" }.joined(separator: "\n") }
        switch task {
        case .setup:
            parts.append("这是开题。完成快照、研究底稿、3–5 个候选关键问题和首轮排雷，回读核对后最后创建 preflight.done。")
        case .snapshot:
            parts.append("更新 snapshot.json，并在 log.md 记录触及关键问题市场假设的变化。")
        case .checklist:
            parts.append("按公司类型选取清单并逐项运行，写入 checklist.json；异常项升级为 role 为 flag 的问题。")
        case .cruxes:
            if !m.cruxes.isEmpty { parts.append("已确认的关键问题：\n" + list(m.cruxes)) }
            if !m.candidateCruxes.isEmpty { parts.append("尚未确认的候选问题：\n" + list(m.candidateCruxes)) }
            if !m.dismissedCruxes.isEmpty { parts.append("用户删除过的问题，不得以相同或同义的题目重新起草：\n" + m.dismissedCruxes.map { "- " + $0.title }.joined(separator: "\n")) }
        case .timeline:
            parts.append("现有事件的最晚日期：" + (m.timeline.first?.date.nilIfEmpty ?? "无"))
            if !m.cruxes.isEmpty { parts.append("已确认的关键问题：\n" + list(m.cruxes)) }
        case .thesis:
            if let latest = m.stockBook.history.first {
                parts.append("同步 research.json 中最新发布的判断「" + latest.title + "」（" + latest.date.formatted(.iso8601.year().month().day()) + "，ID " + latest.id.uuidString + "）。命题正文以用户发布的文字为准，不改写判断。")
            }
            if let path = m.company.lakehouse?.thesis { parts.append("上次同步的目标：" + path) }
        }
        if !note.clean.isEmpty { parts.append("用户补充：\n" + note.clean) }
        parts.append(task == .thesis
            ? "这是非交互运行，不要等待确认。知识库内只写 Theses/ 下的命题文件，再用绝对路径运行索引刷新脚本；其余结果写入当前公司目录。"
            : "这是非交互运行，不要等待确认。所有结果按文件约定写入当前公司目录，不写知识库的其他位置。")
        parts.append("完成后用中文简要列出：改动的文件、需要我填写或确认的项目、仍未取得的关键数据。")
        return parts.joined(separator: "\n\n")
    }
}
