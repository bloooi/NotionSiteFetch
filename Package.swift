// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NotionSiteFetch",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "NotionSiteFetch", targets: ["NotionSiteFetch"]),
        .executable(name: "notion-site-fetch", targets: ["NotionSiteFetchCLI"]),
        .executable(name: "notion-site-fetch-playground", targets: ["NotionSiteFetchPlayground"]),
    ],
    targets: [
        .target(name: "NotionSiteFetch"),
        .executableTarget(
            name: "NotionSiteFetchCLI",
            dependencies: ["NotionSiteFetch"]
        ),
        .executableTarget(
            name: "NotionSiteFetchPlayground",
            dependencies: ["NotionSiteFetch"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "NotionSiteFetchTests",
            dependencies: ["NotionSiteFetch"]
        ),
    ]
)
