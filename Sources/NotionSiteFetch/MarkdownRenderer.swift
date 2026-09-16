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

    public static func render(
        rootPageID: String,
        blocks: [String: JSONValue],
        collections: [String: JSONValue] = [:],
        collectionViews: [String: JSONValue] = [:],
        collectionRowIDs: [String: [String]] = [:],
        users: [String: JSONValue] = [:]
    ) -> String {
        let lines = renderBlockLines(
            blockID: rootPageID,
            allBlocks: blocks,
            collections: collections,
            collectionViews: collectionViews,
            collectionRowIDs: collectionRowIDs,
            users: users,
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
        collections: [String: JSONValue] = [:],
        collectionViews: [String: JSONValue] = [:],
        collectionRowIDs: [String: [String]] = [:],
        users: [String: JSONValue] = [:],
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
        case "collection_view", "collection_view_page":
            outputLines.append(contentsOf: renderCollectionViewLines(
                blockID: blockID,
                blockValue: blockValue,
                allBlocks: allBlocks,
                collections: collections,
                collectionViews: collectionViews,
                collectionRowIDs: collectionRowIDs,
                users: users,
                indentLevel: indentLevel,
                indentPrefix: indentPrefix
            ))
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
                collections: collections,
                collectionViews: collectionViews,
                collectionRowIDs: collectionRowIDs,
                users: users,
                indentLevel: childIndentLevel,
                siblingListPosition: numberedPositionCounter
            ))
            previousChildType = childBlockType
        }

        return outputLines
    }

    /// Inline or full-page database view. Rows come from `queryCollection`.
    private static func renderCollectionViewLines(
        blockID: String,
        blockValue: JSONValue,
        allBlocks: [String: JSONValue],
        collections: [String: JSONValue],
        collectionViews: [String: JSONValue],
        collectionRowIDs: [String: [String]],
        users: [String: JSONValue],
        indentLevel: Int,
        indentPrefix: String
    ) -> [String] {
        let collectionID = NotionRecordMap.collectionID(from: blockValue)
        let collection = collectionID.flatMap { collections[$0] }
        let title = collectionViewTitle(blockValue: blockValue, collection: collection)
        var lines: [String] = []
        if !title.isEmpty {
            if blockValue["type"].string == "collection_view_page", indentLevel == 0 {
                lines.append("# \(title)")
            } else {
                lines.append("\(indentPrefix)\(title)")
            }
            lines.append("")
        }

        if let collection,
           let rowIDs = collectionRowIDs[blockID],
           let tableLines = renderCollectionTableLines(
            collection: collection,
            view: blockValue["view_ids"].array.compactMap(\.string).first.flatMap({ collectionViews[$0] }),
            rowIDs: rowIDs,
            allBlocks: allBlocks,
            users: users,
            indentPrefix: indentPrefix
           ) {
            lines.append(contentsOf: tableLines)
        }
        return lines
    }

    private static func collectionViewTitle(blockValue: JSONValue, collection: JSONValue?) -> String {
        let blockTitle = renderRichText(blockValue["properties"]["title"])
        if !blockTitle.isEmpty {
            return blockTitle
        }
        if let collection {
            let name = renderRichText(collection["name"])
            if !name.isEmpty {
                return name
            }
        }
        return ""
    }

    private static func renderCollectionTableLines(
        collection: JSONValue,
        view: JSONValue?,
        rowIDs: [String],
        allBlocks: [String: JSONValue],
        users: [String: JSONValue],
        indentPrefix: String
    ) -> [String]? {
        let schema = collection["schema"]
        guard !schema.object.isEmpty else { return nil }

        let columnIDs = visibleCollectionColumnIDs(schema: schema, view: view)
        guard !columnIDs.isEmpty else { return nil }

        let headers = columnIDs.map { columnID in
            escapeTableCell(schema[columnID]["name"].string ?? columnID)
        }
        var lines: [String] = []
        func pipeRow(_ cells: [String]) -> String {
            "\(indentPrefix)| " + cells.joined(separator: " | ") + " |"
        }
        lines.append(pipeRow(headers))
        lines.append(pipeRow(Array(repeating: "---", count: columnIDs.count)))
        for rowID in rowIDs {
            guard let row = allBlocks[rowID] else { continue }
            let cells = columnIDs.map { columnID in
                escapeTableCell(
                    renderCollectionCell(
                        columnID: columnID,
                        schema: schema[columnID],
                        row: row,
                        allBlocks: allBlocks,
                        users: users
                    )
                )
            }
            lines.append(pipeRow(cells))
        }
        lines.append("")
        return lines
    }

    static func visibleCollectionColumnIDs(schema: JSONValue, view: JSONValue?) -> [String] {
        let tableProperties = (view ?? .null)["format"]["table_properties"].array
        var columnIDs: [String] = []
        var seen = Set<String>()
        for entry in tableProperties {
            guard entry["visible"].bool != false else { continue }
            guard let propertyID = entry["property"].string, !propertyID.isEmpty else { continue }
            guard !schema[propertyID].isNull || propertyID == "title" else { continue }
            if seen.insert(propertyID).inserted {
                columnIDs.append(propertyID)
            }
        }
        if !columnIDs.isEmpty {
            return columnIDs
        }

        if !schema["title"].isNull {
            columnIDs.append("title")
            seen.insert("title")
        }
        for key in schema.object.keys.sorted() where seen.insert(key).inserted {
            columnIDs.append(key)
        }
        return columnIDs
    }

    static func renderCollectionCell(
        columnID: String,
        schema: JSONValue,
        row: JSONValue,
        allBlocks: [String: JSONValue],
        users: [String: JSONValue]
    ) -> String {
        let propertyType = schema["type"].string ?? ""
        let raw = row["properties"][columnID]
        switch propertyType {
        case "checkbox":
            let text = renderRichText(raw)
            return text == "Yes" ? "Yes" : (text == "No" ? "No" : text)
        case "created_time":
            let fromProperty = renderCollectionValue(raw, allBlocks: allBlocks, users: users)
            if !fromProperty.isEmpty { return fromProperty }
            return formatEpochMilliseconds(row["created_time"])
        case "last_edited_time":
            let fromProperty = renderCollectionValue(raw, allBlocks: allBlocks, users: users)
            if !fromProperty.isEmpty { return fromProperty }
            return formatEpochMilliseconds(row["last_edited_time"])
        case "created_by":
            let fromProperty = renderCollectionValue(raw, allBlocks: allBlocks, users: users)
            if !fromProperty.isEmpty { return fromProperty }
            return userDisplayName(row["created_by_id"].string, users: users)
        case "last_edited_by":
            let fromProperty = renderCollectionValue(raw, allBlocks: allBlocks, users: users)
            if !fromProperty.isEmpty { return fromProperty }
            return userDisplayName(row["last_edited_by_id"].string, users: users)
        default:
            return renderCollectionValue(raw, allBlocks: allBlocks, users: users)
        }
    }

    private static func renderCollectionValue(
        _ raw: JSONValue,
        allBlocks: [String: JSONValue],
        users: [String: JSONValue]
    ) -> String {
        guard !raw.isNull else { return "" }
        var parts: [String] = []
        for run in raw.array {
            if let special = renderSpecialCollectionRun(run, allBlocks: allBlocks, users: users) {
                if !special.isEmpty {
                    parts.append(special)
                }
                continue
            }
            let text = renderRichText(.array([run]))
            if !text.isEmpty, text != "‣" {
                parts.append(text)
            }
        }
        return parts.joined(separator: ", ")
    }

    private static func renderSpecialCollectionRun(
        _ run: JSONValue,
        allBlocks: [String: JSONValue],
        users: [String: JSONValue]
    ) -> String? {
        let decorations: [JSONValue]
        if case .array(let parts) = run, parts.count > 1 {
            decorations = parts[1].array
        } else {
            return nil
        }
        var rendered: [String] = []
        var sawPointer = false
        for decoration in decorations {
            guard let tag = decoration[0].string else { continue }
            switch tag {
            case "d":
                sawPointer = true
                let date = formatCollectionDate(decoration[1])
                if !date.isEmpty { rendered.append(date) }
            case "u":
                sawPointer = true
                let name = userDisplayName(decoration[1].string, users: users)
                if !name.isEmpty { rendered.append(name) }
            case "p":
                sawPointer = true
                let pageID = decoration[1].string
                if let pageID, let page = allBlocks[pageID] {
                    let title = renderRichText(page["properties"]["title"])
                    if !title.isEmpty { rendered.append(title) }
                }
            default:
                break
            }
        }
        return sawPointer ? rendered.joined(separator: ", ") : nil
    }

    static func formatCollectionDate(_ value: JSONValue) -> String {
        let start = value["start_date"].string
            ?? value["start_date"].number.map { String(Int($0)) }
        let end = value["end_date"].string
        let startTime = value["start_time"].string
        let endTime = value["end_time"].string
        guard let start, !start.isEmpty else { return "" }
        var left = start
        if let startTime, !startTime.isEmpty {
            left += " \(startTime)"
        }
        if let end, !end.isEmpty {
            var right = end
            if let endTime, !endTime.isEmpty {
                right += " \(endTime)"
            }
            return "\(left) → \(right)"
        }
        return left
    }

    static func formatEpochMilliseconds(_ value: JSONValue) -> String {
        guard let milliseconds = value.number ?? value.string.flatMap(Double.init) else {
            return ""
        }
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func userDisplayName(_ userID: String?, users: [String: JSONValue]) -> String {
        guard let userID, let user = users[userID] else { return "" }
        if let name = user["name"].string, !name.isEmpty {
            return name
        }
        return ""
    }

    /// Notion simple tables (`table` + `table_row`).
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
