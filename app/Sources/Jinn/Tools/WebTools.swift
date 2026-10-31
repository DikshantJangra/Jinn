import AppKit
import Foundation

enum Web {
    static func vet(_ s: String) -> String? {
        guard let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), let h = u.host?.lowercased()
        else { return "need a full http(s) URL" }
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".internal") { return "local and private network addresses are off limits" }
        var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(h, nil, &hints, &res) == 0, let first = res else { return "host does not resolve" }
        defer { freeaddrinfo(first) }
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            if isPrivate(ai.pointee) { return "local and private network addresses are off limits" }
            cur = ai.pointee.ai_next
        }
        return nil
    }

    private static func isPrivate(_ ai: addrinfo) -> Bool {
        if ai.ai_family == AF_INET {
            let a = ai.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let (b0, b1) = (a >> 24, (a >> 16) & 255)
            return b0 == 0 || b0 == 10 || b0 == 127 || (b0 == 169 && b1 == 254) || (b0 == 172 && (16...31).contains(b1))
                || (b0 == 192 && b1 == 168) || (b0 == 100 && (64...127).contains(b1)) || b0 >= 224
        }
        guard ai.ai_family == AF_INET6 else { return true }
        return ai.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sp -> Bool in
            let b = withUnsafeBytes(of: sp.pointee.sin6_addr) { Array($0) }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] <= 1 { return true }
            if b[0] & 0xFE == 0xFC || (b[0] == 0xFE && b[1] & 0xC0 == 0x80) { return true }
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
                return b[12] == 0 || b[12] == 10 || b[12] == 127 || (b[12] == 169 && b[13] == 254) || (b[12] == 172 && (16...31).contains(b[13])) || (b[12] == 192 && b[13] == 168)
            }
            return false
        }
    }

    private final class NoPrivateRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest q: URLRequest,
                        completionHandler done: @escaping (URLRequest?) -> Void) {
            done(q.url.flatMap { Web.vet($0.absoluteString) } == nil ? q : nil)
        }
    }

    static func url(_ a: [String: Any]) throws -> URL {
        let s = try a.str("url")
        if let why = vet(s) { throw JinnError.blocked(why) }
        return URL(string: s)!
    }

    static func request(_ url: URL, method: String = "GET") async throws -> (Data, HTTPURLResponse, Int) {
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = method
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let t0 = Date()
        let (d, resp) = try await URLSession.shared.data(for: r, delegate: NoPrivateRedirects())
        guard let h = resp as? HTTPURLResponse else { throw JinnError("no HTTP response") }
        return (d, h, Int(Date().timeIntervalSince(t0) * 1000))
    }

    static func text(_ html: String) -> String {
        var s = html
        for p in [#"(?is)<(script|style|noscript|svg)[^>]*>.*?</\1>"#, #"(?s)<!--.*?-->"#, #"(?s)<[^>]+>"#] {
            s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        return decode(s).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func decode(_ s: String) -> String {
        [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " ")]
            .reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    static func search(_ q: String, limit: Int) async throws -> String {
        var c = URLComponents(string: "https://html.duckduckgo.com/html/")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        let (d, h, _) = try await request(c.url!)
        guard h.statusCode == 200 else { throw JinnError("search failed: HTTP \(h.statusCode)") }
        let html = String(decoding: d, as: UTF8.self)
        let links = matches(#"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: html)
        let snippets = matches(#"class="result__snippet"[^>]*>(.*?)</a>"#, in: html)
        let out = links.prefix(limit).enumerated().map { i, l -> String in
            var url = decode(l[0])
            if url.hasPrefix("//") { url = "https:" + url }
            if let u = URLComponents(string: url), let real = u.queryItems?.first(where: { $0.name == "uddg" })?.value { url = real }
            let snip = i < snippets.count ? text(snippets[i][0]) : ""
            return "\(i + 1). \(text(l[1]))\n   \(url)\n   \(snip)"
        }
        return out.isEmpty ? "No results." : out.joined(separator: "\n")
    }

    private static func matches(_ pattern: String, in s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (1..<m.numberOfRanges).map { String(s[Range(m.range(at: $0), in: s)!]) }
        }
    }
}

let webTools: [Tool] = [
    Tool(name: "web_search", description: "Search the internet and return titles, URLs and snippets. Use for any question about current or outside information.",
         params: ["query": "Search query", "limit": "(optional) number of results, default 5"]) { a in
        try await Web.search(try a.str("query"), limit: max(1, min(10, Int(a.opt("limit")) ?? 5)))
    },
    Tool(name: "web_fetch", description: "Download a web page and return its readable text (first 6000 characters). Use after web_search to read a result.",
         params: ["url": "Full http(s) URL"], vet: { Web.vet($0.opt("url")) }) { a in
        let (d, h, _) = try await Web.request(try Web.url(a))
        guard (200..<300).contains(h.statusCode) else { throw JinnError("HTTP \(h.statusCode)") }
        let t = Web.text(String(decoding: d.prefix(1_500_000), as: UTF8.self))
        return String(t.prefix(6000))
    },
    Tool(name: "ping", description: "Check whether a website is up: returns the HTTP status and response time.",
         params: ["url": "Site URL, e.g. https://example.com"], vet: { Web.vet($0.opt("url")) }) { a in
        let u = try Web.url(a)
        do {
            var (_, h, ms) = try await Web.request(u, method: "HEAD")
            if h.statusCode == 405 || h.statusCode == 403 { (_, h, ms) = try await Web.request(u) }
            return "\(u.host ?? "site") is up: HTTP \(h.statusCode) in \(ms) ms"
        } catch { return "\(u.host ?? "site") is unreachable: \(error.localizedDescription)" }
    },
    Tool(name: "open_url", description: "Open a URL in the user's default browser.", params: ["url": "Full http(s) URL"],
         vet: { Web.vet($0.opt("url")) }) { a in
        NSWorkspace.shared.open(try Web.url(a))
        return "Opened."
    },
]
