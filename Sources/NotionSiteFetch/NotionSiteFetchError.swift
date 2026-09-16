import Foundation

public enum NotionSiteFetchError: Error, Sendable, Equatable {
    case invalidURL(String)
    case cannotResolvePageID(String)
    case missingPublicHomePage(String)
    case rootPageMissing(String)
    case httpStatus(code: Int, url: String, bodyPreview: String)
    case transport(String)
    case invalidJSON(String)
    case retriesExhausted(String)
}

extension NotionSiteFetchError: LocalizedError, CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidURL(let value):
            return "Invalid URL: \(value)"
        case .cannotResolvePageID(let url):
            return "Cannot resolve page id from URL: '\(url)'. Expected a *.notion.site host or a URL ending in a 32-char page id."
        case .missingPublicHomePage(let space):
            return "Space '\(space)' has no public home page set."
        case .rootPageMissing(let pageID):
            return "root page \(pageID) not found in response"
        case .httpStatus(let code, let url, let bodyPreview):
            return "\(code) from \(url): \(bodyPreview)"
        case .transport(let message):
            return message
        case .invalidJSON(let message):
            return message
        case .retriesExhausted(let message):
            return message
        }
    }

    public var errorDescription: String? { description }
}
