# Xcode Playground

에러가 났다면 다른 Xcode 창이 같은 Playground/패키지를 연 상태입니다. 아래 순서대로 다시 여세요.

1. Xcode에서 **File → Close Workspace** 로 열린 창을 모두 닫습니다. 여러 창이 있으면 전부 닫습니다.
2. `Package.swift` 와 `Fetch.playground` 는 열지 않습니다.
3. **File → Open…** 에서 이것만 엽니다.

```
Examples/XcodePlayground/NotionSiteFetch.xcworkspace
```

4. 스킴은 **Host** 하나면 됩니다. **My Mac**.
5. 왼쪽에서 `Fetch.playground` 를 열고 Run (`⌥⌘↩`).

이전에 보이던 `Host (Host project)` / `Host (NotionSiteFetch Workspace)` 두 개는 지웠습니다. Playground도 워크스페이스에만 있습니다.

`Couldn't load Fetch.playground because it is already opened` 는 `Package.swift` 를 같이 열었을 때 납니다.  
`Missing package product 'NotionSiteFetch'` 는 로컬 패키지 경로가 어긋났을 때 났고, 지금은 `Package.swift` 가 있는 저장소 루트를 가리킵니다.
