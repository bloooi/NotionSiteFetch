import Foundation
import NotionSiteFetch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

final class MiniHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data

        static func html(_ html: String, status: Int = 200) -> Response {
            Response(
                status: status,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: Data(html.utf8)
            )
        }

        static func json(_ value: JSONValue, status: Int = 200) -> Response {
            let data = (try? value.encodedData(prettyPrinted: true)) ?? Data("{}".utf8)
            return Response(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: data
            )
        }

        static func json(_ object: [String: JSONValue], status: Int = 200) -> Response {
            .json(.object(object), status: status)
        }
    }

    private let socketFD: Int32
    private let port: UInt16

    init(host: String, port: UInt16) throws {
        self.port = port
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else {
            throw NotionSiteFetchError.transport("socket() failed")
        }
        self.socketFD = fd

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = try Self.inAddress(from: host)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw NotionSiteFetchError.transport("bind() failed on port \(port)")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw NotionSiteFetchError.transport("listen() failed")
        }
    }

    deinit {
        close(socketFD)
    }

    func serve(_ handler: @escaping @Sendable (Request) async -> Response) async throws {
        while !Task.isCancelled {
            let clientFD = accept(socketFD, nil, nil)
            if clientFD < 0 {
                continue
            }
            Task {
                defer { close(clientFD) }
                do {
                    let request = try Self.readRequest(from: clientFD)
                    let response = await handler(request)
                    try Self.write(response, to: clientFD)
                } catch {
                    let fallback = Response.json(["error": "Bad request"], status: 400)
                    try? Self.write(fallback, to: clientFD)
                }
            }
        }
    }

    private static func inAddress(from host: String) throws -> in_addr {
        var address = in_addr()
        if host == "0.0.0.0" {
            address.s_addr = INADDR_ANY
            return address
        }
        if host == "127.0.0.1" {
            address.s_addr = inet_addr("127.0.0.1")
            return address
        }
        guard inet_pton(AF_INET, host, &address) == 1 else {
            throw NotionSiteFetchError.transport("Unsupported bind host: \(host)")
        }
        return address
    }

    private static func readRequest(from fd: Int32) throws -> Request {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Range<Data.Index>?

        while headerEnd == nil {
            let received = recv(fd, &chunk, chunk.count, 0)
            if received <= 0 {
                throw NotionSiteFetchError.transport("client closed before headers")
            }
            buffer.append(contentsOf: chunk.prefix(received))
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range
            }
            if buffer.count > 1_048_576 {
                throw NotionSiteFetchError.transport("request headers too large")
            }
        }

        let headerData = buffer[..<headerEnd!.lowerBound]
        var body = Data(buffer[headerEnd!.upperBound...])
        let headerText = String(data: headerData, encoding: .utf8) ?? ""
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            throw NotionSiteFetchError.transport("empty request")
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            throw NotionSiteFetchError.transport("malformed request line")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        while body.count < contentLength {
            let received = recv(fd, &chunk, chunk.count, 0)
            if received <= 0 {
                break
            }
            body.append(contentsOf: chunk.prefix(received))
            if body.count > 2_000_000 {
                throw NotionSiteFetchError.transport("request body too large")
            }
        }
        if body.count > contentLength {
            body = body.prefix(contentLength)
        }

        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        return Request(method: String(parts[0]), path: path, headers: headers, body: body)
    }

    private static func write(_ response: Response, to fd: Int32) throws {
        let reason = statusReason(response.status)
        var headerLines = [
            "HTTP/1.1 \(response.status) \(reason)",
            "Content-Length: \(response.body.count)",
            "Connection: close",
        ]
        for (name, value) in response.headers {
            headerLines.append("\(name): \(value)")
        }
        var payload = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        payload.append(response.body)
        payload.withUnsafeBytes { raw in
            var written = 0
            let bytes = raw.bindMemory(to: UInt8.self)
            while written < bytes.count {
                let result = send(fd, bytes.baseAddress! + written, bytes.count - written, 0)
                if result <= 0 {
                    break
                }
                written += result
            }
        }
    }

    private static func statusReason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 502: return "Bad Gateway"
        default: return "OK"
        }
    }
}
