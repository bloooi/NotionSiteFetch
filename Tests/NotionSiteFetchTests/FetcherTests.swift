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

    func testQueriesCollectionViewRows() async throws {
        let client = ScriptedHTTPClient([
            ScriptedCall(
                urlSuffix: "loadCachedPageChunkV2",
                statusCode: 200,
                body: Fixtures.chunk(
                    blocks: [
                        Fixtures.rootID: Fixtures.blockRecord([
                            "type": "page",
                            "properties": ["title": [["Public Page"]]],
                            "content": [.string(Fixtures.collectionViewBlockID)],
                            "space_id": .string(Fixtures.spaceID),
                        ]),
                        Fixtures.collectionViewBlockID: Fixtures.blockRecord([
                            "type": "collection_view",
                            "properties": ["title": [["Tasks"]]],
                            "collection_id": .string(Fixtures.collectionID),
                            "view_ids": [.string(Fixtures.collectionViewID)],
                            "space_id": .string(Fixtures.spaceID),
                        ]),
                    ],
                    collections: [
                        Fixtures.collectionID: Fixtures.collectionRecord([
                            "name": [["Tasks"]],
                            "schema": [
                                "title": ["name": "Name", "type": "title"],
                                "stat": ["name": "Status", "type": "select"],
                            ],
                        ]),
                    ],
                    collectionViews: [
                        Fixtures.collectionViewID: Fixtures.collectionRecord([
                            "type": "table",
                            "format": [
                                "table_properties": [
                                    ["property": "title", "visible": true],
                                    ["property": "stat", "visible": true],
                                ],
                            ],
                        ]),
                    ]
                )
            ),
            ScriptedCall(
                urlSuffix: "queryCollection",
                statusCode: 200,
                body: [
                    "result": [
                        "reducerResults": [
                            "collection_group_results": [
                                "type": "results",
                                "blockIds": [
                                    .string(Fixtures.collectionRow1ID),
                                    .string(Fixtures.collectionRow2ID),
                                ],
                                "hasMore": false,
                            ],
                        ],
                    ],
                    "recordMap": [
                        "block": [
                            Fixtures.collectionRow1ID: Fixtures.blockRecord([
                                "type": "page",
                                "properties": [
                                    "title": [["Alpha"]],
                                    "stat": [["Done"]],
                                ],
                            ]),
                            Fixtures.collectionRow2ID: Fixtures.blockRecord([
                                "type": "page",
                                "properties": [
                                    "title": [["Beta"]],
                                    "stat": [["Todo"]],
                                ],
                            ]),
                        ],
                    ],
                ]
            ),
        ])

        let fetcher = NotionSiteFetcher(client: client, sleeper: ImmediateSleeper())
        let page = try await fetcher.fetchPage(
            from: "https://app.notion.com/p/docs/11111111111111111111111111111111?v=\(Fixtures.collectionViewID.replacingOccurrences(of: "-", with: ""))"
        )

        XCTAssertEqual(
            page.markdown,
            """
            # Public Page

            Tasks

            | Name | Status |
            | --- | --- |
            | Alpha | Done |
            | Beta | Todo |

            """
        )
        XCTAssertEqual(page.collectionRowIDs[Fixtures.collectionViewBlockID], [
            Fixtures.collectionRow1ID,
            Fixtures.collectionRow2ID,
        ])
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(
            client.requests[1].body["collection"]["id"].string,
            Fixtures.collectionID
        )
        XCTAssertEqual(
            client.requests[1].body["collectionView"]["id"].string,
            Fixtures.collectionViewID
        )
        XCTAssertEqual(
            client.requests[1].body["loader"]["reducers"]["collection_group_results"]["limit"].int,
            200
        )
        XCTAssertTrue(client.requests[0].url.contains("docs.notion.site"))
        XCTAssertTrue(client.requests[1].url.contains("docs.notion.site"))
    }

    func testIgnoresCollectionViewOutsidePageTree() async throws {
        let client = ScriptedHTTPClient([
            ScriptedCall(
                urlSuffix: "loadCachedPageChunkV2",
                statusCode: 200,
                body: Fixtures.chunk(blocks: [
                    Fixtures.rootID: Fixtures.blockRecord([
                        "type": "page",
                        "properties": ["title": [["Row page"]]],
                        "content": [.string(Fixtures.childID)],
                        "space_id": .string(Fixtures.spaceID),
                    ]),
                    Fixtures.childID: Fixtures.blockRecord([
                        "type": "text",
                        "properties": ["title": [["Just text"]]],
                    ]),
                    Fixtures.collectionViewBlockID: Fixtures.blockRecord([
                        "type": "collection_view",
                        "properties": ["title": [["Parent database"]]],
                        "collection_id": .string(Fixtures.collectionID),
                        "view_ids": [.string(Fixtures.collectionViewID)],
                    ]),
                ])
            ),
        ])

        let fetcher = NotionSiteFetcher(client: client, sleeper: ImmediateSleeper())
        let page = try await fetcher.fetchPage(
            from: "https://www.notion.so/11111111111111111111111111111111"
        )
        XCTAssertEqual(page.markdown, "# Row page\n\nJust text\n")
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertTrue(page.collectionRowIDs.isEmpty)
    }

    func testKeepsPageWhenCollectionQueryFails() async throws {
        let client = ScriptedHTTPClient([
            ScriptedCall(
                urlSuffix: "loadCachedPageChunkV2",
                statusCode: 200,
                body: Fixtures.chunk(blocks: [
                    Fixtures.rootID: Fixtures.blockRecord([
                        "type": "page",
                        "properties": ["title": [["Visible"]]],
                        "content": [.string(Fixtures.collectionViewBlockID)],
                        "space_id": .string(Fixtures.spaceID),
                    ]),
                    Fixtures.collectionViewBlockID: Fixtures.blockRecord([
                        "type": "collection_view",
                        "properties": ["title": [["Hidden rows"]]],
                        "collection_id": .string(Fixtures.collectionID),
                        "view_ids": [.string(Fixtures.collectionViewID)],
                    ]),
                ])
            ),
            ScriptedCall(urlSuffix: "queryCollection", statusCode: 400, body: "private"),
            ScriptedCall(urlSuffix: "queryCollection", statusCode: 400, body: "private"),
            ScriptedCall(urlSuffix: "queryCollection", statusCode: 400, body: "private"),
            ScriptedCall(urlSuffix: "queryCollection", statusCode: 400, body: "private"),
            ScriptedCall(urlSuffix: "queryCollection", statusCode: 400, body: "private"),
            ScriptedCall(urlSuffix: "queryCollection", statusCode: 400, body: "private"),
        ])

        let fetcher = NotionSiteFetcher(client: client, sleeper: ImmediateSleeper())
        let page = try await fetcher.fetchPage(
            from: "https://www.notion.so/11111111111111111111111111111111"
        )
        XCTAssertEqual(page.markdown, "# Visible\n\nHidden rows\n")
        XCTAssertNil(page.collectionRowIDs[Fixtures.collectionViewBlockID])
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

    func testLivePublicDatabaseIfEnabled() async throws {
        let enabled = ProcessInfo.processInfo.environment["NOTION_SITE_FETCH_LIVE"] == "1"
        try XCTSkipUnless(enabled, "Set NOTION_SITE_FETCH_LIVE=1 to run the live fetch.")
        let url = ProcessInfo.processInfo.environment["NOTION_SITE_FETCH_LIVE_DB_URL"]
            ?? "https://canvas-os.notion.site/122f88b8e7ce810683e0f21ccf1b61e9"
        let page = try await NotionSiteFetcher().fetchPage(from: url)
        XCTAssertFalse(page.collectionRowIDs.isEmpty, "expected queryCollection to return database rows")
        XCTAssertTrue(
            page.markdown.contains("|"),
            "expected a markdown table of database rows, got:\n\(page.markdown)"
        )
    }
}
