import Foundation
#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

public struct NotionHTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data
    public var timeout: TimeInterval?

    public init(
        url: URL,
        method: String = "POST",
        headers: [String: String] = [:],
        body: Data,
        timeout: TimeInterval? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct NotionHTTPResponse: Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    public var bodyPreview: String {
        let text = String(data: body, encoding: .utf8) ?? ""
        if text.count <= 200 {
            return text
        }
        return String(text.prefix(200))
    }
}

public protocol NotionHTTPClient: Sendable {
    func send(_ request: NotionHTTPRequest) async throws -> NotionHTTPResponse
}

public protocol Sleeper: Sendable {
    func sleep(seconds: Double) async
}

public struct TaskSleeper: Sleeper {
    public init() {}

    public func sleep(seconds: Double) async {
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

public struct ImmediateSleeper: Sleeper {
    public init() {}

    public func sleep(seconds: Double) async {}
}

public struct URLSessionHTTPClient: NotionHTTPClient, Sendable {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: NotionHTTPRequest) async throws -> NotionHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        if let timeout = request.timeout {
            urlRequest.timeoutInterval = timeout
        }
        for (header, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: header)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return NotionHTTPResponse(statusCode: status, body: data)
        } catch {
            throw NotionSiteFetchError.transport(error.localizedDescription)
        }
    }
}

enum NotionAPI {
    static let defaultHeaders: [String: String] = [
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": "Mozilla/5.0 (notion-reader)",
    ]

    static let maxRetries = 8
    static let maxBackoffSeconds = 10.0

    static func postJSON(
        client: any NotionHTTPClient,
        sleeper: any Sleeper,
        url: URL,
        body: JSONValue,
        maxRetries: Int,
        maxBackoffSeconds: Double,
        timeout: TimeInterval? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> JSONValue {
        var lastError: NotionSiteFetchError?

        for attemptIndex in 0..<maxRetries {
            do {
                var headers = defaultHeaders
                for (header, value) in extraHeaders {
                    headers[header] = value
                }
                let request = NotionHTTPRequest(
                    url: url,
                    headers: headers,
                    body: try body.encodedData(),
                    timeout: timeout
                )
                let response = try await client.send(request)

                if response.statusCode >= 500 {
                    lastError = .httpStatus(
                        code: response.statusCode,
                        url: url.absoluteString,
                        bodyPreview: response.bodyPreview
                    )
                } else if (200..<300).contains(response.statusCode) {
                    return try JSONValue.parse(data: response.body)
                } else if response.statusCode == 429 {
                    lastError = .httpStatus(
                        code: response.statusCode,
                        url: url.absoluteString,
                        bodyPreview: response.bodyPreview
                    )
                    // Rate limits get worse if we keep hammering the same cell.
                    if attemptIndex >= 1 {
                        break
                    }
                } else {
                    lastError = .httpStatus(
                        code: response.statusCode,
                        url: url.absoluteString,
                        bodyPreview: response.bodyPreview
                    )
                }
            } catch let error as NotionSiteFetchError {
                lastError = error
            } catch {
                lastError = .transport(error.localizedDescription)
            }

            if attemptIndex < maxRetries - 1 {
                let delay = min(2.0 * Double(attemptIndex + 1), maxBackoffSeconds)
                await sleeper.sleep(seconds: delay)
            }
        }

        throw lastError ?? .retriesExhausted("Request to \(url.absoluteString) failed")
    }
}
