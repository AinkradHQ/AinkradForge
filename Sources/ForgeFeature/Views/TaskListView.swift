import AinkradAppKit
import SwiftUI

/// The drawer's Tasks tab: what the workspace can run, by where it came from, in two columns; each row runs
/// (or stops) its task and keeps how it last went.
struct TaskListView: View {
    let model: ForgeModel
    @Environment(\.ainkradSkin) private var skin

    private var groups: [(name: String, tasks: [WorkspaceTask])] {
        var order: [String] = []
        var byGroup: [String: [WorkspaceTask]] = [:]
        for task in model.tasks.tasks {
            if byGroup[task.group] == nil { order.append(task.group) }
            byGroup[task.group, default: []].append(task)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    var body: some View {
        if model.tasks.tasks.isEmpty {
            AinkradEmptyState(
                icon: "play", title: "No tasks found",
                message: "Forge lists Makefile targets, package.json scripts and composer.json scripts in this workspace.")
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: skin.size.s18, alignment: .top), GridItem(.flexible(), alignment: .top)],
                    alignment: .leading, spacing: 0
                ) {
                    ForEach(groups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            // `.tasks .grp`: always uppercase, faint 10.5 pt, tracked under Neon.
                            Text(group.name.uppercased())
                                .font(skin.font(AinkradFontToken(sizeKey: "t10_5")))
                                .tracking(skin.usesNativeGlass ? 0 : skin.size.s10 * 0.08)
                                .foregroundStyle(skin.color(skin.text.faint))
                                .padding(.top, skin.size.s8)
                                .padding(.horizontal, skin.size.s6)
                                .padding(.bottom, skin.size.s4)
                            ForEach(group.tasks) { task in TaskRow(model: model, task: task) }
                        }
                    }
                }
                .padding(.horizontal, skin.size.s4)
            }
            .scrollIndicators(.never)
        }
    }
}

private struct TaskRow: View {
    let model: ForgeModel
    let task: WorkspaceTask
    @State private var isHovered = false
    @Environment(\.ainkradSkin) private var skin
    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradStatusColors) private var status
    @Environment(\.ainkradMotionBudget) private var budget

    private var isRunning: Bool { model.tasks.running[task.id] != nil }

    /// `.tk`: a bare cyan `▶` / `■`, the name (mono, 150 pt), the command (faint mono), how it last went.
    var body: some View {
        HStack(spacing: skin.size.s8) {
            // 16 pt keeps the row at the mockup's height; the glyph's column stays the mockup's 20.
            AinkradIconButton(systemName: isRunning ? "stop" : "play", size: skin.size.s16, tooltip: isRunning ? "Stop" : "Run \(task.shows)") {
                if isRunning { model.tasks.stop(task, in: model.terminals) } else { model.runTask(task) }
            }
            .textGlyph(isRunning ? "■" : "▶", size: skin.size.s10)
            .bare()
            .frame(width: skin.size.s20)
            Text(task.name)
                .font(skin.font(AinkradFontToken(size: 11.5, weight: "medium", mono: "family")))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                // Up to 150 pt: in a narrow drawer it gives way too, so the row never outgrows its column (FD50).
                .frame(maxWidth: skin.size.s150, alignment: .leading)
                // Ahead of the command, so the names keep one column while the commands truncate.
                .layoutPriority(1)
            Text(task.shows)
                .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "family")))
                .foregroundStyle(skin.color(skin.text.faint))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Never wraps (FD50): the command truncates instead.
            outcome
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(2)
        }
        .padding(.vertical, skin.size.s4)
        .padding(.horizontal, skin.size.s6)
        .background(
            RoundedRectangle(cornerRadius: skin.size.s6, style: .continuous)
                .fill(isHovered ? skin.color(skin.palette.white).opacity(skin.opacity.o05) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { model.runTask(task) }
        .help(task.command)
    }

    @ViewBuilder private var outcome: some View {
        let font = skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true))
        if isRunning {
            // `running · 0:18`, ticking once a second — only while the window is visible (the motion budget says
            // so); otherwise drawn once. No animation, so reduce motion has nothing to calm.
            if budget.isWindowVisible {
                TimelineView(.periodic(from: .now, by: 1)) { _ in running(font) }
            } else {
                running(font)
            }
        } else if let result = model.tasks.results[task.id] {
            let when = result.at.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
            Text(result.succeeded ? "✓ \(result.seconds) s · \(when)" : "✗ exit \(result.exitCode.map(String.init) ?? "?") · \(when)")
                .font(font)
                .foregroundStyle(result.succeeded ? status.success : status.danger)
        }
    }

    private func running(_ font: Font) -> some View {
        Text(model.tasks.elapsed(task.id).map { "running · \($0)" } ?? "running")
            .font(font)
            .foregroundStyle(skin.color(skin.text.muted))
    }
}
