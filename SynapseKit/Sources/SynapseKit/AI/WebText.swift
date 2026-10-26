import Foundation

/// Readable text from web pages and HTML files.
public enum HTMLText {
    /// The page's `<title>`.
    public static func title(_ html: String) -> String? {
        guard let r = html.range(of: "(?s)<title[^>]*>(.*?)</title>", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let inner = html[r].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let t = decode(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// The text of a page: scripts, styles, navigation and footers dropped; headings as `#`, list items as `-`,
    /// paragraphs on their own lines.
    public static func text(_ html: String, limit: Int = 400_000) -> String {
        var s = String(html.prefix(limit * 4))
        let drop = ["script", "style", "noscript", "svg", "template", "iframe", "nav", "footer", "aside", "form", "head"]
        s = s.replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
        for tag in drop {
            s = s.replacingOccurrences(of: "(?s)<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Source line breaks mean nothing in HTML; only tags break lines.
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        for level in 1...6 {
            s = s.replacingOccurrences(of: "<h\(level)\\b[^>]*>", with: "\n\n" + String(repeating: "#", count: level) + " ",
                                       options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<li\\b[^>]*>", with: "\n- ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<(td|th)\\b[^>]*>", with: " | ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(ul|ol|table)>", with: "\n\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(p|div|section|article|main|header|h[1-6]|blockquote|pre|figure)>",
                                   with: "\n\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(tr|dd|dt|figcaption)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decode(s)
        // Collapse spaces inside lines, then blank lines.
        let lines = s.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: "[ \\t\\x{00A0}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        return String(SourceText.tidy(lines.joined(separator: "\n")).prefix(limit))
    }

    static let named: [String: String] = [
        "nbsp": " ", "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘", "ldquo": "“", "rdquo": "”",
        "copy": "©", "reg": "®", "trade": "™", "middot": "·", "bull": "•", "times": "×", "deg": "°", "euro": "€",
        "pound": "£", "laquo": "«", "raquo": "»", "shy": "",
    ]

    /// XML entities plus the common named HTML ones.
    public static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (name, value) in named { out = out.replacingOccurrences(of: "&\(name);", with: value) }
        return SourceText.decodeEntities(out)
    }
}

/// One web search result.
public struct WebResult: Equatable, Sendable {
    public var title: String
    public var url: String
    public var snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// Parses search pages that need no API key.
public enum WebSearchParse {
    /// Results from DuckDuckGo's HTML page (`https://html.duckduckgo.com/html/?q=…`), ads left out.
    public static func duckDuckGo(_ html: String) -> [WebResult] {
        let ns = html as NSString
        guard let linkRE = try? NSRegularExpression(pattern: "<a\\b([^>]*\\bclass=\"[^\"]*result__a[^\"]*\"[^>]*)>(.*?)</a>",
                                                    options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let snippetRE = try? NSRegularExpression(pattern: "<(?:a|div|td)\\b[^>]*\\bclass=\"[^\"]*result__snippet[^\"]*\"[^>]*>(.*?)</(?:a|div|td)>",
                                                       options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let links = linkRE.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let snippets = snippetRE.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [WebResult] = []
        for (i, m) in links.enumerated() {
            let attrs = ns.substring(with: m.range(at: 1))
            guard let hrefRange = attrs.range(of: "href=\"([^\"]+)\"", options: .regularExpression) else { continue }
            let href = String(attrs[hrefRange].dropFirst(6).dropLast())
            let url = unwrapDuckDuckGo(HTMLText.decode(href))
            guard url.hasPrefix("http"), !url.contains("duckduckgo.com/y.js"), !url.contains("ad_provider") else { continue }
            let title = plain(ns.substring(with: m.range(at: 2)))
            // Snippets come in the same order as titles; pair each title with the next snippet after it.
            let snippet = snippets.first { $0.range.location > m.range.location && (i + 1 >= links.count || $0.range.location < links[i + 1].range.location) }
                .map { plain(ns.substring(with: $0.range(at: 1))) } ?? ""
            if !title.isEmpty && !out.contains(where: { $0.url == url }) {
                out.append(WebResult(title: title, url: url, snippet: snippet))
            }
        }
        return out
    }

    /// DuckDuckGo wraps result links as `//duckduckgo.com/l/?uddg=<encoded url>&rut=…`.
    public static func unwrapDuckDuckGo(_ href: String) -> String {
        var h = href
        if h.hasPrefix("//") { h = "https:" + h }
        guard let comps = URLComponents(string: h), comps.host?.hasSuffix("duckduckgo.com") == true,
              let target = comps.queryItems?.first(where: { $0.name == "uddg" })?.value else { return h }
        return target
    }

    /// Results from the Wikipedia search API (`/w/api.php?action=query&list=search&format=json`).
    public static func wikipedia(_ data: Data, language: String = "en") -> [WebResult] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any], let search = query["search"] as? [[String: Any]] else { return [] }
        return search.compactMap { item in
            guard let title = item["title"] as? String else { return nil }
            let path = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
            return WebResult(title: title, url: "https://\(language).wikipedia.org/wiki/\(path)", snippet: plain(item["snippet"] as? String ?? ""))
        }
    }

    static func plain(_ html: String) -> String {
        HTMLText.decode(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Results as a compact numbered list for a model.
    public static func format(_ results: [WebResult], limit: Int = 6) -> String {
        if results.isEmpty { return "No results." }
        return results.prefix(limit).enumerated().map { "\($0.offset + 1). \($0.element.title)\n   \($0.element.url)\n   \($0.element.snippet)" }
            .joined(separator: "\n")
    }
}
