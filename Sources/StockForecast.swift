import SwiftUI

struct ForecastTable: View {
    let forecast: Forecast
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !forecast.metrics.isEmpty {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                        GridRow {
                            Text("指标 / 口径").fontWeight(.semibold)
                            ForEach(forecast.years.sorted(), id: \.self) { Text($0).bold() }
                        }
                        Divider()
                        ForEach(forecast.metrics) { metric in
                            GridRow {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(metric.name)
                                    Text([metric.basis, metric.unit].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(forecast.years.sorted(), id: \.self) { year in Text(metric.values[year] ?? "—").monospacedDigit() }
                            }
                        }
                    }.textSelection(.enabled)
                }
            } else { Text("暂无预测指标").foregroundStyle(.secondary) }
            if !forecast.price.isEmpty { Text("估值采用股价　" + forecast.price + "　" + forecast.priceDate) }
            if let date = forecast.updated { Text("摘要更新于 " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct ForecastEditor: View {
    @Environment(\.dismiss) var dismiss
    @State var draft: Forecast
    let save: (Forecast) throws -> Void
    @State private var year = ""
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑盈利与估值摘要").font(.title2.bold())
            HStack {
                TextField("财年，例如 FY2028", text: $year).frame(width: 160)
                Button("添加财年") {
                    let key = year.clean
                    if !key.isEmpty && !draft.years.contains(key) { draft.years.append(key); draft.years.sort(); year = "" }
                }.disabled(year.clean.isEmpty || draft.years.contains(year.clean))
                Menu("移除财年") {
                    ForEach(draft.years, id: \.self) { key in Button(key) {
                        draft.years.removeAll { $0 == key }
                        for index in draft.metrics.indices { draft.metrics[index].values[key] = nil }
                    } }
                }.fixedSize().disabled(draft.years.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($draft.metrics) { $metric in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("指标，如远期 PE", text: $metric.name)
                                TextField("单位及币种，如美元/股", text: $metric.unit)
                                Button { draft.metrics.removeAll { $0.id == metric.id } } label: { Image(systemName: "minus.circle") }.help("移除指标")
                            }
                            TextField("口径，如 GAAP、调整后 EPS、以调整后 EPS 计算", text: $metric.basis)
                            ScrollView(.horizontal) {
                                HStack {
                                    ForEach(draft.years, id: \.self) { key in
                                        VStack(alignment: .leading) {
                                            Text(key).font(.caption)
                                            TextField("数值", text: Binding(get: { metric.values[key] ?? "" }, set: { metric.values[key] = $0 })).frame(width: 95)
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                    }
                    Button("添加指标") { draft.metrics.append(ForecastMetric()) }
                }
            }
            HStack {
                TextField("估值股价及币种（选填）", text: $draft.price)
                TextField("股价日期 YYYY-MM-DD", text: $draft.priceDate)
            }
            if !message.isEmpty { Text(message).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("取消") { dismiss() }
                Button("保存摘要") { do { try save(draft.validated()); dismiss() } catch { message = error.localizedDescription } }
                    .keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(22).frame(width: 610, height: 475)
    }
}
