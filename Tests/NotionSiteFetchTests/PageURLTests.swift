import XCTest
@testable import NotionSiteFetch

final class PageURLTests: XCTestCase {
    func testAPIBaseUsesNotionSiteHost() throws {
        let url = try NotionPageURL.parse("https://Docs.Notion.Site/hello")
        XCTAssertEqual(NotionPageURL.apiBase(for: url), "https://docs.notion.site/api/v3")
    }

    func testAPIBaseFallsBackToWWW() throws {
        let url = try NotionPageURL.parse("https://www.notion.so/workspace/Page-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(NotionPageURL.apiBase(for: url), "https://www.notion.so/api/v3")
    }

    func testPageIDFromSlugPath() {
        let pageID = NotionPageURL.pageID(
            fromPath: "/What-s-New-157765353f2c4705bd45474e5ba8b46c"
        )
        XCTAssertEqual(pageID, "15776535-3f2c-4705-bd45-474e5ba8b46c")
    }

    func testPageIDIgnoresNonHexAndUsesLast32() {
        let pageID = NotionPageURL.pageID(fromPath: "/hello-11111111222233334444555566667777")
        XCTAssertEqual(pageID, "11111111-2222-3333-4444-555566667777")
    }

    func testAppNotionPublishedPathUsesSpaceSiteAPI() throws {
        let url = try NotionPageURL.parse(
            "https://app.notion.com/p/cafe123abc/11111111222233334444555566667777?v=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        XCTAssertEqual(
            NotionPageURL.apiBase(for: url),
            "https://cafe123abc.notion.site/api/v3"
        )
        XCTAssertEqual(NotionPageURL.spaceDomain(from: url), "cafe123abc")
        XCTAssertEqual(
            NotionPageURL.pageID(from: url),
            "11111111-2222-3333-4444-555566667777"
        )
        XCTAssertEqual(
            NotionPageURL.viewID(from: url),
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        )
    }

    func testPageIDIgnoresHexDigitsInWorkspaceSlug() throws {
        let url = try NotionPageURL.parse(
            "https://app.notion.com/p/cafe123abc/11111111222233334444555566667777"
        )
        XCTAssertEqual(
            NotionPageURL.pageID(from: url),
            "11111111-2222-3333-4444-555566667777"
        )
    }

    func testParseRejectsSchemelessText() {
        XCTAssertThrowsError(try NotionPageURL.parse("not-a-url")) { error in
            guard case NotionSiteFetchError.invalidURL = error else {
                return XCTFail("expected invalidURL, got \(error)")
            }
        }
    }
}
