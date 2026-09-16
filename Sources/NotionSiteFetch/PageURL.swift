import Foundation

public enum NotionPageURL: Sendable {
    /// Chooses the public API host. `*.notion.site` stays on that subdomain
    /// so requests hit the right Notion cell.
    ///
    /// `https://app.notion.com/p/<space>/...` is the published-page form of
    /// `<space>.notion.site`, so those calls go to the space host as well.
    public static func apiBase(for targetURL: URL) -> String {
        let hostname = (targetURL.host ?? "").lowercased()
        if hostname.hasSuffix(".notion.site") {
            return "https://\(hostname)/api/v3"
        }
        if let spaceDomain = spaceDomain(from: targetURL) {
            return "https://\(spaceDomain).notion.site/api/v3"
        }
        if hostname == "app.notion.com" {
            return "https://app.notion.com/api/v3"
        }
        return "https://www.notion.so/api/v3"
    }

    /// Published-site slug from `*.notion.site` or `/p/<slug>/...`.
    public static func spaceDomain(from targetURL: URL) -> String? {
        let hostname = (targetURL.host ?? "").lowercased()
        if hostname.hasSuffix(".notion.site") {
            let slug = String(hostname.dropLast(".notion.site".count))
            return isSpaceDomain(slug) ? slug : nil
        }
        let parts = pathComponents(of: targetURL)
        if parts.first == "p", parts.count >= 2, isSpaceDomain(parts[1]) {
            return parts[1]
        }
        return nil
    }

    /// Last 32 hex characters in the path, formatted as a Notion UUID.
    public static func pageID(fromPath path: String) -> String? {
        hexID(in: path)
    }

    public static func pageID(from targetURL: URL) -> String? {
        for key in ["p", "pageId", "page_id"] {
            if let value = queryValue(targetURL, key), let id = hexID(in: value) {
                return id
            }
        }
        if let last = pathComponents(of: targetURL).last, let id = hexID(in: last) {
            return id
        }
        let path = targetURL.path.removingPercentEncoding ?? targetURL.path
        return hexID(in: path.isEmpty ? "/" : path)
    }

    /// Collection view id from `?v=` / `?viewId=`.
    public static func viewID(from targetURL: URL) -> String? {
        for key in ["v", "viewId", "view_id"] {
            if let value = queryValue(targetURL, key), let id = hexID(in: value) {
                return id
            }
        }
        return nil
    }

    public static func formatPageID(_ rawID: String) -> String {
        let raw = rawID.lowercased()
        precondition(raw.count == 32)
        let characters = Array(raw)
        return """
        \(String(characters[0..<8]))-\
        \(String(characters[8..<12]))-\
        \(String(characters[12..<16]))-\
        \(String(characters[16..<20]))-\
        \(String(characters[20..<32]))
        """
    }

    public static func parse(_ urlString: String) throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw NotionSiteFetchError.invalidURL(urlString)
        }
        return url
    }

    static func hexID(in text: String) -> String? {
        let hexOnly = text.filter(\.isHexDigit).lowercased()
        guard hexOnly.count >= 32 else { return nil }
        let rawID = String(hexOnly.suffix(32))
        guard rawID.allSatisfy(\.isHexDigit), rawID.count == 32 else { return nil }
        return formatPageID(rawID)
    }

    private static func pathComponents(of url: URL) -> [String] {
        let path = url.path.removingPercentEncoding ?? url.path
        return path.split(separator: "/").map(String.init)
    }

    private static func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private static func isSpaceDomain(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return !value.isEmpty
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
            && value != "-"
    }
}

enum PageResolver {
    static func resolvePageAndSpace(
        targetURL: URL,
        client: any NotionHTTPClient,
        sleeper: any Sleeper,
        apiBase: String,
        maxRetries: Int,
        maxBackoffSeconds: Double
    ) async throws -> (pageID: String, spaceID: String?) {
        if let pageID = NotionPageURL.pageID(from: targetURL) {
            return (pageID, nil)
        }

        let hostname = (targetURL.host ?? "").lowercased()
        guard hostname.hasSuffix(".notion.site") else {
            throw NotionSiteFetchError.cannotResolvePageID(targetURL.absoluteString)
        }

        let spaceSubdomain = hostname.split(separator: ".").first.map(String.init) ?? hostname
        guard let publicPageURL = URL(string: "\(apiBase)/getPublicPageData") else {
            throw NotionSiteFetchError.invalidURL("\(apiBase)/getPublicPageData")
        }
        let spaceLookup = try await NotionAPI.postJSON(
            client: client,
            sleeper: sleeper,
            url: publicPageURL,
            body: ["spaceDomain": .string(spaceSubdomain)],
            maxRetries: maxRetries,
            maxBackoffSeconds: maxBackoffSeconds
        )
        guard let spaceID = spaceLookup["spaceId"].string else {
            throw NotionSiteFetchError.missingPublicHomePage(spaceSubdomain)
        }

        guard let spaceDataURL = URL(string: "\(apiBase)/getPublicSpaceData") else {
            throw NotionSiteFetchError.invalidURL("\(apiBase)/getPublicSpaceData")
        }
        let spaceDetails = try await NotionAPI.postJSON(
            client: client,
            sleeper: sleeper,
            url: spaceDataURL,
            body: [
                "type": "space-ids",
                "spaceIds": .array([.string(spaceID)]),
            ],
            maxRetries: maxRetries,
            maxBackoffSeconds: maxBackoffSeconds
        )
        let results = spaceDetails["results"].array
        let publicHomePage = results.first?["publicHomePage"].string
        guard let publicHomePage, !publicHomePage.isEmpty else {
            throw NotionSiteFetchError.missingPublicHomePage(spaceSubdomain)
        }
        return (publicHomePage, spaceID)
    }
}
