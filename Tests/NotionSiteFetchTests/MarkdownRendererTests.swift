import XCTest
@testable import NotionSiteFetch

final class MarkdownRendererTests: XCTestCase {
    func testRichTextDecorationsAndLinks() {
        let runs: JSONValue = [
            ["plain"],
            ["bold", [["b"]]],
            ["code", [["c"]]],
            ["site", [["a", "https://example.com"], ["i"]]],
        ]
        XCTAssertEqual(
            NotionMarkdownRenderer.renderRichText(runs),
            "plain**bold**`code`[*site*](https://example.com)"
        )
    }

    func testEmptyRichText() {
        XCTAssertEqual(NotionMarkdownRenderer.renderRichText(nil), "")
        XCTAssertEqual(NotionMarkdownRenderer.renderRichText(.null), "")
        XCTAssertEqual(NotionMarkdownRenderer.renderRichText(.array([])), "")
    }

    func testRendersCoreBlockTypes() {
        let root = "root"
        let blocks: [String: JSONValue] = [
            "root": [
                "type": "page",
                "properties": ["title": [["Kitchen Sink"]]],
                "content": [
                    "h", "p", "ul", "ol1", "ol2", "todo", "quote", "callout",
                    "div", "code", "img", "mark", "eq", "skip", "unknown",
                ],
            ],
            "h": [
                "type": "header",
                "properties": ["title": [["Section"]]],
            ],
            "p": [
                "type": "text",
                "properties": ["title": [["Hello", [["b"]]]]],
            ],
            "ul": [
                "type": "bulleted_list",
                "properties": ["title": [["Item"]]],
                "content": ["nested"],
            ],
            "nested": [
                "type": "bulleted_list",
                "properties": ["title": [["Child"]]],
            ],
            "ol1": [
                "type": "numbered_list",
                "properties": ["title": [["One"]]],
            ],
            "ol2": [
                "type": "numbered_list",
                "properties": ["title": [["Two"]]],
            ],
            "todo": [
                "type": "to_do",
                "properties": [
                    "title": [["Done"]],
                    "checked": [["Yes"]],
                ],
            ],
            "quote": [
                "type": "quote",
                "properties": ["title": [["Cited"]]],
            ],
            "callout": [
                "type": "callout",
                "properties": ["title": [["Note"]]],
                "format": ["page_icon": "\ud83d\udcce"],
            ],
            "div": ["type": "divider"],
            "code": [
                "type": "code",
                "properties": [
                    "title": [["print(\"hi\")"]],
                    "language": [["Swift"]],
                ],
            ],
            "img": [
                "type": "image",
                "properties": [
                    "source": [["https://img.test/a.png"]],
                    "caption": [["Alt"]],
                ],
            ],
            "mark": [
                "type": "bookmark",
                "properties": [
                    "title": [["Docs"]],
                    "source": [["https://example.com"]],
                ],
            ],
            "eq": [
                "type": "equation",
                "properties": ["title": [["E=mc^2"]]],
            ],
            "skip": ["type": "table_of_contents"],
            "unknown": [
                "type": "collection_view",
                "properties": ["title": [["Database title"]]],
            ],
        ]

        let markdown = NotionMarkdownRenderer.render(rootPageID: root, blocks: blocks)
        let expected = """
        # Kitchen Sink

        ## Section

        **Hello**

        - Item
            - Child
        1. One
        2. Two
        - [x] Done
        > Cited

        > \ud83d\udcce Note

        ---

        ```swift
        print("hi")
        ```

        ![Alt](https://img.test/a.png)

        [Docs](https://example.com)

        $$E=mc^2$$

        Database title

        """
        XCTAssertEqual(markdown, expected)
    }

    func testCollapseBlankLines() {
        XCTAssertEqual(
            NotionMarkdownRenderer.collapseBlankLines(["a", "", "", "b", ""]),
            "a\n\nb\n"
        )
    }

