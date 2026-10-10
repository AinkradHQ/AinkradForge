import AinkradAppKit
import SwiftUI

/// The app's window. Built from kit components, so it follows the host's skin
/// and typography; it reads `store`, so the "Show greeting" toggle on the
/// settings page shows and hides the greeting live.
struct RootView: View {
    let store: SettingsStore
    let theme: HostTheme

    var body: some View {
        Group {
            if store.showGreeting {
                AinkradEmptyState(
                    icon: ForgeApp.icon,
                    title: "Hello from \(ForgeApp.displayName)",
                    message: "Start building in Sources/ForgeFeature.")
            } else {
                AinkradCaption("Greeting hidden. Turn it back on in Settings.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.tokens.background)
    }
}
