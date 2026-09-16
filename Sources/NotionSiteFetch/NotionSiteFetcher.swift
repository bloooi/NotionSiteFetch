import Foundation

public struct NotionFetchedPage: Sendable, Equatable {
    public var rootPageID: String
    public var spaceID: String?
    public var blocks: [String: JSONValue]
    public var collections: [String: JSONValue]
    public var collectionViews: [String: JSONValue]
    public var collectionRowIDs: [String: [String]]
    public var markdown: String

    public init(
        rootPageID: String,
        spaceID: String?,
        blocks: [String: JSONValue],
        markdown: String,
        collections: [String: JSONValue] = [:],
        collectionViews: [String: JSONValue] = [:],
        collectionRowIDs: [String: [String]] = [:]
    ) {
        self.rootPageID = rootPageID
        self.spaceID = spaceID
        self.blocks = blocks
        self.collections = collections
        self.collectionViews = collectionViews
        self.collectionRowIDs = collectionRowIDs
        self.markdown = markdown
    }
}

public enum FetchStage: String, Sendable, Equatable {
    case resolving
    case loadingChunks
    case loadingLazyBlocks
    case loadingCollections
    case rendering
}

public struct NotionSiteFetcher: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var maxRetries: Int
        public var maxBackoffSeconds: Double
        public var requestTimeout: TimeInterval
        /// Max rows loaded per database view. `queryCollection` is re-issued
        /// with a higher limit when the first page sets `hasMore`.
        public var collectionRowLimit: Int

        public static let `default` = Configuration()

        public init(
            maxRetries: Int = NotionSiteFetcher.defaultMaxRetries,
            maxBackoffSeconds: Double = NotionSiteFetcher.defaultMaxBackoffSeconds,
            requestTimeout: TimeInterval = 30,
            collectionRowLimit: Int = 200
        ) {
            self.maxRetries = maxRetries
            self.maxBackoffSeconds = maxBackoffSeconds
            self.requestTimeout = requestTimeout
            self.collectionRowLimit = collectionRowLimit
        }
    }

    public static let defaultMaxRetries = 8
    public static let defaultMaxBackoffSeconds = 10.0

    private let client: any NotionHTTPClient
    private let sleeper: any Sleeper
    private let configuration: Configuration

    public init(
        client: (any NotionHTTPClient)? = nil,
        sleeper: any Sleeper = TaskSleeper(),
        configuration: Configuration = .default
    ) {
        self.client = client ?? URLSessionHTTPClient(timeout: configuration.requestTimeout)
        self.sleeper = sleeper
        self.configuration = configuration
    }

    public func fetchMarkdown(from urlString: String) async throws -> String {
        try await fetchPage(from: urlString).markdown
    }

    public func fetchMarkdown(from url: URL) async throws -> String {
        try await fetchPage(from: url).markdown
    }

    public func fetchPage(
        from urlString: String,
        onProgress: (@Sendable (FetchStage) -> Void)? = nil
    ) async throws -> NotionFetchedPage {
        try await fetchPage(from: NotionPageURL.parse(urlString), onProgress: onProgress)
    }

    public func fetchPage(
        from url: URL,
        onProgress: (@Sendable (FetchStage) -> Void)? = nil
    ) async throws -> NotionFetchedPage {
        let apiBase = NotionPageURL.apiBase(for: url)
        onProgress?(.resolving)
        let resolved = try await PageResolver.resolvePageAndSpace(
            targetURL: url,
            client: client,
            sleeper: sleeper,
            apiBase: apiBase,
            maxRetries: configuration.maxRetries,
            maxBackoffSeconds: configuration.maxBackoffSeconds
        )

        onProgress?(.loadingChunks)
        var store = try await fetchAllBlocks(
            rootPageID: resolved.pageID,
            apiBase: apiBase,
            spaceID: resolved.spaceID,
            onProgress: onProgress
        )

        guard store.blocks[resolved.pageID] != nil else {
            throw NotionSiteFetchError.rootPageMissing(resolved.pageID)
        }

        onProgress?(.loadingCollections)
        await fetchCollectionViews(
            into: &store,
            rootPageID: resolved.pageID,
            apiBase: apiBase
        )

        onProgress?(.rendering)
        let markdown = NotionMarkdownRenderer.render(
            rootPageID: resolved.pageID,
            blocks: store.blocks,
            collections: store.collections,
            collectionViews: store.collectionViews,
            collectionRowIDs: store.collectionRowIDs,
            users: store.users
        )
        return NotionFetchedPage(
            rootPageID: resolved.pageID,
            spaceID: store.spaceID,
            blocks: store.blocks,
            markdown: markdown,
            collections: store.collections,
            collectionViews: store.collectionViews,
            collectionRowIDs: store.collectionRowIDs
        )
    }

    private func postJSON(
        url: URL,
        body: JSONValue,
        maxRetries: Int? = nil,
        timeout: TimeInterval? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> JSONValue {
        try await NotionAPI.postJSON(
            client: client,
            sleeper: sleeper,
            url: url,
            body: body,
            maxRetries: maxRetries ?? configuration.maxRetries,
            maxBackoffSeconds: configuration.maxBackoffSeconds,
            timeout: timeout,
            extraHeaders: extraHeaders
        )
    }

    private func fetchAllBlocks(
        rootPageID: String,
        apiBase: String,
        spaceID: String?,
        onProgress: (@Sendable (FetchStage) -> Void)?
    ) async throws -> NotionRecordMap {
        var store = NotionRecordMap()
        store.spaceID = spaceID
        var cursorState: JSONValue = ["stack": .array([])]
        var chunkIndex = 0

        guard let chunkURL = URL(string: "\(apiBase)/loadCachedPageChunkV2") else {
            throw NotionSiteFetchError.invalidURL("\(apiBase)/loadCachedPageChunkV2")
        }

        while true {
            let chunkData = try await postJSON(
                url: chunkURL,
                body: [
                    "page": ["id": .string(rootPageID)],
                    "limit": 100,
                    "cursor": cursorState,
                    "chunkNumber": .number(Double(chunkIndex)),
                    "verticalColumns": false,
                ]
            )
            store.ingest(chunkData["recordMap"])

            let responseCursors = chunkData["cursors"].array
            let nextCursor = responseCursors.first
            let nextStack = nextCursor?["stack"]
            if nextCursor == nil || nextStack == nil || nextStack?.array.isEmpty == true {
                break
            }
            cursorState = ["stack": nextStack ?? .array([])]
            chunkIndex += 1
            if chunkIndex >= 80 {
                break
            }
        }

        guard let spaceID = store.spaceID else {
            return store
        }

        onProgress?(.loadingLazyBlocks)
        var seenSyncHosts = Set<String>()
        let syncURLs = [
            "\(apiBase)/syncRecordValues",
            "https://www.notion.so/api/v3/syncRecordValues",
        ].filter { seenSyncHosts.insert($0).inserted }.compactMap(URL.init(string:))

        var lazyRounds = 0
        while true {
            lazyRounds += 1
            if lazyRounds > 20 {
                return store
            }
            var missingBlockIDs: [String] = []
            var seen = Set<String>()
            for block in store.blocks.values {
                for childID in block["content"].array.compactMap(\.string) where store.blocks[childID] == nil {
                    if seen.insert(childID).inserted {
                        missingBlockIDs.append(childID)
                    }
                }
            }
            if missingBlockIDs.isEmpty {
                break
            }

            var batchStart = 0
            while batchStart < missingBlockIDs.count {
                let batchIDs = Array(missingBlockIDs[batchStart..<min(batchStart + 100, missingBlockIDs.count)])
                let requests: [JSONValue] = batchIDs.map { blockID in
                    [
                        "pointer": [
                            "table": "block",
                            "id": .string(blockID),
                            "spaceId": .string(spaceID),
                        ],
                        "version": -1,
                    ]
                }
                let payload: JSONValue = ["requests": .array(requests)]
                guard let syncData = await postLazyBlocks(urls: syncURLs, body: payload) else {
                    return store
                }
                store.ingest(syncData["recordMap"])
                if batchIDs.allSatisfy({ store.blocks[$0] == nil }) {
                    return store
                }
                batchStart += 100
            }
        }

        return store
    }

    /// Public database views do not include rows in `loadCachedPageChunkV2`.
    /// `queryCollection` is the same unofficial endpoint the Notion web client
    /// uses for an anonymous visitor. Failures stay soft so the rest of the
    /// page still renders.
    private func fetchCollectionViews(
        into store: inout NotionRecordMap,
        rootPageID: String,
        apiBase: String
    ) async {
        let reachable = store.reachableIDs(from: rootPageID)
        let viewBlocks = store.blocks.compactMap { blockID, block -> (String, JSONValue)? in
            guard reachable.contains(blockID), NotionRecordMap.isCollectionView(block) else {
                return nil
            }
            return (blockID, block)
        }
        guard !viewBlocks.isEmpty else { return }

        var rowsByQuery: [String: [String]] = [:]
        for (blockID, block) in viewBlocks {
            guard let collectionID = NotionRecordMap.collectionID(from: block) else {
                continue
            }
            guard let viewID = block["view_ids"].array.compactMap(\.string).first else {
                continue
            }

            let queryKey = "\(collectionID):\(viewID)"
            if let cached = rowsByQuery[queryKey] {
                store.collectionRowIDs[blockID] = cached
                continue
            }

            guard let rowIDs = await queryCollectionRows(
                collectionID: collectionID,
                viewID: viewID,
                view: store.collectionViews[viewID],
                spaceID: store.spaceID ?? block["space_id"].string,
                apiBase: apiBase,
                store: &store
            ) else {
                continue
            }
            rowsByQuery[queryKey] = rowIDs
            store.collectionRowIDs[blockID] = rowIDs
        }

        await fetchCollectionUsers(into: &store, apiBase: apiBase)
    }

    private func fetchCollectionUsers(
        into store: inout NotionRecordMap,
        apiBase: String
    ) async {
        let rowBlocks = store.collectionRowIDs.values.flatMap { rowIDs in
            rowIDs.compactMap { store.blocks[$0] }
        }
        let missing = NotionRecordMap.userIDs(in: rowBlocks).filter { store.users[$0] == nil }
        guard !missing.isEmpty else { return }

        var seen = Set<String>()
        let urls = [
            "\(apiBase)/getRecordValues",
            "https://www.notion.so/api/v3/getRecordValues",
        ].filter { seen.insert($0).inserted }.compactMap(URL.init(string:))

        var start = 0
        while start < missing.count {
            let batch = Array(missing[start..<min(start + 100, missing.count)])
            let payload: JSONValue = [
                "requests": .array(batch.map { id in
                    ["table": "notion_user", "id": .string(id)]
                }),
            ]
            var loaded = false
            for url in urls {
                do {
                    let response = try await postJSON(
                        url: url,
                        body: payload,
                        maxRetries: 1,
                        timeout: 8
                    )
                    store.ingest(response["recordMapWithRoles"])
                    store.ingest(response["recordMap"])
                    for result in response["results"].array {
                        let user = result["value"]
                        if let id = user["id"].string, !user.isNull {
                            store.users[id] = user
                        }
                    }
                    loaded = true
                    break
                } catch {
                    continue
                }
            }
            if !loaded {
                break
            }
            start += 100
        }
    }

    private func queryCollectionRows(
        collectionID: String,
        viewID: String,
        view: JSONValue?,
        spaceID: String?,
        apiBase: String,
        store: inout NotionRecordMap
    ) async -> [String]? {
        var limit = min(max(configuration.collectionRowLimit, 1), 1000)
        var lastIDs: [String]?
        var extraHeaders: [String: String] = [:]
        if let spaceID {
            extraHeaders["x-notion-space-id"] = spaceID
        }

        for _ in 0..<4 {
            var collectionPointer: [String: JSONValue] = ["id": .string(collectionID)]
            var viewPointer: [String: JSONValue] = ["id": .string(viewID)]
            if let spaceID {
                collectionPointer["spaceId"] = .string(spaceID)
                viewPointer["spaceId"] = .string(spaceID)
            }

            var loader: [String: JSONValue] = [
                "type": "reducer",
                "reducers": [
                    "collection_group_results": [
                        "type": "results",
                        "limit": .number(Double(limit)),
                        "loadContentCover": true,
                    ],
                ],
                "searchQuery": "",
                "userTimeZone": "America/New_York",
            ]
            if let view {
                let sort = view["query2"]["sort"]
                if !sort.isNull {
                    loader["sort"] = sort
                }
                let filter = view["query2"]["filter"]
                if !filter.isNull {
                    loader["filter"] = filter
                }
            }

            let payload: JSONValue = [
                "collection": .object(collectionPointer),
                "collectionView": .object(viewPointer),
                "source": [
                    "type": "collection",
                    "id": .string(collectionID),
                ],
                "loader": .object(loader),
            ]

            guard let response = await postCollectionQuery(
                apiBase: apiBase,
                body: payload,
                extraHeaders: extraHeaders
            ) else {
                return lastIDs
            }

            store.ingest(response["recordMap"])
            let group = response["result"]["reducerResults"]["collection_group_results"]
            let ids = group["blockIds"].array.compactMap(\.string)
            lastIDs = ids
            if group["hasMore"].bool == true, limit < 1000 {
                limit = min(max(limit * 5, limit + 1), 1000)
                continue
            }
            return ids
        }
        return lastIDs
    }

    private func postCollectionQuery(
        apiBase: String,
        body: JSONValue,
        extraHeaders: [String: String]
    ) async -> JSONValue? {
        var seen = Set<String>()
        let urls = [
            "\(apiBase)/queryCollection?src=initial_load",
            "https://www.notion.so/api/v3/queryCollection?src=initial_load",
            "https://app.notion.com/api/v3/queryCollection?src=initial_load",
        ].filter { seen.insert($0).inserted }.compactMap(URL.init(string:))

        for url in urls {
            do {
                return try await postJSON(
                    url: url,
                    body: body,
                    maxRetries: 2,
                    timeout: 20,
                    extraHeaders: extraHeaders
                )
            } catch {
                continue
            }
        }
        return nil
    }

    /// Toggle children are best-effort. Cloudflare often rate-limits
    /// `www.notion.so/syncRecordValues`, so a failure here must not
    /// discard a page that `loadCachedPageChunkV2` already returned.
    private func postLazyBlocks(urls: [URL], body: JSONValue) async -> JSONValue? {
        for url in urls {
            do {
                return try await postJSON(
                    url: url,
                    body: body,
                    maxRetries: 1,
                    timeout: 8
                )
            } catch {
                continue
            }
        }
        return nil
    }
}
