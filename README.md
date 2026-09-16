# NotionSiteFetch

[breitburg/notion-site-fetch](https://github.com/breitburg/notion-site-fetch) 의 Swift 포팅입니다. 공개 Notion 페이지를 토큰·로그인·헤드리스 브라우저 없이 Markdown으로 가져옵니다. Notion 웹 클라이언트가 쓰는 공개 HTTPS 엔드포인트만 호출합니다.

익명 브라우저 탭에서 열리는 페이지라면 이 패키지로 읽을 수 있습니다.

## Swift Package Dependency

Xcode: **File → Add Package Dependencies…** 에 아래 URL을 넣고 제품을 `NotionSiteFetch` 로 선택합니다. Dependency Rule은 **Up to Next Major** `1.0.0` 입니다.

```
https://github.com/bloooi/NotionSiteFetch.git
```

`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/bloooi/NotionSiteFetch.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "NotionSiteFetch", package: "NotionSiteFetch"),
        ]
    ),
]
```

로컬 경로로 붙일 때:

```swift
.package(path: "../NotionSiteFetch")
```

## 사용법

```swift
import NotionSiteFetch

let page = try await NotionSiteFetcher().fetchPage(
    from: "https://example.notion.site/"
)
print(page.markdown)
print(page.rootPageID, page.blocks.count)
print(page.collectionRowIDs)
```

문자열 또는 `URL` 모두 받을 수 있습니다. `fetchMarkdown(from:)` 은 Markdown만 반환합니다.

테스트에서 HTTP를 가로채려면 `NotionHTTPClient` 를 구현해 `NotionSiteFetcher(client:)` 에 넘기면 됩니다. 재시도는 원본과 같이 최대 8회, 5xx/전송 오류에 백오프합니다.

### 받는 URL 형태

| URL | 동작 |
| --- | --- |
| `https://<sub>.notion.site/` | 사이트의 공개 홈 페이지 |
| `https://<sub>.notion.site/<slug-or-id>` | 공개 사이트의 특정 페이지 |
| `https://www.notion.so/<...>-<32-char-page-id>` | notion.so 페이지 URL |
| `https://app.notion.com/p/<space>/<page-id>?v=<view-id>` | 게시된 페이지/데이터베이스. `v` 가 있으면 그 뷰의 행을 가져옵니다 |

경로 끝에 32자리 페이지 id가 있으면 호스트와 관계없이 그 id를 \uc501\ub2c8\ub2e4.

## CLI

```sh
swift run notion-site-fetch 'https://example.notion.site/' > page.md
```

도움말: `swift run notion-site-fetch --help`

## 테스트

```sh
swift test
```

단위 테스트는 URL 해석, 리치 텍스트/블록 렌더, 청크 페이지네이션, 토글 자식 `syncRecordValues`, 데이터베이스 `queryCollection`, 502 재시도, 공개 홈 없음/루트 블록 없음 오류를 커버합니다.

실제 네트워크 확인:

```sh
NOTION_SITE_FETCH_LIVE=1 swift test --filter LiveFetchTests
```

기본 URL은 공개 예제 페이지입니다. `NOTION_SITE_FETCH_LIVE_URL` 로 바꿀 수 있습니다. 토글 자식을 채우는 `syncRecordValues` 가 429/타임아웃이어도, 이미 받은 청크는 Markdown으로 남깁니다.

## Xcode Playground

Xcode에서 `Fetch.playground` 나 `Contents.swift` 만 열면 `No such module 'NotionSiteFetch'` 가 납니다. Playground는 혼자서는 SPM 모듈을 import하지 못합니다.

**`Examples/XcodePlayground/NotionSiteFetch.xcworkspace` 를 여세요.**

1. 스킴을 **Host** 로 둡니다.
2. `Fetch.playground` 를 \uc5fd\ub2c8\ub2e4.
3. Run (`⌥⌘↩`) 합니다.

Host 커맨드라인 타깃이 로컬 패키지를 링크하고, Playground의 `buildActiveScheme` 이 그 모듈을 사용합니다. 자세한 내용은 [`Examples/XcodePlayground/README.md`](Examples/XcodePlayground/README.md) 입니다.

터미널에서 확인할 때는 `swift run notion-site-fetch '<url>'` 를 쓰면 됩니다.

## 동작

원본 Python 도구와 같은 경로입니다.

1. `POST /api/v3/getPublicPageData` — `*.notion.site` 서브도메인을 `spaceId` 로
2. `POST /api/v3/getPublicSpaceData` — 공개 홈 페이지 블록 id
3. `POST /api/v3/loadCachedPageChunkV2` — 커서 페이지네이션으로 블록 수집
4. `POST https://www.notion.so/api/v3/syncRecordValues` — 청크에 빠진 토글 자식
5. `POST /api/v3/queryCollection` — 데이터베이스/컬렉션 뷰 행 (`collection_view`, `collection_view_page`)

가능하면 `*.notion.site` 호스트로 호출해 `www.notion.so` 의 cross-cell 오류를 피합니다.

렌더 대상: H1–H4, 문단, 굵게/기울임/취소선/인라인 코드, 링크, 중첩 불릿/번호/할 일/토글, 인용, 콜아웃, 구분선, 코드 블록, 이미지, 북마크/비디오/파일/PDF/오디오 링크, 수식, Notion 단순 표(`table` / `table_row`), 데이터베이스 뷰 행(표/보드/리스트 등 — 기본 뷰의 보이는 속성을 Markdown 표로).

의도적으로 건너뛰거나 단순화하는 것: 목차·브레드크럼, 컬럼 레이아웃(자식은 펼침). 비공개 데이터베이스이거나 `queryCollection`이 실패하면 뷰 제목만 남깁니다. 페이지 안의 단순 표와 공개 데이터베이스 뷰는 Markdown 표로 출력합니다.

요청한 페이지만 가져옵니다. 하위 페이지는 링크로 남습니다.

## 요구 사항

- Swift 5.10+ / Xcode 15.4+
- macOS 13+, iOS 16+, 또는 Linux(Swift.org 툴체인)
- 외부 Swift 패키지 의존성 없음. 라이브러리는 `URLSession` 만 사용합니다.

## 라이선스

[MIT](LICENSE). 원본 [notion-site-fetch](https://github.com/breitburg/notion-site-fetch) 도 MIT이며, 이 포팅은 그 구현을 Swift로 옮긴 것입니다.
