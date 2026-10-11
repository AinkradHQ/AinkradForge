// swift-tools-version: 6.0
import PackageDescription

/// Language servers behind Forge's own types. LanguageClient pulls in C modules (swift-glob's FNMDefinitions)
/// that Xcode cannot resolve from the app project, so — like ForgeEditor — the package is resilient and
/// imports them `internal`ly; ForgeFeature sees only Issue, ServerStatus, LanguageHub and friends.
let package = Package(
    name: "ForgeLanguage",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ForgeLanguage", targets: ["ForgeLanguage"])],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/LanguageClient", exact: "0.8.2"),
    ],
    targets: [
        .target(
            name: "ForgeLanguage",
            dependencies: [.product(name: "LanguageClient", package: "LanguageClient")],
            swiftSettings: [.unsafeFlags(["-enable-library-evolution"])]),
        .testTarget(name: "ForgeLanguageTests", dependencies: ["ForgeLanguage"]),
    ]
)
