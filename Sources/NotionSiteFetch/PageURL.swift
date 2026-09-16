import Foundation

public enum NotionPageURL: Sendable {
    /// Chooses the public API host. `*.notion.site` stays on that subdomain
    /// so requests hit the right Notion cell.
    public static func apiBase(for targetURL: URL) -> String {
        let hostname = (targetURL.host ?? "").lowercased()
        if hostname.hasSuffix(".notion.site") {
            return "https://\(hostname)/api/v3"
        }
        return "https://www.notion.so/api/v3"
    }

    /// Last 32 hex characters in the path, formatted as a Notion UUID.
    public static func pageID(fromPath path: String) -> String? {
        let hexOnly = path.filter(\.isHexDigit)
        guard hexOnly.count >= 32 else { return nil }
        let rawID = String(hexOnly.suffix(32)).lowercased()
        guard rawID.allSatisfy(\.isHexDigit), rawID.count == 32 else { return nil }
        return formatPageID(rawID)
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
        let hostname = targetURL.host ?? ""
        let path = targetURL.path.removingPercentEncoding ?? targetURL.path

        if let pageID = NotionPageURL.pageID(fromPath: path.isEmpty ? "/" : path) {
            return (pageID, nil)
        }

        guard hostname.lowercased().hasSuffix(".notion.site") else {
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
