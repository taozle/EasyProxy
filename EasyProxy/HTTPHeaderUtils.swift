import NIOHTTP1

enum HTTPHeaderUtils {

    // MARK: - Absolute URI parsing

    /// Parse an absolute URI like `http://example.com:8080/path?q=1` into (host, port, path).
    static func parseAbsoluteURI(_ uri: String) -> (host: String, port: Int, path: String)? {
        // Must start with http:// or https://
        let lowered = uri.lowercased()
        let defaultPort: Int
        let stripped: String

        if lowered.hasPrefix("http://") {
            defaultPort = 80
            stripped = String(uri.dropFirst("http://".count))
        } else if lowered.hasPrefix("https://") {
            defaultPort = 443
            stripped = String(uri.dropFirst("https://".count))
        } else {
            return nil
        }

        // Split authority and path
        let authority: String
        let path: String
        if let slashIndex = stripped.firstIndex(of: "/") {
            authority = String(stripped[stripped.startIndex..<slashIndex])
            path = String(stripped[slashIndex...])
        } else {
            authority = stripped
            path = "/"
        }

        // Split host and port
        let host: String
        let port: Int

        // Handle IPv6: [::1]:port
        if authority.hasPrefix("[") {
            if let closeBracket = authority.firstIndex(of: "]") {
                host = String(authority[authority.index(after: authority.startIndex)...authority.index(before: closeBracket)])
                let afterBracket = authority[authority.index(after: closeBracket)...]
                if afterBracket.hasPrefix(":"), let p = Int(afterBracket.dropFirst()) {
                    port = p
                } else {
                    port = defaultPort
                }
            } else {
                return nil
            }
        } else if let colonIndex = authority.lastIndex(of: ":") {
            host = String(authority[authority.startIndex..<colonIndex])
            port = Int(authority[authority.index(after: colonIndex)...]) ?? defaultPort
        } else {
            host = authority
            port = defaultPort
        }

        guard !host.isEmpty else { return nil }
        return (host: host, port: port, path: path)
    }

    // MARK: - CONNECT target parsing

    /// Parse `host:port` from a CONNECT request URI.
    static func parseConnectTarget(_ uri: String) -> (host: String, port: Int)? {
        // Handle IPv6: [::1]:443
        if uri.hasPrefix("[") {
            guard let closeBracket = uri.firstIndex(of: "]") else { return nil }
            let host = String(uri[uri.index(after: uri.startIndex)..<closeBracket])
            let rest = uri[uri.index(after: closeBracket)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        }

        guard let colonIndex = uri.lastIndex(of: ":") else { return nil }
        let host = String(uri[uri.startIndex..<colonIndex])
        guard let port = Int(uri[uri.index(after: colonIndex)...]) else { return nil }
        guard !host.isEmpty, port > 0, port <= 65535 else { return nil }
        return (host, port)
    }

    // MARK: - Extract target from request

    /// Extract target (host, port) from either the absolute URI or Host header.
    static func extractTarget(from request: HTTPRequestHead) -> (host: String, port: Int)? {
        // Try absolute URI first
        if let parsed = parseAbsoluteURI(request.uri) {
            return (parsed.host, parsed.port)
        }

        // Fall back to Host header
        guard let hostHeader = request.headers["Host"].first else { return nil }
        if let colonIndex = hostHeader.lastIndex(of: ":"),
           !hostHeader.hasPrefix("[") || hostHeader.contains("]:") {
            let host: String
            let portStr: String
            if hostHeader.hasPrefix("["), let closeBracket = hostHeader.firstIndex(of: "]") {
                host = String(hostHeader[hostHeader.index(after: hostHeader.startIndex)..<closeBracket])
                let rest = hostHeader[hostHeader.index(after: closeBracket)...]
                guard rest.hasPrefix(":") else { return (host, 80) }
                portStr = String(rest.dropFirst())
            } else {
                host = String(hostHeader[hostHeader.startIndex..<colonIndex])
                portStr = String(hostHeader[hostHeader.index(after: colonIndex)...])
            }
            let port = Int(portStr) ?? 80
            return (host, port)
        }
        return (hostHeader, 80)
    }

    // MARK: - Hop-by-hop header removal

    private static let hopByHopHeaders: Set<String> = [
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "proxy-connection",
        "te",
        "trailers",
        "upgrade",
    ]

    /// Remove hop-by-hop headers from the given headers.
    static func removeHopByHopHeaders(_ headers: inout HTTPHeaders) {
        // Also remove headers listed in Connection header
        let connectionValues = headers["Connection"].flatMap {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }

        for name in hopByHopHeaders {
            headers.remove(name: name)
        }
        for name in connectionValues {
            headers.remove(name: name)
        }
    }

    /// Rewrite absolute URI to relative path for upstream request.
    static func rewriteURIToRelative(_ uri: String) -> String {
        guard let parsed = parseAbsoluteURI(uri) else { return uri }
        return parsed.path
    }
}
