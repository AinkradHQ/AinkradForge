import AinkradAppKit
import Foundation
import SwiftUI
import Testing

@testable import ForgeFeature

/// Smoke test: the root view builds from a fake host and draws (the welcome screen — no workspace yet).
@MainActor
@Suite("Root view")
struct RootViewTests {
    @Test func rendersTheWelcomeScreen() throws {
        let renderer = ImageRenderer(content: ForgeApp.makeRootView(host: FakeHost()).frame(width: 640, height: 480))
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "the root view did not render")
        let data = try #require(image.dataProvider?.data, "the rendered image has no pixels")
        #expect((data as Data).contains { $0 != 0 }, "the view drew nothing")
    }
}
