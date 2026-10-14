// swift-tools-version: 6.0
import PackageDescription

/// The editor engine behind one small API. CodeEdit is imported `internal`ly here, so ForgeFeature never sees
/// its types — and Xcode never has to scan its C modules (CodeEditTextViewObjC, TreeSitter), which it cannot
/// resolve from a static-library target. Swapping the engine (E1's CodeMirror fallback) stays local to this package.
let package = Package(
    name: "ForgeEditor",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ForgeEditor", targets: ["ForgeEditor"])],
    dependencies: [
        // Forge's forks — E1 spike fixes; see Docs/Plans/2026-10-10-forge-plan.md.
        .package(url: "https://github.com/AhmedMElhalaby/CodeEditSourceEditor", exact: "0.15.2-forge.14"),
        .package(url: "https://github.com/AhmedMElhalaby/CodeEditTextView", exact: "0.12.1-forge.5"),
        // History-free snapshot; upstream's history is >2.5 GB.
        .package(url: "https://github.com/AhmedMElhalaby/CodeEditLanguages", exact: "0.1.20-forge.4"),
    ],
    targets: [
        .target(
            name: "ForgeEditor",
            dependencies: [
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
                .product(name: "CodeEditTextView", package: "CodeEditTextView"),
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
            ],
            // Resilient, so clients do not load its `internal import`s (CodeEdit's C modules) at all.
            swiftSettings: [.unsafeFlags(["-enable-library-evolution"])]),
        .testTarget(
            name: "ForgeEditorTests",
            dependencies: [
                "ForgeEditor", .product(name: "CodeEditTextView", package: "CodeEditTextView"),
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
            ]),
    ]
)
