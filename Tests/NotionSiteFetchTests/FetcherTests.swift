import XCTest
@testable import NotionSiteFetch

final class FetcherTests: XCTestCase {
    func testFetchesPageIDURLAndRendersMarkdown() async throws {
        let client = ScriptedHTTPClient([
            ScriptedCall(
                urlSuffix: "www.notion.so/api/v3/loadCachedPageChunkV2",
                statusCode: 200,
                body: Fixtures.chunk(blocks: [
                    Fixtures.rootID: Fixtures.blockRecord(
                        [
                            "type": "page",
                            "properties": ["title": [["Public Page"]]],
                            "content": [.string(Fixtures.childID)],
                            "space_id": .string(Fixtures.spaceID),
                        ],
                        spaceID: Fixtures.spaceID
                    ),
                    Fixtures.childID: Fixtures.blockRecord([
                        "type": "text",
                        "properties": ["title": [["Body"]]],
                    ]),
                ])
            ),
        ])

        let fetcher = NotionSiteFetcher(client: client, sleeper: ImmediateSleeper())
        let page = try await fetcher.fetchPage(
            from: "https://www.notion.so/team/Public-11111111111111111111111111111111"
        )

        XCTAssertEqual(page.rootPageID, Fixtures.rootID)
        XCTAssertEqual(page.spaceID, Fixtures.spaceID)
        XCTAssertEqual(page.markdown, "# Public Page\n\nBody\n")
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].body["page"]["id"].string, Fixtures.rootID)
    }

    func testResolvesSiteRootWithoutPageID() async throws {
        let client = ScriptedHTTPClient([
            ScriptedCall(
                urlSuffix: "docs.notion.site/api/v3/getPublicPageData",
                statusCode: 200,
                body: ["spaceId": .string(Fixtures.spaceID)]
            ),
            ScriptedCall(
                urlSuffix: "docs.notion.site/api/v3/getPublicSpaceData",
                statusCode: 200,
                body: [
                    "results": [[
                        "publicHomePage": .string(Fixtures.rootID),
                    ]],
                ]
            ),
            ScriptedCall(
                urlSuffix: "docs.notion.site/api/v3/loadCachedPageChunkV2",
                statusCode: 200,
                body: Fixtures.chunk(blocks: [
                    Fixtures.rootID: Fixtures.blockRecord([
                        "type": "page",
                        "properties": ["title": [["Home"]]],
                    ]),
                ])
            ),
        ])

        let fetcher = NotionSiteFetcher(client: client, sleeper: ImmediateSleeper())
        let markdown = try await fetcher.fetchMarkdown(from: "https://docs.notion.site/")
        XCTAssertEqual(markdown, "# Home\n")
        XCTAssertEqual(client.requests[0].body["spaceDomain"].string, "docs")
    }

    func testPaginatesChunksAndLoadsToggleChildren() async throws {
        let client = ScriptedHTTPClient([
            ScriptedCall(
                urlSuffix: "loadCachedPageChunkV2",
                statusCode: 200,
                body: Fixtures.chunk(
                    blocks: [
                        Fixtures.rootID: Fixtures.blockRecord([
                            "type": "page",
                            "properties": ["title": [["Toggles"]]],
                            "content": [.string(Fixtures.childID)],
                            "space_id": .string(Fixtures.spaceID),
                        ]),
                    ],
                    cursorStack: [["token": "more"]]
                )
            ),
            ScriptedCall(
                urlSuffix: "loadCachedPageChunkV2",
                statusCode: 200,
                body: Fixtures.chunk(blocks: [
                    Fixtures.childID: Fixtures.blockRecord([
                        "type": "toggle",
                        "properties": ["title": [["Open me"]]],
                        "content": [.string(Fixtures.toggleChildID)],
                    ]),
                ])
            ),
            ScriptedCall(
                urlSuffix: "www.notion.so/api/v3/syncRecordValues",
                statusCode: 200,
                body: [
                    "recordMap": [
                        "block": [
                            Fixtures.toggleChildID: Fixtures.blockRecord([
                                "type": "text",
                                "properties": ["title": [["Hidden"]]],
                            ]),
                        ],
                    ],
                ]
            ),
        ])

        let fetcher = NotionSiteFetcher(client: client, sleeper: ImmediateSleeper())
        let page = try await fetcher.fetchPage(
            from: "https://www.notion.so/11111111111111111111111111111111"
        )
        XCTAssertEqual(page.markdown, "# Toggles\n\n- Open me\n    Hidden\n")
        XCTAssertEqual(client.requests.count, 3)
        XCTAssertEqual(client.requests[1].body["chunkNumber"].int, 1)
        XCTAssertEqual(
            client.requests[2].body["requests"][0]["pointer"]["id"].string,
            Fixtures.toggleChildID
        )
    }

    func testKeepsChunkedPageWhenLazySyncIsRateLimited() async throws {
        let client = ScriptedHTTPClient([
            ScriptedCall(
                urlSuffix: "loadCachedPageChunkV2",
                statusCode: 200,
                body: Fixtures.chunk(blocks: [
                    Fixtures.rootID: Fixtures.blockRecord([
                        "type": "page",
                        "properties": ["title": [["Visible"]]],
                        "content": [.string(Fixtures.childID)],
                        "space_id": .string(Fixtures.spaceID),
                    ]),
                    Fixtures.childID: Fixtures.blockRecord([
                        "type": "toggle",
                        "properties": ["title": [["Open me"]]],
                        "content": [.string(Fixtures.toggleChildID)],
                    ]),
                ])
            ),
            ScriptedCall(
                urlSuffix: "syncRecordValues",
                statusCode: 429,
                body: "rate limited"
            ),
            ScriptedCall(
                urlSuffix: "syncRecordValues",
                statusCode: 429,
                body: "rate limited"
            ),
            ScriptedCall(
                urlSuffix: "syncRecordValues",
                statusCode: 429,
                body: "rate limited"
            ),
        ])

        let fetcher = NotionSiteFetcher(client: client, sleeper: ImmediateSleeper())
        let page = try await fetcher.fetchPage(
            from: "https://www.notion.so/11111111111111111111111111111111"
        )
        XCTAssertEqual(page.markdown, "# Visible\n\n- Open me\n")
        XCTAssertNil(page.blocks[Fixtures.toggleChildID])
    }

    func testRetriesServerErrorsWithBackoff() async throws {
        let sleeper = RecordingSleeper()
        let client = ScriptedHTTPClient([
            ScriptedCall(urlSuffix: "loadCachedPageChunkV2", statusCode: 502, body: "MemcachedCrossCellError"),
            ScriptedCall(urlSuffix: "loadCachedPageChunkV2", statusCode: 502, body: "still down"),
            ScriptedCall(
                urlSuffix: "loadCachedPageChunkV2",
                statusCode: 200,
                body: Fixtures.chunk(blocks: [
                    Fixtures.rootID: Fixtures.blockRecord([
                        "type": "page",
                        "properties": ["title": [["Recovered"]]],
                    ]),
                ])
            ),
        ])

        let fetcher = NotionSiteFetcher(
            client: client,
            sleeper: sleeper,
            configuration: .init(maxRetries: 8, maxBackoffSeconds: 10, requestTimeout: 5)
        )
        let markdown = try await fetcher.fetchMarkdown(
            from: "https://www.notion.so/11111111111111111111111111111111"
        )
        XCTAssertEqual(markdown, "# Recovered\n")
        XCTAssertEqual(sleeper.delays, [2.0, 4.0])
    }

    func testMissingPublicHomePage() async throws {
        let client = ScriptedHTTPClient([
            ScriptedCall(
                urlSuffix: "getPublicPageData",
                statusCode: 200,
                body: ["spaceId": .string(Fixtures.spaceID)]
            ),
            ScriptedCall(
                urlSuffix: "getPublicSpaceData",
                statusCode: 200,
                body: ["results": []]
            ),
        ])
        let fetcher = NotionSiteFetcher(client: client, sleeper: ImmediateSleeper())
        do {
            _ = try await fetcher.fetchMarkdown(from: "https://empty.notion.site/")
            XCTFail("expected missing public home page")
        } catch let error as NotionSiteFetchError {
            XCTAssertEqual(error, .missingPublicHomePage("empty"))
        }
    }

    func testCannotResolvePageID() async {
        let fetcher = NotionSiteFetcher(client: ScriptedHTTPClient([]), sleeper: ImmediateSleeper())
        do {
            _ = try await fetcher.fetchMarkdown(from: "https://example.com/nope")
            XCTFail("expected resolve failure")
        } catch let error as NotionSiteFetchError {
            guard case .cannotResolvePageID = error else {
                return XCTFail("unexpected \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRootPageMissing() async {
        let client = ScriptedHTTPClient([
            ScriptedCall(
                urlSuffix: "loadCachedPageChunkV2",
                statusCode: 200,
                body: Fixtures.chunk(blocks: [:])
            ),
        ])
        let fetcher = NotionSiteFetcher(client: client, sleeper: ImmediateSleeper())
        do {
            _ = try await fetcher.fetchMarkdown(
                from: "https://www.notion.so/11111111111111111111111111111111"
            )
            XCTFail("expected missing root")
        } catch let error as NotionSiteFetchError {
            XCTAssertEqual(error, .rootPageMissing(Fixtures.rootID))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

final class LiveFetchTests: XCTestCase {
    func testLivePublicPageIfEnabled() async throws {
        let enabled = ProcessInfo.processInfo.environment["NOTION_SITE_FETCH_LIVE"] == "1"
        try XCTSkipUnless(enabled, "Set NOTION_SITE_FETCH_LIVE=1 to run the live fetch.")
        let url = ProcessInfo.processInfo.environment["NOTION_SITE_FETCH_LIVE_URL"]
            ?? "https://sota1235.notion.site/Example-page-for-notion-sdk-js-helper-4176d72d760c40979a6a6523fa2c1165"
        let page = try await NotionSiteFetcher().fetchPage(from: url)
        XCTAssertFalse(page.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(page.blocks.isEmpty)
    }
}
