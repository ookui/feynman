import Foundation
import PDFKit

/// Inspect a single GET, including redirects. Stop reading ordinary pages after the prefix;
/// stream PDFs to disk so a large report (or a single-use URL) only needs one transfer.
final class PDFLinkDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct File {
        let url: URL
        let name: String
    }

    private let source: URL
    private let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
    private var completion: CheckedContinuation<File?, Error>?
    private var prefix = Data()
    private var output: FileHandle?
    private var expectedPDF: Bool
    private var ordinaryPage = false
    private var htmlResponse = false
    private var failure: Error?

    init(source: URL) {
        self.source = source
        expectedPDF = source.pathExtension.lowercased() == "pdf"
    }

    func fetch(configuration: URLSessionConfiguration = .ephemeral) async throws -> File? {
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            var request = URLRequest(url: source)
            request.timeoutInterval = 20
            session.dataTask(with: request).resume()
            session.finishTasksAndInvalidate()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        htmlResponse = ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "")
        let name = response.suggestedFilename ?? ""
        expectedPDF = expectedPDF || response.mimeType?.lowercased() == "application/pdf" ||
            (name as NSString).pathExtension.lowercased() == "pdf" || response.url?.pathExtension.lowercased() == "pdf"
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if expectedPDF { failure = Failure("PDF 下载失败，服务器返回 HTTP " + String((response as? HTTPURLResponse)?.statusCode ?? 0)) }
            else { ordinaryPage = true }
            completionHandler(.cancel)
            return
        }
        // A partial response to our full GET must never be stored as the original.
        if http.statusCode == 206 {
            let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            let size = range.split(separator: "/").last.flatMap { Int64($0) } ?? 0
            if size <= 0 || range.lowercased() != "bytes 0-\(size - 1)/\(size)" {
                failure = Failure("服务器只返回了部分文件，请使用完整下载链接。")
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, !ordinaryPage else { return }
        do {
            if let output { try output.write(contentsOf: data); return }
            prefix.append(data)
            if prefix.count >= 1024 || prefix.starts(with: "%PDF-".utf8) {
                try classifyPrefix()
                if ordinaryPage { dataTask.cancel() }
            }
        } catch { failure = error; dataTask.cancel() }
    }

    private func classifyPrefix() throws {
        let head = prefix.prefix(1024)
        let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.hasPrefix("<"), head.range(of: Data("%PDF-".utf8)) != nil else {
            let html = htmlResponse || text.lowercased().hasPrefix("<html") || text.lowercased().hasPrefix("<!doctype html")
            if expectedPDF && !html { throw Failure("下载内容不是可读取的 PDF。") }
            ordinaryPage = true
            prefix.removeAll()
            return
        }
        expectedPDF = true
        try prefix.write(to: temporary, options: .withoutOverwriting)
        output = try FileHandle(forWritingTo: temporary)
        try output?.seekToEnd()
        prefix.removeAll()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { completion = nil }
        do {
            if let failure { throw failure }
            if !ordinaryPage, let error {
                if expectedPDF { throw error }
                ordinaryPage = true // The URL can still be bookmarked when a page is offline.
            }
            if output == nil && !ordinaryPage { try classifyPrefix() }
            if ordinaryPage { completion?.resume(returning: nil); return }
            try output?.close()
            output = nil
            guard let pdf = PDFDocument(url: temporary), pdf.isLocked || pdf.pageCount > 0 else {
                throw Failure("下载文件无法作为 PDF 打开，请检查原始链接。")
            }
            let name = task.response?.suggestedFilename ?? source.lastPathComponent
            completion?.resume(returning: File(url: temporary, name: name))
        } catch {
            try? output?.close()
            try? FileManager.default.removeItem(at: temporary)
            completion?.resume(throwing: error)
        }
    }
}
