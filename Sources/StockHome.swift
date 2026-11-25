import SwiftUI
import UniformTypeIdentifiers

struct StockSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StockThesis: View {
    @ObservedObject var m: Workspace
    let company: ProjectAt
    @State private var identityEditor = false
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        PageHeading(title: "已发布判断与历史", category: .stock, metadata: company.stockLabel) {
                            Button("编辑公司资料") { identityEditor = true }
                        }
                        HStack(alignment: .top, spacing: 10) {
                            VStack(spacing: 10) {
                                current
                                StockHistory(m: m, company: company)
                            }.frame(maxWidth: .infinity)
                            VStack(spacing: 10) {
                                StockModels(m: m, company: company)
                                StockTopics(m: m, company: company)
                            }.frame(width: min(285, max(169, geometry.size.width * 0.31)))
                        }.padding(10)
                    }
                }.task(id: m.historyScrollTarget) {
                    if let id = m.historyScrollTarget { scroll.scrollTo(id, anchor: .top) }
                }
            }
        }
        .sheet(isPresented: $identityEditor) { StockIdentityEditor(m: m, company: company) }
    }
    private var current: some View {
        StockSection(title: "当前投资判断") {
            if let latest = m.stockBook.history.first {
                Text(latest.date.formatted(date: .long, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                Text(latest.conclusion).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text(latest.reason).foregroundStyle(.secondary).textSelection(.enabled)
                if !latest.body.isEmpty {
                    Reader(model: m, path: ".current-" + latest.id.uuidString + ".md", bodyText: latest.body, allowsEditing: false).frame(height: 100)
                }
                ForEach(latest.corrections) { item in CorrectionNote(item: item) }
            }
            Button(m.stockBook.draft != nil ? "继续编辑判断草稿" : m.stockBook.history.isEmpty ? "写下首次判断" : "更新判断") {
                m.attempt { try m.startJudgment() }
            }.foregroundStyle(ink)
        }
    }
}

struct StockJudgmentEditor: View {
    @ObservedObject var m: Workspace
    let company: ProjectAt
    @State private var editingForecast = false
    @State private var showForecast = false
    private func field<T>(_ path: WritableKeyPath<JudgmentDraft, T>, default fallback: T) -> Binding<T> {
        Binding(get: { m.stockBook.draft?[keyPath: path] ?? fallback }, set: { value in
            m.attempt { try m.modifyBook { $0.draft?[keyPath: path] = value } }
        })
    }
    var body: some View {
        if let draft = m.stockBook.draft {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("更新投资判断").font(.title2.bold())
                    Spacer()
                    Button("返回主页") { m.go(.overview) }
                    Button("发布判断") { m.attempt { try m.publishJudgment() } }.buttonStyle(Primary())
                }
                TextField("变动标题，例如下调检测毛利率假设、维持判断", text: field(\.title, default: ""))
                TextField("一句话投资结论", text: field(\.conclusion, default: ""), axis: .vertical)
                TextField("本次为什么调整或维持判断", text: field(\.reason, default: ""), axis: .vertical)
                Text("关键假设与引用依据").font(.headline)
                NoteBody(m: m, path: draft.path, text: (try? m.text(draft.path)) ?? "").frame(minHeight: 90)
                Divider()
                HStack {
                    Button(showForecast ? "收起盈利与估值" : "查看本次盈利与估值") { showForecast.toggle() }
                    Button("编辑本次摘要") { editingForecast = true }
                    Spacer()
                    Toggle("保存本次模型版本", isOn: field(\.archiveModel, default: false)).disabled(m.stockBook.mainModel == nil)
                }
                if showForecast {
                    ScrollView { ForecastTable(forecast: draft.forecast).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 130)
                }
            }.padding(16).textFieldStyle(.roundedBorder)
                .onAppear { showForecast = true }
                .sheet(isPresented: $editingForecast) {
                    ForecastEditor(draft: draft.forecast) { value in try m.modifyBook { $0.draft?.forecast = value } }
                }
        }
    }
}

