import Foundation

extension Files {
    // Serialize company creation and bindings across windows or processes sharing this library.
    static func createStock(_ root: URL, name: String, ticker: String, link: StockLink?) throws -> ProjectAt {
        let name = name.clean, ticker = ticker.clean.uppercased()
        let folder = name + (ticker.isEmpty ? "" : " (" + ticker + ")")
        guard !name.isEmpty, !folder.hasPrefix("."), !folder.contains("/"), folder.utf8.count < 230 else {
            throw Failure("请填写有效的公司名称和代码。")
        }
        let base = try child(root, "Feynman/stocks")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return try locked(base) {
            let companies = try catalog(root, stocks: true)
            guard !companies.contains(where: {
                $0.info.title.localizedCaseInsensitiveCompare(name) == .orderedSame &&
                $0.info.stock?.ticker.localizedCaseInsensitiveCompare(ticker) == .orderedSame
            }) else { throw Failure("已存在相同名称和代码的公司，请从已有档案中选择。") }
            if let link { try validateLink(root, link: link, companies: companies) }
            var info = Project(title: name, intent: "")
            info.stock = StockProfile(ticker: ticker, links: link.map { [$0] } ?? [])
            return try createProject(root, folder: folder, info: info)
        }
    }

    private static func validateLink(_ root: URL, link: StockLink, companies: [ProjectAt]) throws {
        guard let topic = try projects(root).first(where: { $0.id == link.projectID }),
              let entity = try scan(topic.url).resolve(link.entityID), entity.kind == .entities else { throw Failure("专题中的实体已移走。") }
        let ids = Set(entity.aliases + [entity.id])
        guard !companies.contains(where: { $0.info.stock?.links.contains { $0.projectID == topic.id && ids.contains($0.entityID) } == true }) else {
            throw Failure("该实体已关联一家公司，请先解除现有关联。")
        }
    }

    static func updateStock(_ root: URL, id: String, adding: StockLink? = nil, removing: Set<StockLink> = [],
                            identity: (String, String)? = nil) throws {
        try locked(child(root, "Feynman/stocks")) {
            let stocks = try catalog(root, stocks: true)
            guard let company = stocks.first(where: { $0.id == id }) else { throw Failure("公司目录已移走。") }
            let file = try child(company.url, "project.json")
            let raw = try contents(file)
            guard var info = decode(Project.self, raw), info.id == id, var profile = info.stock else { throw Failure("无法读取公司档案。") }
            if let adding {
                try validateLink(root, link: adding, companies: stocks)
                profile.links.append(adding)
            }
            profile.links.removeAll { removing.contains($0) }
            if let (name, ticker) = identity {
                guard !name.clean.isEmpty else { throw Failure("请填写公司名称。") }
                info.title = name.clean
                profile.ticker = ticker.clean.uppercased()
            }
            info.stock = profile
            try save(file, json(info), expected: raw)
        }
    }
}

struct ForecastMetric: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var unit = ""
    var basis = ""
    var values: [String: String] = [:]
    var label: String { [name, basis, unit].filter { !$0.clean.isEmpty }.joined(separator: " · ") }
}

struct Forecast: Codable, Equatable {
    var years: [String] = []
    var metrics: [ForecastMetric] = []
    var price = ""
    var priceDate = ""
    var updated: Date?

    func validated() throws -> Forecast {
        guard Set(years.map(\.clean)).count == years.count, years.allSatisfy({ !$0.clean.isEmpty }),
              metrics.allSatisfy({ !$0.name.clean.isEmpty && !$0.unit.clean.isEmpty && !$0.basis.clean.isEmpty }),
              price.clean.isEmpty || !priceDate.clean.isEmpty else {
            throw Failure("请填写唯一的财年、指标名称、单位和口径。采用股价时请填写价格日期。")
        }
        return self
    }

    func changes(since old: Forecast) -> [String] {
        var result: [String] = []
        for id in metrics.map(\.id) + old.metrics.map(\.id).filter({ id in !metrics.contains { $0.id == id } }) {
            let before = old.metrics.first { $0.id == id }, after = metrics.first { $0.id == id }
            let label = after?.label ?? before?.label ?? ""
            for year in Set(years + old.years).sorted() {
                let a = before?.values[year] ?? "", b = after?.values[year] ?? ""
                if a != b || (before?.label != after?.label && !a.isEmpty && !b.isEmpty) {
                    let oldLabel = before?.label != after?.label && !a.isEmpty && after != nil ? " (" + (before?.label ?? "") + ")" : ""
                    result.append("\(year) · \(label)　\(a.isEmpty ? "—" : a)\(oldLabel) → \(b.isEmpty ? "—" : b)")
                }
            }
        }
        if price != old.price || priceDate != old.priceDate {
            result.append("估值股价　" + [old.price, old.priceDate].filter { !$0.isEmpty }.joined(separator: " ") + " → " + [price, priceDate].filter { !$0.isEmpty }.joined(separator: " "))
        }
        return result
    }
}

struct JudgmentDraft: Codable, Equatable, Identifiable {
    var id = UUID()
    var title = ""
    var conclusion = ""
    var reason = ""
    var forecast = Forecast()
    var archiveModel = false
    var path: String { ".judgment-" + id.uuidString + ".md" }
}
struct JudgmentCorrection: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    var text: String
}
struct Judgment: Codable, Equatable, Identifiable {
    var id: UUID
    var date: Date
    var title: String
    var conclusion: String
    var reason: String
    var body: String
    var forecast: Forecast
    var modelVersion: String?
    var corrections: [JudgmentCorrection] = []
}
struct StockBook: Codable, Equatable {
    var forecast = Forecast()
    var history: [Judgment] = [] // Publication order, newest first.
    var draft: JudgmentDraft?
    var mainModel: String?
    var homeLayout: StockHomeLayout?
}

enum StockFiles {
    static let workbookTypes: Set<String> = ["xlsx", "xlsm", "xls", "xlsb", "xltx", "xltm"]
    static func load(_ company: ProjectAt) throws -> (StockBook, String?) {
        let raw = try Files.contents(Files.child(company.url, "research.json"))
        guard let raw else { return (StockBook(), nil) }
        guard let book = decode(StockBook.self, raw) else { throw Failure("个股判断档案无法读取：" + company.info.title) }
        return (book, raw)
    }
    static func save(_ book: StockBook, in company: ProjectAt, expected: String?) throws -> String {
        let text = try json(book)
        try Files.save(Files.child(company.url, "research.json"), text, expected: expected)
        return text
    }
    static func legacyReports(in company: ProjectAt) throws -> [String] {
        let directory = try Files.child(company.url, "reports")
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try Files.list(directory).filter { $0.pathExtension.lowercased() == "md" }.map { "reports/" + $0.lastPathComponent }
    }
    static func documents(in company: ProjectAt) throws -> [URL] {
        try Files.list(Files.child(company.url, "documents")).filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
    }
    static func copyDocument(_ source: URL, to company: ProjectAt) throws -> String {
        guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure("请选择文件。") }
        let directory = try Files.child(company.url, "documents")
        let name = source.lastPathComponent
        var destination = try Files.child(directory, name)
        if source.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath() {
            return "documents/" + name
        }
        var suffix = 2
        while fm.fileExists(atPath: destination.path) {
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            destination = try Files.child(directory, base + " (\(suffix))" + (ext.isEmpty ? "" : "." + ext))
            suffix += 1
        }
        try fm.copyItem(at: source, to: destination)
        return "documents/" + destination.lastPathComponent
    }
}
