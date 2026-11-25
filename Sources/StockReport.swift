import Foundation
import JavaScriptCore

/// Use the same block and inline grammar as the company reader, including its treatment
/// of code examples, HTML blocks, tables and reference-style image definitions.
@MainActor final class StockReportParser {
    private let context: JSContext
    private let split: JSValue

    init() throws {
        guard let context = JSContext() else { throw Failure("无法初始化全文解析器。") }
        self.context = context
        for name in ["marked.umd", "stock-report"] {
            guard let file = Bundle.main.url(forResource: name, withExtension: "js") else {
                throw Failure("找不到全文解析资源 " + name)
            }
            context.evaluateScript(try String(contentsOf: file, encoding: .utf8), withSourceURL: file)
            if let error = context.exception { throw Failure(error.toString()) }
        }
        split = context.objectForKeyedSubscript("splitStockReport")
    }

    func sections(_ report: String, final: Bool) throws -> [StockModule: String] {
        context.exception = nil
        let modules = StockModule.allCases
        let result = split.call(withArguments: [report, modules.map(\.heading), final])
        if let error = context.exception { throw Failure(error.toString()) }
        guard let bodies = result?.toArray() as? [String], bodies.count <= modules.count,
              !final || bodies.count == modules.count else { throw Failure("无法读取完整章节。") }
        return Dictionary(uniqueKeysWithValues: zip(modules, bodies))
    }
}
