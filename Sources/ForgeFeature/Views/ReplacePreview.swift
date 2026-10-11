import AinkradAppKit
import SwiftUI

/// The editor area while a replace is being previewed: that file's changes as a diff, each hunk untickable,
/// nothing written until Replace in File (or Replace All). Built on the kit's diff review.
struct ReplacePreview: View {
    let model: ForgeModel
    let path: String
    @State private var plan: ReplacePlan?
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        @Bindable var search = model.search
        VStack(alignment: .leading, spacing: skin.size.s10) {
            HStack(spacing: skin.size.s8) {
                VStack(alignment: .leading, spacing: skin.size.s2) {
                    Text("Replace preview · \((path as NSString).lastPathComponent)")
                        .font(skin.font(AinkradFontToken(sizeKey: "t14", weight: "semibold")))
                    Text(subtitle)
                        .font(skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true)))
                        .foregroundStyle(skin.color(skin.text.muted))
                }
                Spacer(minLength: skin.size.s8)
                AinkradButton(title: "Close Preview", style: .ghost) { search.previewPath = nil }.fixedSize()
                AinkradButton(title: "Replace in File", style: .primary) { model.replace(in: path) }
                    .fixedSize()
                    .disabled((plan?.count ?? 0) == 0)
            }
            Group {
                if let diff = plan?.diff {
                    ScrollView {
                        AinkradDiffReview(
                            fileDiff: diff,
                            rejectedHunkIDs: Binding(get: { search.rejected[path] ?? [] }, set: { search.rejected[path] = $0 }))
                    }
                } else if plan != nil {
                    AinkradEmptyState(
                        icon: "doc.text", title: "Too long to preview",
                        message: "This file has more than \(ReplacePlan.previewLineLimit) lines. Replace in File still works.")
                } else {
                    AinkradLoadingState(label: "Preparing the preview…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(skin.size.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: skin.size.s10).fill(theme.surface.opacity(skin.opacity.o45)))
        .padding(.horizontal, skin.size.s14)
        .padding(.top, skin.size.s12)
        // Recomputed only when the file, query or replacement changes — the diff is real work on long files.
        .task(id: "\(path)\u{0}\(search.query.text)\u{0}\(search.replacement)\u{0}\(search.preserveCase)\u{0}\(search.query.regex)") {
            plan = model.replacePlan(for: path)
        }
    }

    private var subtitle: String {
        guard let plan else { return " " }
        let rejected = model.search.rejected[path]?.count ?? 0
        let hunks = plan.diff?.hunks.count ?? 0
        return "\(plan.count) match\(plan.count == 1 ? "" : "es")"
            + (hunks > 0 ? " in \(hunks) change\(hunks == 1 ? "" : "s")" : "")
            + (rejected > 0 ? " · \(rejected) left as is" : "") + " · nothing is written until you replace"
    }
}
