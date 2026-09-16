import Foundation

/// Normalized `recordMap` tables from Notion's unofficial public APIs.
///
/// `loadCachedPageChunkV2` and `queryCollection` wrap records as
/// `{ value: { value: ... } }`. This type unwraps them and keeps collection
/// metadata next to page blocks so database views can be rendered.
struct NotionRecordMap: Sendable, Equatable {
    var blocks: [String: JSONValue] = [:]
    var collections: [String: JSONValue] = [:]
    var collectionViews: [String: JSONValue] = [:]
    var users: [String: JSONValue] = [:]
    var collectionRowIDs: [String: [String]] = [:]
    var spaceID: String?

    mutating func ingest(_ recordMap: JSONValue) {
        merge(recordMap["block"], into: &blocks)
        merge(recordMap["collection"], into: &collections)
        merge(recordMap["collection_view"], into: &collectionViews)
        merge(recordMap["notion_user"], into: &users)
        if spaceID == nil {
            spaceID = firstSpaceID(in: recordMap["block"])
                ?? firstSpaceID(in: recordMap["collection"])
        }
    }

    static func unwrap(_ record: JSONValue) -> JSONValue {
        let inner = record["value"]
        let nested = inner["value"]
        if !nested.isNull {
            return nested
        }
        if !inner.isNull {
            return inner
        }
        return record
    }

    static func collectionID(from block: JSONValue) -> String? {
        if let id = block["collection_id"].string, !id.isEmpty {
            return id
        }
        if let id = block["format"]["collection_pointer"]["id"].string, !id.isEmpty {
            return id
        }
        return nil
    }

    static func isCollectionView(_ block: JSONValue) -> Bool {
        let type = block["type"].string
        return type == "collection_view" || type == "collection_view_page"
    }

    func reachableIDs(from rootID: String) -> Set<String> {
        var seen = Set<String>()
        var stack = [rootID]
        while let id = stack.popLast() {
            guard seen.insert(id).inserted else { continue }
            if let block = blocks[id] {
                stack.append(contentsOf: block["content"].array.compactMap(\.string))
            }
        }
        return seen
    }

    static func userIDs(in rows: [JSONValue]) -> [String] {
        var ids = Set<String>()
        for row in rows {
            if let id = row["created_by_id"].string, !id.isEmpty { ids.insert(id) }
            if let id = row["last_edited_by_id"].string, !id.isEmpty { ids.insert(id) }
            for (_, property) in row["properties"].object {
                for run in property.array {
                    for decoration in run[1].array where decoration[0].string == "u" {
                        if let id = decoration[1].string, !id.isEmpty {
                            ids.insert(id)
                        }
                    }
                }
            }
        }
        return Array(ids)
    }

    private func firstSpaceID(in records: JSONValue) -> String? {
        for (_, record) in records.object {
            if let spaceID = record["spaceId"].string, !spaceID.isEmpty {
                return spaceID
            }
            let value = Self.unwrap(record)
            if let spaceID = value["space_id"].string, !spaceID.isEmpty {
                return spaceID
            }
        }
        return nil
    }

    private func merge(_ records: JSONValue, into map: inout [String: JSONValue]) {
        for (id, record) in records.object {
            let value = Self.unwrap(record)
            if !value.isNull {
                map[id] = value
            }
        }
    }
}
