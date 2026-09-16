import XCTest
@testable import NotionSiteFetch

final class JSONValueTests: XCTestCase {
    func testRoundTripPreservesTypes() throws {
        let original: JSONValue = [
            "ok": true,
            "count": 3,
            "nested": ["a", nil, 1.5],
        ]
        let parsed = try JSONValue.parse(data: original.encodedData())
        XCTAssertEqual(parsed["ok"].bool, true)
        XCTAssertEqual(parsed["count"].int, 3)
        XCTAssertEqual(parsed["nested"][0].string, "a")
        XCTAssertTrue(parsed["nested"][1].isNull)
        XCTAssertEqual(parsed["nested"][2].number, 1.5)
    }

    func testMissingKeysAreNull() {
        let value: JSONValue = ["present": "yes"]
        XCTAssertTrue(value["absent"].isNull)
        XCTAssertEqual(value["present"].string, "yes")
    }
}
