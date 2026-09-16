import NotionSiteFetch
import PlaygroundSupport

// 이 파일만 단독으로 열면 "No such module 'NotionSiteFetch'" 가 납니다.
// Xcode에서 Examples/XcodePlayground/NotionSiteFetch.xcworkspace 를 열고,
// 스킴을 Host 로 둔 다음 이 Playground를 실행하세요.

PlaygroundPage.current.needsIndefiniteExecution = true

let url = "https://sota1235.notion.site/Example-page-for-notion-sdk-js-helper-4176d72d760c40979a6a6523fa2c1165"

Task { @MainActor in
    do {
        let page = try await NotionSiteFetcher().fetchPage(from: url)
        print("root:", page.rootPageID)
        print("blocks:", page.blocks.count)
        print(page.markdown)
    } catch {
        print("error:", error)
    }
    PlaygroundPage.current.finishExecution()
}
