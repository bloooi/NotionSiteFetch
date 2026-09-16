import Foundation
@testable import NotionSiteFetch

struct ScriptedCall: Sendable {
    var urlSuffix: String
    var statusCode: Int
    var body: JSONValue
}

final class ScriptedHTTPClient: NotionHTTPClient, @unchecked Sendable {
    private var scripts: [ScriptedCall]
    private(set) var requests: [(url: String, body: JSONValue)] = []

    init(_ scripts: [ScriptedCall]) {
        self.scripts = scripts
    }

    func send(_ request: NotionHTTPRequest) async throws -> NotionHTTPResponse {
        let body = try JSONValue.parse(data: request.body)
        requests.append((request.url.absoluteString, body))
        guard !scripts.isEmpty else {
            throw NotionSiteFetchError.transport("No more scripted responses for \(request.url)")
        }
        let next = scripts.removeFirst()
        if !request.url.absoluteString.contains(next.urlSuffix) {
            throw NotionSiteFetchError.transport(
                "Expected call to \(next.urlSuffix) but got \(request.url.absoluteString)"
            )
        }
        return NotionHTTPResponse(statusCode: next.statusCode, body: try next.body.encodedData())
    }
}

final class RecordingSleeper: Sleeper, @unchecked Sendable {
    private(set) var delays: [Double] = []

    func sleep(seconds: Double) async {
        delays.append(seconds)
    }
}

enum Fixtures {
    static let rootID = "11111111-1111-1111-1111-111111111111"
    static let childID = "22222222-2222-2222-2222-222222222222"
    static let toggleChildID = "33333333-3333-3333-3333-333333333333"
    static let spaceID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

    static func blockRecord(_ value: JSONValue, spaceID: String? = nil) -> JSONValue {
        var record: [String: JSONValue] = [
            "value": ["value": value],
        ]
        if let spaceID {
            record["spaceId"] = .string(spaceID)
        }
        return .object(record)
    }

    static func chunk(blocks: [String: JSONValue], cursorStack: [JSONValue] = []) -> JSONValue {
        [
            "recordMap": [
                "block": .object(blocks),
            ],
            "cursors": .array([
                ["stack": .array(cursorStack)],
            ]),
        ]
    }
}
