import SwiftUI
import WebKit

struct ProjectGraphData: Codable, Equatable {
    struct Node: Codable, Equatable {
        let path: String
        let title: String
        let color: String
    }
    let nodes: [Node]
    let edges: [[Int]]

    init(_ snapshot: Snapshot) {
        var rows = snapshot.entries.map { entry in
            let category: PageCategory = snapshot.isWebReference(entry) ? .webLinks : .kind(entry.kind)
            return Node(path: entry.path, title: (entry.core ? "★ " : "") + entry.title, color: category.cssColor)
        }
        let documents = Set(snapshot.reports + snapshot.documents + ["memo.md", "log.md"])
        rows += documents.sorted().map { Node(path: $0, title: documentLabel($0), color: PageCategory(document: $0).cssColor) }
        var seen = Set<String>()
        nodes = rows.filter { seen.insert($0.path).inserted }
        let indices = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.path, $0) })
        var links = Set<[Int]>()
        func connect(_ from: String, _ to: String) {
            if let a = indices[from], let b = indices[to], a != b { links.insert([a,b]) }
        }
        for e in snapshot.entries {
            for id in e.links { if let target = snapshot.resolve(id) { connect(e.path, target.path) } }
            for path in e.reportLinks + e.anchors.map(\.report) { connect(e.path, path) }
            for path in snapshot.citations[e.id] ?? [] { connect(path, e.path) }
            for asset in e.assets {
                if let ref = snapshot.reference(for: asset, from: e.path) { connect(e.path, ref.path) }
            }
        }
        edges = links.sorted { $0.lexicographicallyPrecedes($1) }
    }
}

struct ProjectGraph: NSViewRepresentable {
    @ObservedObject var model: Workspace
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let model: Workspace
        var ready = false
        var data: ProjectGraphData?
        init(_ model: Workspace) { self.model = model }
        func draw(_ web: WKWebView) {
            guard ready, let data, let value = try? json(data) else { return }
            web.evaluateJavaScript("projectGraph.update(" + value + ")")
        }
        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) { ready = true; draw(web) }
        @MainActor func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let path = message.body as? String, data?.nodes.contains(where: { $0.path == path }) == true else { return }
            if let e = model.snapshot.entry(at: path) { model.go(.entry(e.id)) }
            else if model.valid(.doc(path)) { model.go(.doc(path)) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "graph")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        if let page = Bundle.main.url(forResource: "graph", withExtension: "html") {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        let next = ProjectGraphData(model.snapshot)
        if context.coordinator.data != next { context.coordinator.data = next; context.coordinator.draw(web) }
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "graph")
    }
}
