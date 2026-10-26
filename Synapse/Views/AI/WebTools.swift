import Foundation
import PDFKit
import SynapseKit

/// Web search and page reading, straight from the iPhone (no account or API key): DuckDuckGo's HTML results with
/// Wikipedia as the fallback, and pages turned into plain text.
enum WebTools {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    static func search(_ query: String) async throws -> [WebResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        var req = URLRequest(url: comps.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-GB,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        req.timeoutInterval = 20
        if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 {
            let results = WebSearchParse.duckDuckGo(String(decoding: data, as: UTF8.self))
            if !results.isEmpty { return results }
        }
        // DuckDuckGo can rate-limit; Wikipedia is reliable for reference facts.
        var wiki = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        wiki.queryItems = [URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
                           URLQueryItem(name: "srsearch", value: q), URLQueryItem(name: "format", value: "json"),
                           URLQueryItem(name: "srlimit", value: "6")]
        var wreq = URLRequest(url: wiki.url!)
        wreq.setValue("Synapse/0.3 (iOS notes app)", forHTTPHeaderField: "User-Agent")
        wreq.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: wreq)
        return WebSearchParse.wikipedia(data)
    }

    /// A page as text: "Title\nURL\n\ntext". PDFs and plain text work too.
    static func fetch(_ address: String, limit: Int = 60_000) async throws -> String {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.contains("://") { a = "https://" + a }
        guard let url = URL(string: a), url.scheme == "https" || url.scheme == "http" else {
            throw AIError(message: "That isn't a web address: \(address)")
        }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 25
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        guard (200..<400).contains(http?.statusCode ?? 0) else {
            throw AIError(message: "The page answered \(http?.statusCode ?? 0).")
        }
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let final = http?.url?.absoluteString ?? url.absoluteString
        if type.contains("pdf") || url.pathExtension.lowercased() == "pdf" {
            let text = PDFDocument(data: data)?.string ?? ""
            return "PDF\n\(final)\n\n" + String(SourceText.tidy(text).prefix(limit))
        }
        let body = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if type.contains("html") || body.prefix(500).lowercased().contains("<html") {
            let title = HTMLText.title(body) ?? url.host ?? final
            return "\(title)\n\(final)\n\n" + HTMLText.text(body, limit: limit)
        }
        return "\(final)\n\n" + String(body.prefix(limit))
    }
}