struct CorrectionNote: View {
    let item: JudgmentCorrection
    var body: some View {
        Text("更正 · " + item.date.formatted(date: .abbreviated, time: .shortened) + "　" + item.text)
            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

struct StockHistory: View {
    @ObservedObject var m: Workspace
    let company: ProjectAt
    @State private var comparing: UUID?
    @State private var correcting: Judgment?
    @State private var correction = ""
    private var years: [Int] {
        Set(m.stockBook.history.map { Calendar.current.component(.year, from: $0.date) }).sorted(by: >)
    }
    private var records: [Judgment] {
        if let year = m.stockHistoryYear[company.id] {
            return m.stockBook.history.filter { Calendar.current.component(.year, from: $0.date) == year }
        }
        return Array(m.stockBook.history.prefix(3))
    }
    var body: some View {
        StockSection(title: "投资判断历史") {
            if records.isEmpty { Text("发布首次判断后在此留档。").foregroundStyle(.secondary) }
            ForEach(records) { record in
                let prior = m.stockBook.history.firstIndex { $0.id == record.id }.flatMap { m.stockBook.history.dropFirst($0 + 1).first }
                let expanded = m.stockHistorySelection[company.id]?.contains(record.id) == true
                VStack(alignment: .leading, spacing: 5) {
                    Button {
                        if expanded {
                            m.stockHistorySelection[company.id]?.remove(record.id)
                            m.lastHistoryRecord[company.id] = nil
                        } else {
                            m.stockHistorySelection[company.id, default: []].insert(record.id)
                            m.lastHistoryRecord[company.id] = record.id
                        }
                    } label: {
                        HStack {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            Text(record.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                            Text(prior == nil && record.title != "首次判断" ? "首次判断 · " + record.title : record.title).bold()
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Text(record.reason).textSelection(.enabled)
                    if let prior {
                        ForEach(Array(record.forecast.changes(since: prior.forecast).enumerated()), id: \.offset) { _, change in
                            Text(change).font(.caption.monospacedDigit()).foregroundStyle(ink).textSelection(.enabled)
                        }
                    }
                    if expanded {
                        Text(record.conclusion).bold().textSelection(.enabled)
                        if !record.body.isEmpty {
                            Reader(model: m, path: ".history-" + record.id.uuidString + ".md", bodyText: record.body, allowsEditing: false)
                                .frame(height: 170)
                        }
                        ForecastTable(forecast: record.forecast)
                        ForEach(record.corrections) { item in CorrectionNote(item: item) }
                        if let version = record.modelVersion { Button("打开当时的模型版本") { m.openStockFile(version) } }
                        HStack {
                            if prior != nil { Button("与上一版比较") { comparing = comparing == record.id ? nil : record.id } }
                            Button("更正") { correction = ""; correcting = record }
                        }
                        if comparing == record.id, let prior {
                            JudgmentDifference(before: prior, after: record)
                        }
                    }
                }.id(record.id)
                Divider()
            }
            if let year = m.stockHistoryYear[company.id] {
                HStack {
                    Picker("年份", selection: Binding(get: { year }, set: { m.stockHistoryYear[company.id] = $0 })) {
                        ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                    }.fixedSize()
                    Button("最近三次") { m.stockHistoryYear[company.id] = nil }
                }
            } else if let year = years.first {
                Button("查看全部") { m.stockHistoryYear[company.id] = year }.buttonStyle(.link)
            }
        }.sheet(item: $correcting) { record in
            VStack(alignment: .leading, spacing: 12) {
                Text("更正 · " + record.title).font(.headline)
                TextField("原录入内容及更正后的内容", text: $correction, axis: .vertical).lineLimit(3...8)
                HStack {
                    Spacer(); Button("取消") { correcting = nil }
                    Button("保存更正") {
                        m.attempt {
                            try m.modifyBook { book in
                                guard let i = book.history.firstIndex(where: { $0.id == record.id }) else { throw Failure("找不到判断记录。") }
                                book.history[i].corrections.append(JudgmentCorrection(text: correction.clean))
                            }
                            correcting = nil
                        }
                    }.disabled(correction.clean.isEmpty)
                }
            }.padding(20).frame(width: 410)
        }
    }
}

private struct JudgmentDifference: View {
    let before: Judgment, after: Judgment
    private var edits: [String] {
        let lines: (Judgment) -> [String] = { record in
            [record.title, record.conclusion, record.reason] + record.body.components(separatedBy: "\n")
        }
        return lines(after).difference(from: lines(before)).map { change in
            switch change {
            case .remove(_, let text, _): return "− " + text
            case .insert(_, let text, _): return "+ " + text
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("与「" + before.title + "」比较").font(.headline)
            Text(edits.isEmpty ? "正文相同" : edits.joined(separator: "\n")).textSelection(.enabled)
            let changes = after.forecast.changes(since: before.forecast)
            Text(changes.isEmpty ? "预测数字相同" : changes.joined(separator: "\n")).textSelection(.enabled)
        }.font(.callout).padding(8).background(rail)
    }
}

struct StockIdentityEditor: View {
    @ObservedObject var m: Workspace
    let company: ProjectAt
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var ticker = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("公司资料").font(.title2.bold())
            TextField("公司名称", text: $name)
            TextField("股票代码", text: $ticker)
            HStack { Spacer(); Button("取消") { dismiss() }
                Button("保存") {
                    guard let root = m.root else { return }
                    m.attempt { try Files.updateStock(root, id: company.id, identity: (name, ticker)); m.refreshProjects(); dismiss() }
                }.disabled(name.clean.isEmpty)
            }
        }.padding(20).frame(width: 370)
            .onAppear { name = company.info.title; ticker = company.info.stock?.ticker ?? "" }
    }
}
