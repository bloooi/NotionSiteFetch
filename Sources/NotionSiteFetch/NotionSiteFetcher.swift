import Foundation

public struct NotionFetchedPage: Sendable, Equatable {
    public var rootPageID: String
    public var spaceID: String?
    public var blocks: [String: JSONValue]
    public var markdown: String

    public init(
        rootPageID: String,
        spaceID: String?,
        blocks: [String: JSONValue],
        markdown: String
    ) {
        self.rootPageID = rootPageID
        self.spaceID = spaceID
        self.blocks = blocks
        self.markdown = markdown
    }
}

public enum FetchStage: String, Sendable, Equatable {
    case resolving
    case loadingChunks
    case loadingLazyBlocks
    case rendering
}

public struct NotionSiteFetcher: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var maxRetries: Int
        public var maxBackoffSeconds: Double
        public var requestTimeout: TimeInterval

        public static let `default` = Configuration()

        public init(
            maxRetries: Int = NotionSiteFetcher.defaultMaxRetries,
            maxBackoffSeconds: Double = NotionSiteFetcher.defaultMaxBackoffSeconds,
            requestTimeout: TimeInterval = 30
        ) {
            self.maxRetries = maxRetries
            self.maxBackoffSeconds = maxBackoffSeconds
            self.requestTimeout = requestTimeout
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
        let fetched = try await fetchAllBlocks(
            rootPageID: resolved.pageID,
            apiBase: apiBase,
            spaceID: resolved.spaceID,
            onProgress: onProgress
        )

        guard fetched.blocks[resolved.pageID] != nil else {
            throw NotionSiteFetchError.rootPageMissing(resolved.pageID)
        }

        onProgress?(.rendering)
        let markdown = NotionMarkdownRenderer.render(
            rootPageID: resolved.pageID,
            blocks: fetched.blocks
        )
        return NotionFetchedPage(
            rootPageID: resolved.pageID,
            spaceID: fetched.spaceID,
            blocks: fetched.blocks,
            markdown: markdown
        )
    }

    private func postJSON(
        url: URL,
        body: JSONValue,
        maxRetries: Int? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> JSONValue {
        try await NotionAPI.postJSON(
            client: client,
            sleeper: sleeper,
            url: url,
            body: body,
            maxRetries: maxRetries ?? configuration.maxRetries,
            maxBackoffSeconds: configuration.maxBackoffSeconds,
            timeout: timeout
        )
    }

    private func fetchAllBlocks(
        rootPageID: String,
        apiBase: String,
        spaceID: String?,
        onProgress: (@Sendable (FetchStage) -> Void)?
    ) async throws -> (blocks: [String: JSONValue], spaceID: String?) {
        var accumulatedBlocks: [String: JSONValue] = [:]
        var cursorState: JSONValue = ["stack": .array([])]
        var chunkIndex = 0
        var resolvedSpaceID = spaceID

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
            let blockRecords = chunkData["recordMap"]["block"].object
            for (blockID, blockRecord) in blockRecords {
                let blockValue = blockRecord["value"]["value"]
                if !blockValue.isNull {
                    accumulatedBlocks[blockID] = blockValue
                }
                if resolvedSpaceID == nil {
                    resolvedSpaceID = blockRecord["spaceId"].string
                        ?? (blockValue.isNull ? nil : blockValue["space_id"].string)
                }
            }

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

        guard let spaceID = resolvedSpaceID else {
            return (accumulatedBlocks, resolvedSpaceID)
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
                return (accumulatedBlocks, spaceID)
            }
            var missingBlockIDs: [String] = []
            var seen = Set<String>()
            for block in accumulatedBlocks.values {
                for childID in block["content"].array.compactMap(\.string) where accumulatedBlocks[childID] == nil {
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
                    return (accumulatedBlocks, spaceID)
                }
                for (blockID, blockRecord) in syncData["recordMap"]["block"].object {
                    let blockValue = blockRecord["value"]["value"]
                    if !blockValue.isNull {
                        accumulatedBlocks[blockID] = blockValue
                    }
                }
                if batchIDs.allSatisfy({ accumulatedBlocks[$0] == nil }) {
                    return (accumulatedBlocks, spaceID)
                }
                batchStart += 100
            }
        }

        return (accumulatedBlocks, spaceID)
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
