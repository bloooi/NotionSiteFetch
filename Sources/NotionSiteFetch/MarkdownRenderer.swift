import Foundation

public enum NotionMarkdownRenderer: Sendable {
    public static func renderRichText(_ richTextRuns: JSONValue?) -> String {
        guard let richTextRuns, !richTextRuns.isNull else { return "" }
        var outputSegments: [String] = []

        for run in richTextRuns.array {
            if run.isNull || (run.array.isEmpty && run.string == nil) {
                continue
            }

            let plainText: String
            let formatDecorations: [JSONValue]
            if case .array(let parts) = run {
                plainText = parts.first?.string ?? ""
                formatDecorations = parts.count > 1 ? parts[1].array : []
            } else {
                continue
            }

            var linkURL: String?
            var isBold = false
            var isItalic = false
            var isStrikethrough = false
            var isCode = false

            for decoration in formatDecorations {
                guard !decoration.isNull else { continue }
                let tag = decoration[0].string ?? ""
                switch tag {
                case "b":
                    isBold = true
                case "i":
                    isItalic = true
                case "s":
                    isStrikethrough = true
                case "c":
                    isCode = true
                case "a" where decoration.array.count > 1:
                    linkURL = decoration[1].string
                default:
                    break
                }
            }

            var styledText = plainText
            if isCode {
                styledText = "`\(styledText)`"
            } else {
                if isBold {
                    styledText = "**\(styledText)**"
                }
                if isItalic {
                    styledText = "*\(styledText)*"
                }
                if isStrikethrough {
                    styledText = "~~\(styledText)~~"
                }
            }
            if let linkURL {
                styledText = "[\(styledText)](\(linkURL))"
            }
            outputSegments.append(styledText)
        }

        return outputSegments.joined()
    }

    public static func render(rootPageID: String, blocks: [String: JSONValue]) -> String {
        let lines = renderBlockLines(
            blockID: rootPageID,
            allBlocks: blocks,
            indentLevel: 0,
            siblingListPosition: 0
        )
        return collapseBlankLines(lines)
    }

    public static func collapseBlankLines(_ renderedLines: [String]) -> String {
        var outputBuffer: [String] = []
        var previousWasBlank = false
        for line in renderedLines {
            let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank && previousWasBlank {
                continue
            }
            outputBuffer.append(line)
            previousWasBlank = isBlank
        }
        var joined = outputBuffer.joined(separator: "\n")
        while let last = joined.last, last.isWhitespace {
            joined.removeLast()
        }
        return joined + "\n"
    }

