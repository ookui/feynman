import SwiftUI
import WebKit

struct MHTMLPreview: NSViewRepresentable {
    let url: URL

    static func supports(_ url: URL) -> Bool {
        ["mhtml", "mht"].contains(url.pathExtension.lowercased())
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let url: URL
        let shell = Bundle.main.url(forResource: "mhtml", withExtension: "html")
        init(url: URL) { self.url = url }

        @MainActor func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            guard web.url == shell else { return }
            let file = url
            Task {
                do {
                    let encoded = try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: file, options: .mappedIfSafe).base64EncodedString()
                    }.value
                    _ = try await web.callAsyncJavaScript("showMHTML(encoded); return true", arguments: ["encoded": encoded],
                                                      in: nil, contentWorld: .page)
                } catch {
                    let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    _ = try? await web.callAsyncJavaScript("document.querySelector('#status').textContent = message",
                        arguments: ["message": "无法读取网页存档。 " + detail], in: nil, contentWorld: .page)
                }
            }
        }
        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let destination = action.request.url
            if destination == shell || (action.targetFrame?.isMainFrame == false &&
                ["blob","about"].contains(destination?.scheme?.lowercased() ?? "")) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if action.navigationType == .linkActivated, let destination, MaterialLinks.isWeb(destination.absoluteString) {
                    NSWorkspace.shared.open(destination)
                }
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        if let shell = context.coordinator.shell {
            web.loadFileURL(shell, allowingReadAccessTo: shell.deletingLastPathComponent())
        }
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {}
}