    func testRendersSimpleTableWithHeaderRow() {
        let blocks: [String: JSONValue] = [
            "root": [
                "type": "page",
                "properties": ["title": [["\uad6c\ub3c5 \uad00\ub9ac"]]],
                "content": ["table"],
            ],
            "table": [
                "type": "table",
                "format": [
                    "table_block_column_order": ["colA", "colB"],
                    "table_block_column_header": true,
                ],
                "content": ["h", "r1"],
            ],
            "h": [
                "type": "table_row",
                "properties": [
                    "colA": [["\uc774\ub984"]],
                    "colB": [["\uae08\uc561"]],
                ],
            ],
            "r1": [
                "type": "table_row",
                "properties": [
                    "colA": [["Netflix"]],
                    "colB": [["13,500"]],
                ],
            ],
        ]

        XCTAssertEqual(
            NotionMarkdownRenderer.render(rootPageID: "root", blocks: blocks),
            """
            # \uad6c\ub3c5 \uad00\ub9ac

            | \uc774\ub984 | \uae08\uc561 |
            | --- | --- |
            | Netflix | 13,500 |

            """
        )
    }

    func testRendersCollectionViewRowsAsMarkdownTable() {
        let blocks: [String: JSONValue] = [
            "root": [
                "type": "page",
                "properties": ["title": [["Docs"]]],
                "content": ["view"],
            ],
            "view": [
                "type": "collection_view",
                "properties": ["title": [["Tasks"]]],
                "collection_id": "col",
                "view_ids": ["table-view"],
            ],
            "r1": [
                "type": "page",
                "properties": [
                    "title": [["Alpha"]],
                    "stat": [["Done"]],
                    "when": [[
                        "\u2023",
                        [["d", ["type": "date", "start_date": "2024-09-03"]]],
                    ]],
                    "done": [["Yes"]],
                ],
                "created_time": 1_720_000_000_000,
            ],
            "r2": [
                "type": "page",
                "properties": [
                    "title": [["Beta"]],
                    "stat": [["Todo"]],
                    "rel": [[
                        "\u2023",
                        [["p", "related"]],
                    ]],
                    "who": [[
                        "\u2023",
                        [["u", "user-1"]],
                    ]],
                ],
            ],
            "related": [
                "type": "page",
                "properties": ["title": [["Related page"]]],
            ],
        ]
        let collections: [String: JSONValue] = [
            "col": [
                "name": [["Tasks"]],
                "schema": [
                    "title": ["name": "Name", "type": "title"],
                    "stat": ["name": "Status", "type": "select"],
                    "when": ["name": "Due", "type": "date"],
                    "done": ["name": "Done", "type": "checkbox"],
                    "rel": ["name": "Link", "type": "relation"],
                    "who": ["name": "Owner", "type": "person"],
                    "created": ["name": "Created", "type": "created_time"],
                ],
            ],
        ]
        let collectionViews: [String: JSONValue] = [
            "table-view": [
                "type": "table",
                "format": [
                    "table_properties": [
                        ["property": "title", "visible": true],
                        ["property": "stat", "visible": true],
                        ["property": "when", "visible": true],
                        ["property": "done", "visible": true],
                        ["property": "rel", "visible": true],
                        ["property": "who", "visible": true],
                        ["property": "created", "visible": true],
                        ["property": "hidden", "visible": false],
                    ],
                ],
            ],
        ]

        XCTAssertEqual(
            NotionMarkdownRenderer.render(
                rootPageID: "root",
                blocks: blocks,
                collections: collections,
                collectionViews: collectionViews,
                collectionRowIDs: ["view": ["r1", "r2"]],
                users: ["user-1": ["name": "Ada"]]
            ),
            """
            # Docs

            Tasks

            | Name | Status | Due | Done | Link | Owner | Created |
            | --- | --- | --- | --- | --- | --- | --- |
            | Alpha | Done | 2024-09-03 | Yes |  |  | 2024-07-03 |
            | Beta | Todo |  |  | Related page | Ada |  |

            """
        )
    }

    func testCollectionViewWithoutRowsKeepsTitleOnly() {
        let blocks: [String: JSONValue] = [
            "root": [
                "type": "collection_view_page",
                "properties": ["title": [["Leads Database"]]],
                "collection_id": "col",
                "view_ids": ["v"],
            ],
        ]
        XCTAssertEqual(
            NotionMarkdownRenderer.render(rootPageID: "root", blocks: blocks),
            """
            # Leads Database

            """
        )
    }

    func testMissingBlockIsSkipped() {
        XCTAssertEqual(
            NotionMarkdownRenderer.render(rootPageID: "missing", blocks: [:]),
            "\n"
        )
    }
}
