import AinkradAppKit
import SwiftUI

/// F2's field on the symbol: the new name, and how far it reaches. ↵ previews, ⇧↵ renames now, Esc cancels.
struct RenameField: View {
    let model: ForgeModel
    let state: RenameState
    @FocusState private var focused: Bool
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    /// `.renamebox`: a slim mono field (`.sfield`) over a faint hint, 330 pt with the card's 8 pt inset.
    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s6) {
            TextField(state.original, text: Binding(get: { model.rename?.newName ?? "" }, set: { model.rename?.newName = $0 }))  // design-lint: allow raw-control the mockup's slim field
                .textFieldStyle(.plain)
                .font(skin.font(AinkradFontToken(sizeKey: "t12", mono: "family")))
                .foregroundStyle(theme.foreground)
                .tint(theme.accentSecondary)
                .padding(.vertical, skin.size.s6)
                .padding(.leading, skin.size.s10)
                .padding(.trailing, skin.size.s8)
                .modifier(FieldSurface())
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    model.commitRename(preview: !press.modifiers.contains(.shift))
                    return .handled
                }
                .onExitCommand { model.rename = nil }
            Text(hint)
                .font(skin.font(AinkradFontToken(sizeKey: "t10_5")))
                .foregroundStyle(skin.color(skin.text.faint))
                .padding(.horizontal, skin.size.s4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: skin.size.s300 + skin.size.s14)
        .onAppear { DispatchQueue.main.async { focused = true } }  // see Palette's onAppear (E0 FD16)
    }

    private var hint: String {
        let reach = state.places.map { places in
            " — \(places) place\(places == 1 ? "" : "s") in \(state.files ?? 1) file\((state.files ?? 1) == 1 ? "" : "s")"
        } ?? ""
        return "Rename ‘\(state.original)’\(reach) · ↵ preview · ⇧↵ rename now · Esc"
    }
}

/// `.sfield.cut`: Neon's chamfered field on `--fill-strong` with the cyan stroke; a glass capsule under Glass.
struct FieldSurface: ViewModifier {
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    func body(content: Content) -> some View {
        if #available(macOS 26, *), skin.usesNativeGlass {
            content.glassEffect(.regular, in: .capsule)
        } else {
            let shape = skin.shape(cut: skin.cut.c8)
            content
                .background(shape.fill(ForgeStyle.fillStrong(skin, theme)))
                .overlay(shape.strokeBorder(ForgeStyle.stroke(skin, theme), lineWidth: skin.size.s1))
        }
    }
}

/// A rename waiting for review: every file's changes as editor-style diffs (line numbers, change bars, washes,
/// syntax colour, folded unchanged lines), each hunk untickable, nothing made until Apply — on the editor's surface.
struct EditPreview: View {
    let model: ForgeModel
    let pending: PendingEdit
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s12) {
            HStack(spacing: skin.size.s10) {
                VStack(alignment: .leading, spacing: skin.size.s2) {
                    Text(pending.title)
                        .font(skin.font(AinkradFontToken(sizeKey: "t14", weight: "semibold")))
                    Text(subtitle)
                        .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                        .foregroundStyle(skin.color(skin.text.muted))
                }
                Spacer(minLength: skin.size.s8)
                AinkradButton(title: "Cancel", style: .ghost) { model.pendingEdit = nil }.borderless().secondaryAccent().fixedSize()
                AinkradButton(title: "Apply", style: .primary) { model.applyPendingEdit() }.fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: skin.size.s12) {
                    ForEach(pending.plans, id: \.path) { plan in
                        VStack(alignment: .leading, spacing: skin.size.s6) {
                            fileRow(plan.path, count: pending.changes[plan.path]?.count ?? 0)
                            if let diff = plan.diff {
                                AinkradDiffReview(
                                    fileDiff: diff,
                                    rejectedHunkIDs: Binding(
                                        get: { model.pendingEdit?.rejected[plan.path] ?? [] },
                                        set: { model.pendingEdit?.rejected[plan.path] = $0 })
                                )
                                .hidesHeader()
                                .bareHunks(untickable: true)
                                .lineMetrics(fontSize: 12.5, rowHeight: 20)
                                .editorLines()
                                .syntaxColoured()
                                .lineNumberGutter()
                                .unchangedLineFolds()
                            } else {
                                Text("\(plan.path) is too long to preview — it changes as a whole.")
                                    .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                                    .foregroundStyle(skin.color(skin.text.faint))
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(skin.size.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: skin.usesNativeGlass ? skin.size.s10 : 0).fill(ForgeStyle.pane(skin, theme)))
        .padding(.horizontal, skin.size.s14)
    }

    /// `.rv .file`: `◆ SidebarBadge.swift  Sources/…  2 changes`.
    private func fileRow(_ path: String, count: Int) -> some View {
        HStack(spacing: skin.size.s8) {
            FileGlyph(name: (path as NSString).lastPathComponent)
            Text((path as NSString).lastPathComponent)
                .font(skin.font(AinkradFontToken(sizeKey: "t12")))
                .foregroundStyle(theme.foreground)
            Text((path as NSString).deletingLastPathComponent)
                .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "family")))
                .foregroundStyle(skin.color(skin.text.faint))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: skin.size.s8)
            Text("\(count) change\(count == 1 ? "" : "s")")
                .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "family")))
                .foregroundStyle(skin.color(skin.text.muted))
        }
    }

    private var subtitle: String {
        let places = pending.changes.values.reduce(0) { $0 + $1.count }
        let unticked = pending.rejected.values.reduce(0) { $0 + $1.count }
        return "\(places) place\(places == 1 ? "" : "s") in \(pending.plans.count) file\(pending.plans.count == 1 ? "" : "s")"
            + (unticked > 0 ? " · \(unticked) hunk\(unticked == 1 ? "" : "s") left as they are" : "")
    }
}
