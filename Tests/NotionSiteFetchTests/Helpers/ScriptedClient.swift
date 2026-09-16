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
    static let collectionViewBlockID = "44444444-4444-4444-4444-444444444444"
    static let collectionID = "55555555-5555-5555-5555-555555555555"
    static let collectionViewID = "66666666-6666-6666-6666-666666666666"
    static let collectionRow1ID = "77777777-7777-7777-7777-777777777777"
    static let collectionRow2ID = "88888888-8888-8888-8888-888888888888"

    static func blockRecord(_ value: JSONValue, spaceID: String? = nil) -> JSONValue {
        var record: [String: JSONValue] = [
            "value": ["value": value],
        ]
        if let spaceID {
            record["spaceId"] = .string(spaceID)
        }
        return .object(record)
    }

    static func chunk(
        blocks: [String: JSONValue],
        collections: [String: JSONValue] = [:],
        collectionViews: [String: JSONValue] = [:],
        cursorStack: [JSONValue] = []
    ) -> JSONValue {
        var recordMap: [String: JSONValue] = [
            "block": .object(blocks),
        ]
        if !collections.isEmpty {
            recordMap["collection"] = .object(collections)
        }
        if !collectionViews.isEmpty {
            recordMap["collection_view"] = .object(collectionViews)
        }
        return [
            "recordMap": .object(recordMap),
            "cursors": .array([
                ["stack": .array(cursorStack)],
            ]),
        ]
    }

    static func collectionRecord(_ value: JSONValue) -> JSONValue {
        ["value": ["value": value]]
    }
}
