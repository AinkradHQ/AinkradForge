import AinkradAppKit
import SwiftUI

/// F2's field on the symbol: the new name, and how far it reaches. ↵ previews, ⇧↵ renames now, Esc cancels.
struct RenameField: View {
    let model: ForgeModel
    let state: RenameState
    @FocusState private var focused: Bool
    @Environment(\.ainkradSkin) private var skin

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s6) {
            GlassField(
                label: "rename", text: Binding(get: { model.rename?.newName ?? "" }, set: { model.rename?.newName = $0 }),
                placeholder: state.original
            )
            .focused($focused)
            .onKeyPress(.return, phases: .down) { press in
                model.commitRename(preview: !press.modifiers.contains(.shift))
                return .handled
            }
            .onExitCommand { model.rename = nil }
            Text(hint)
                .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                .foregroundStyle(skin.color(skin.text.muted))
        }
        .frame(width: skin.size.s400)
        .onAppear { focused = true }
    }

    private var hint: String {
        let reach = state.places.map { places in
            " — \(places) place\(places == 1 ? "" : "s") in \(state.files ?? 1) file\((state.files ?? 1) == 1 ? "" : "s")"
        } ?? ""
        return "‘\(state.original)’\(reach) · ↵ preview · ⇧↵ rename · Esc"
    }
}

/// A rename waiting for review: every file's changes as diffs, each hunk untickable, nothing made until Apply.
struct EditPreview: View {
    let model: ForgeModel
    let pending: PendingEdit
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: skin.size.s10) {
            HStack(spacing: skin.size.s8) {
                VStack(alignment: .leading, spacing: skin.size.s2) {
                    Text(pending.title)
                        .font(skin.font(AinkradFontToken(sizeKey: "t14", weight: "semibold")))
                    Text(subtitle)
                        .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                        .foregroundStyle(skin.color(skin.text.muted))
                }
                Spacer(minLength: skin.size.s8)
                AinkradButton(title: "Cancel", style: .ghost) { model.pendingEdit = nil }.fixedSize()
                AinkradButton(title: "Apply", style: .primary) { model.applyPendingEdit() }.fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: skin.size.s14) {
                    ForEach(pending.plans, id: \.path) { plan in
                        // The diff review heads each file with its path.
                        VStack(alignment: .leading, spacing: skin.size.s6) {
                            if let diff = plan.diff {
                                AinkradDiffReview(
                                    fileDiff: diff,
                                    rejectedHunkIDs: Binding(
                                        get: { model.pendingEdit?.rejected[plan.path] ?? [] },
                                        set: { model.pendingEdit?.rejected[plan.path] = $0 }))
                            } else {
                                Text("\(plan.path) is too long to preview — it changes as a whole.")
                                    .font(skin.font(AinkradFontToken(sizeKey: "t11")))
                                    .foregroundStyle(skin.color(skin.text.faint))
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(skin.size.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: skin.size.s10).fill(theme.surface.opacity(skin.opacity.o45)))
        .padding(.horizontal, skin.size.s14)
        .padding(.top, skin.size.s12)
    }

    private var subtitle: String {
        let places = pending.changes.values.reduce(0) { $0 + $1.count }
        let unticked = pending.rejected.values.reduce(0) { $0 + $1.count }
        return "\(places) place\(places == 1 ? "" : "s") in \(pending.plans.count) file\(pending.plans.count == 1 ? "" : "s")"
            + (unticked > 0 ? " · \(unticked) hunk\(unticked == 1 ? "" : "s") left as they are" : "")
    }
}
