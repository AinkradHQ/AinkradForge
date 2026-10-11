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
        AnyView(AinkradCaption("Forge's settings are on its settings page."))
    }

    /// Editor settings as real descriptors: searchable and laid out with every other setting.
    public static func settingsCatalog(host: HostServices) -> SettingsPage? {
        let model = model(host: host)
        let root = SettingsPath(["app", id])
        let editor = root.appending("editor")
        let defaults = EditorSettings()
        func toggle(_ key: String, _ label: String, _ help: String, _ keyPath: WritableKeyPath<EditorSettings, Bool>)
            -> SettingsField
        {
            SettingsField(
                path: editor.appending(key), label: label, help: help, keywords: [key],
                kind: .toggle(Binding(get: { model.editorSettings[keyPath: keyPath] }, set: { model.editorSettings[keyPath: keyPath] = $0 })),
                defaultDescription: defaults[keyPath: keyPath] ? "On" : "Off",
                isModified: { model.editorSettings[keyPath: keyPath] != defaults[keyPath: keyPath] },
                reset: { model.editorSettings[keyPath: keyPath] = defaults[keyPath: keyPath] })
        }
        return SettingsPage(
            path: root, title: displayName, icon: icon, group: .installedApps, order: 0,
            groups: [
                SettingsGroup(
                    path: editor, title: "Editor",
                    fields: [
                        SettingsField(
                            path: editor.appending("fontSize"), label: "Font size", help: "The editor's text size, in points.",
                            keywords: ["font", "size", "zoom"],
                            kind: .slider(
                                range: 9...28, step: 1,
                                value: Binding(get: { model.editorSettings.fontSize }, set: { model.editorSettings.fontSize = $0 })),
                            defaultDescription: "\(Int(defaults.fontSize)) pt",
                            isModified: { model.editorSettings.fontSize != defaults.fontSize },
                            reset: { model.editorSettings.fontSize = defaults.fontSize }),
                        SettingsField(
                            path: editor.appending("tabWidth"), label: "Tab width",
                            help: "How many columns a tab takes, and how many spaces Tab inserts.",
                            keywords: ["tab", "indent", "width", "spaces"],
                            kind: .select(
                                options: [2, 4, 8].map { SettingsOption(id: String($0), title: "\($0)") },
                                selection: Binding(
                                    get: { String(model.editorSettings.tabWidth) },
                                    set: { model.editorSettings.tabWidth = Int($0) ?? defaults.tabWidth })),
                            defaultDescription: "\(defaults.tabWidth)",
                            isModified: { model.editorSettings.tabWidth != defaults.tabWidth },
                            reset: { model.editorSettings.tabWidth = defaults.tabWidth }),
                        toggle("insertSpaces", "Insert spaces", "Tab inserts spaces instead of a tab character.", \.insertSpaces),
                        toggle("wrapLines", "Wrap lines", "Long lines wrap at the editor's edge instead of scrolling.", \.wrapLines),
                        toggle("showMinimap", "Show minimap", "A miniature of the file beside the editor.", \.showMinimap),
                        toggle("showInvisibles", "Show invisibles", "Draw spaces and tabs as faint marks.", \.showInvisibles),
                    ])
            ],
            appID: id)
    }
}
