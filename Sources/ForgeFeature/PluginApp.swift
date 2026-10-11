import AinkradAppKit
import SwiftUI

/// Forge: a native code editor — workspaces, LSP, terminal and agent review. Read theme via
/// `host.theme.tokens` and persist via `host.documents` — never host internals.
public struct ForgeApp: AinkradApp, AinkradAppTeardown {
    public static let id = "forge"
    public static let displayName = "Forge"
    public static let icon = "hammer"

    /// One model per host-minted instance, so every open window of that instance shares the workspace,
    /// and `teardown` can drop it.
    private static let models = PluginInstanceStorage<ForgeModel>()

    /// The instance a host stands for. A host that does not identify itself
    /// (see `PluginInstanceIdentity`) gets one id minted per process.
    private static let fallbackInstance = PluginInstanceID()

    private static func model(host: HostServices) -> ForgeModel {
        let instance = (host as? PluginInstanceIdentity)?.instanceID ?? fallbackInstance
        return models.value(for: instance) { ForgeModel(store: ForgeStore(documents: host.documents), apps: host.apps) }
    }

    public static func teardown(instance: PluginInstanceID) {
        models.remove(instance)
    }

    public static func makeRootView(host: HostServices) -> AnyView {
        AnyView(RootView(model: model(host: host), theme: host.theme) { host.apps.takePendingLaunch() })
    }

    public static func makeSettingsView(host: HostServices) -> AnyView {
        AnyView(AinkradCaption("Editor settings (font, tab width, wrapping) arrive with E3."))
    }
}
