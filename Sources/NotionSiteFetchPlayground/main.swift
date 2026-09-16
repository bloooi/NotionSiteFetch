import Foundation
import NotionSiteFetch

#if canImport(FoundationNetworking)
@preconcurrency import FoundationNetworking
#endif

@main
struct PlaygroundServer {
    static func main() async {
        let port = UInt16(ProcessInfo.processInfo.environment["PORT"] ?? "") ?? 43147
        let host = ProcessInfo.processInfo.environment["HOST"] ?? "0.0.0.0"

        do {
            let server = try MiniHTTPServer(host: host, port: port)
            FileHandle.standardError.write(
                Data("NotionSiteFetch playground listening on http://127.0.0.1:\(port)\n".utf8)
            )
            try await server.serve { request in
                await PlaygroundRouter.handle(request)
            }
        } catch {
            FileHandle.standardError.write(Data("playground failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

enum PlaygroundRouter {
    static func handle(_ request: MiniHTTPServer.Request) async -> MiniHTTPServer.Response {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .html(PlaygroundHTML.load())
        case ("GET", "/health"):
            return .json(["ok": true, "service": "notion-site-fetch-playground"])
        case ("POST", "/api/fetch"):
            return await fetch(request)
        default:
            return .json(["error": "Not found"], status: 404)
        }
    }

    private static func fetch(_ request: MiniHTTPServer.Request) async -> MiniHTTPServer.Response {
        let payload: JSONValue
        do {
            payload = try JSONValue.parse(data: request.body)
        } catch {
            return .json(["error": "JSON 본문을 읽을 수 없습니다."], status: 400)
        }

        guard let urlString = payload["url"].string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty else {
            return .json(["error": "url 필드가 필요합니다."], status: 400)
        }

        let parsedURL: URL
        do {
            parsedURL = try NotionPageURL.parse(urlString)
        } catch {
            return .json(["error": "올바른 http(s) URL이 아닙니다."], status: 400)
        }

        let started = Date()
        do {
            let page = try await NotionSiteFetcher().fetchPage(from: parsedURL)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            let collectionRowCount = page.collectionRowIDs.values.reduce(0) { $0 + $1.count }
            var body: [String: JSONValue] = [
                "markdown": .string(page.markdown),
                "rootPageID": .string(page.rootPageID),
                "spaceID": page.spaceID.map { .string($0) } ?? .null,
                "blockCount": .number(Double(page.blocks.count)),
                "collectionCount": .number(Double(page.collections.count)),
                "collectionViewCount": .number(Double(page.collectionViews.count)),
                "collectionRowCount": .number(Double(collectionRowCount)),
                "elapsedMs": .number(Double(elapsedMs)),
            ]
            if let viewID = NotionPageURL.viewID(from: parsedURL) {
                body["viewID"] = .string(viewID)
            }
            return .json(body)
        } catch {
            return .json(
                [
                    "error": .string(String(describing: error)),
                    "elapsedMs": .number(Double(Int(Date().timeIntervalSince(started) * 1000))),
                ],
                status: 502
            )
        }
    }
}

enum PlaygroundHTML {
    static func load() -> String {
        if let url = Bundle.module.url(forResource: "index", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            return html
        }
        return """
        <!doctype html><html lang="ko"><body>
        <p>Playground HTML 리소스를 찾지 못했습니다. 패키지 리소스 번들을 확인하세요.</p>
        </body></html>
        """
    }
}