    static func renderBlockLines(
        blockID: String,
        allBlocks: [String: JSONValue],
        indentLevel: Int,
        siblingListPosition: Int
    ) -> [String] {
        guard let blockValue = allBlocks[blockID], !blockValue.isNull else {
            return []
        }

        let blockType = blockValue["type"].string
        let properties = blockValue["properties"]
        let titleRichText = properties["title"]
        let renderedTitle = renderRichText(titleRichText.isNull ? .array([]) : titleRichText)
        let indentPrefix = String(repeating: "    ", count: indentLevel)
        var outputLines: [String] = []

        switch blockType {
        case "page":
            if !renderedTitle.isEmpty {
                outputLines.append("# \(renderedTitle)")
                outputLines.append("")
            }
        case "header":
            outputLines.append("\(indentPrefix)## \(renderedTitle)")
            outputLines.append("")
        case "sub_header":
            outputLines.append("\(indentPrefix)### \(renderedTitle)")
            outputLines.append("")
        case "sub_sub_header":
            outputLines.append("\(indentPrefix)#### \(renderedTitle)")
            outputLines.append("")
        case "text":
            outputLines.append("\(indentPrefix)\(renderedTitle)")
            outputLines.append("")
        case "bulleted_list":
            outputLines.append("\(indentPrefix)- \(renderedTitle)")
        case "numbered_list":
            outputLines.append("\(indentPrefix)\(siblingListPosition). \(renderedTitle)")
        case "to_do":
            let isChecked = properties["checked"] == .array([.array([.string("Yes")])])
            let checkboxMarker = isChecked ? "[x]" : "[ ]"
            outputLines.append("\(indentPrefix)- \(checkboxMarker) \(renderedTitle)")
        case "toggle":
            outputLines.append("\(indentPrefix)- \(renderedTitle)")
        case "quote":
            outputLines.append("\(indentPrefix)> \(renderedTitle)")
            outputLines.append("")
        case "callout":
            let emojiIcon = blockValue["format"]["page_icon"].string ?? ""
            let leadingMarker: String
            if !emojiIcon.isEmpty && !emojiIcon.hasPrefix("/") {
                leadingMarker = "\(emojiIcon) "
            } else {
                leadingMarker = ""
            }
            outputLines.append("\(indentPrefix)> \(leadingMarker)\(renderedTitle)")
            outputLines.append("")
        case "divider":
            outputLines.append("\(indentPrefix)---")
            outputLines.append("")
        case "code":
            let codeLanguage = renderRichText(
                properties["language"].isNull ? .array([]) : properties["language"]
            ).lowercased()
            outputLines.append("\(indentPrefix)```\(codeLanguage)")
            for codeLine in renderedTitle.split(separator: "\n", omittingEmptySubsequences: false) {
                outputLines.append("\(indentPrefix)\(codeLine)")
            }
            outputLines.append("\(indentPrefix)```")
            outputLines.append("")
        case "image":
            let imageURL = renderRichText(
                properties["source"].isNull ? .array([]) : properties["source"]
            )
            let imageCaption = renderRichText(
                properties["caption"].isNull ? .array([]) : properties["caption"]
            )
            if !imageURL.isEmpty {
                outputLines.append("\(indentPrefix)![\(imageCaption)](\(imageURL))")
                outputLines.append("")
            }
        case "bookmark", "video", "embed", "file", "pdf", "audio":
            let linkRuns = properties["source"].isNull ? properties["link"] : properties["source"]
            let linkURL = renderRichText(linkRuns.isNull ? .array([]) : linkRuns)
            if !linkURL.isEmpty {
                let label = renderedTitle.isEmpty ? linkURL : renderedTitle
                outputLines.append("\(indentPrefix)[\(label)](\(linkURL))")
                outputLines.append("")
            }
        case "equation":
            let expression = renderRichText(
                properties["title"].isNull ? .array([]) : properties["title"]
            )
            outputLines.append("\(indentPrefix)$$\(expression)$$")
            outputLines.append("")
        case "table":
            outputLines.append(contentsOf: renderTableLines(
                blockValue: blockValue,
                allBlocks: allBlocks,
                indentPrefix: indentPrefix
            ))
        case "table_row":
            break
        case "column_list", "column", "table_of_contents", "breadcrumb":
            break
        default:
            if !renderedTitle.isEmpty {
                outputLines.append("\(indentPrefix)\(renderedTitle)")
                outputLines.append("")
            }
        }

        if blockType == "table" {
            return outputLines
        }

        let childBlockIDs = blockValue["content"].array.compactMap(\.string)
        let nestsDescendants = ["bulleted_list", "numbered_list", "to_do", "toggle"].contains(blockType)
        var childIndentLevel = nestsDescendants ? indentLevel + 1 : indentLevel
        if blockType == "page" {
            childIndentLevel = 0
        }

        var numberedPositionCounter = 0
        var previousChildType: String?
        for childBlockID in childBlockIDs {
            let childBlockType = allBlocks[childBlockID]?["type"].string
            if childBlockType == "numbered_list" {
                if previousChildType == "numbered_list" {
                    numberedPositionCounter += 1
                } else {
                    numberedPositionCounter = 1
                }
            } else {
                numberedPositionCounter = 0
            }
            outputLines.append(contentsOf: renderBlockLines(
                blockID: childBlockID,
                allBlocks: allBlocks,
                indentLevel: childIndentLevel,
                siblingListPosition: numberedPositionCounter
            ))
            previousChildType = childBlockType
        }

        return outputLines
    }

    /// Notion simple tables (`table` + `table_row`). Not a database/collection view.
    private static func renderTableLines(
        blockValue: JSONValue,
        allBlocks: [String: JSONValue],
        indentPrefix: String
    ) -> [String] {
        let format = blockValue["format"]
        let columnOrder = format["table_block_column_order"].array.compactMap(\.string)
        guard !columnOrder.isEmpty else { return [] }

        let hasHeader = format["table_block_column_header"].bool == true
        let rowIDs = blockValue["content"].array.compactMap(\.string)
        var rows: [[String]] = []
        rows.reserveCapacity(rowIDs.count)

        for rowID in rowIDs {
            guard let row = allBlocks[rowID], row["type"].string == "table_row" else {
                continue
            }
            let cells = columnOrder.map { columnID -> String in
                let raw = renderRichText(row["properties"][columnID])
                return escapeTableCell(raw)
            }
            rows.append(cells)
        }
        guard !rows.isEmpty else { return [] }

        var lines: [String] = []
        func pipeRow(_ cells: [String]) -> String {
            "\(indentPrefix)| " + cells.joined(separator: " | ") + " |"
        }
        let separator = columnOrder.map { _ in "---" }

        if hasHeader {
            lines.append(pipeRow(rows[0]))
            lines.append(pipeRow(separator))
            for row in rows.dropFirst() {
                lines.append(pipeRow(row))
            }
        } else {
            lines.append(pipeRow(Array(repeating: "", count: columnOrder.count)))
            lines.append(pipeRow(separator))
            for row in rows {
                lines.append(pipeRow(row))
            }
        }
        lines.append("")
        return lines
    }

    private static func escapeTableCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
