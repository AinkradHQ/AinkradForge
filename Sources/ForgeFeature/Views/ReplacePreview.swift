import AinkradAppKit
import SwiftUI

/// The editor area while a replace is being previewed (mockup 08): a tab "SidebarRow.swift ↔ Replace preview" and
/// a pane with the breadcrumb "Replace preview › SidebarRow.swift › 2 changes" over that file's changes, drawn like
/// the editor — line numbers, syntax colours, full-row washes, unchanged lines folded, hunks running on without
/// their box, each with its ✓ Keep / ↶ Undo tick (an unticked hunk is left as is). Nothing is written until ⇄ or Replace All. The tab's ✕ closes the preview.
struct ReplacePreview: View {
    let model: ForgeModel
    let path: String
    @State private var plan: ReplacePlan?
    @State private var diffWidth: CGFloat?
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme

    var body: some View {
        @Bindable var search = model.search
        let name = (path as NSString).lastPathComponent
        VStack(spacing: 0) {
            HStack(spacing: skin.size.s2) {
                EditorTab(
                    name: name, title: "\(name) ↔ Replace preview", isActive: true, isPreview: false, isDirty: false,
                    onSelect: {}, onDoubleClick: {}, onClose: { search.previewPath = nil }
                )
                .help("\(path) — nothing is written until you replace")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, skin.size.s14)
            .padding(.top, skin.size.s12)
            .frame(height: skin.size.s44, alignment: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                AinkradBreadcrumb(items: ["Replace preview", name, changes])
                    .segmentColors { $0 == 1 ? theme.foreground : nil }
                    .textSeparators()
                    .preservesCase()
                    .icon(at: 1) { FileGlyph(name: name) }
                    .lineLimit(1)
                    .padding(.horizontal, skin.size.s14)
                    .padding(.top, skin.size.s8)
                    .padding(.bottom, skin.size.s4)
                Group {
                    if let diff = plan?.diff {
                        ScrollView {
                            AinkradDiffReview(
                                fileDiff: diff,
                                rejectedHunkIDs: Binding(
                                    get: { plan?.rejected(search.rejected[path]) ?? [] },
                                    set: { search.rejected[path] = plan?.unticked($0) })
                            )
                            .hidesHeader()
                            .previewHunks(diff, width: diffWidth, skin: skin)
                            .lineMetrics(fontSize: 12.5, rowHeight: 20)
                            .editorLines()
                            .syntaxColoured()
                            .lineNumberGutter()
                            .unchangedLineFolds()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { diffWidth = $0 }
                            .padding(.vertical, skin.size.s4)
                            .padding(.trailing, skin.size.s14)
                        }
                    } else if plan != nil {
                        AinkradEmptyState(
                            icon: "doc.text", title: "Too long to preview",
                            message: "This file has more than \(ReplacePlan.previewLineLimit) lines. ⇄ on its row still replaces in it.")
                    } else {
                        AinkradLoadingState(label: "Preparing the preview…")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0, bottomLeadingRadius: skin.size.s10, bottomTrailingRadius: skin.size.s10,
                    topTrailingRadius: skin.size.s10
                )
                .fill(theme.surface.opacity(skin.opacity.o45))
            )
            .padding(.horizontal, skin.size.s14)
        }
        // Recomputed only when the file, query or replacement changes — the diff is real work on long files.
        .task(id: "\(path)\u{0}\(search.query.text)\u{0}\(search.replacement)\u{0}\(search.preserveCase)\u{0}\(search.query.regex)") {
            plan = model.replacePlan(for: path)
        }
    }

    /// "2 changes", or what is left of them once some are unticked.
    private var changes: String {
        guard let plan else { return " " }
        let hunks = plan.diff?.hunks.count ?? 0
        let rejected = plan.rejected(model.search.rejected[path]).count
        let text = hunks == 0 ? "\(plan.count) match\(plan.count == 1 ? "" : "es")" : "\(hunks) change\(hunks == 1 ? "" : "s")"
        return text + (rejected > 0 ? " · \(rejected) left as is" : "")
    }
}
