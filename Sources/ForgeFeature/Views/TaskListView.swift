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
                    alignment: .leading, spacing: skin.size.s8
                ) {
                    ForEach(groups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: skin.size.s2) {
                            AinkradCaption(group.name)
                                .padding(.horizontal, skin.size.s6)
                                .padding(.bottom, skin.size.s2)
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

    private var isRunning: Bool { model.tasks.running[task.id] != nil }

    var body: some View {
        HStack(spacing: skin.size.s8) {
            AinkradIconButton(
                systemName: isRunning ? "stop.fill" : "play.fill", size: skin.size.s18,
                tooltip: isRunning ? "Stop" : "Run \(task.shows)"
            ) {
                if isRunning { model.tasks.stop(task, in: model.terminals) } else { model.runTask(task) }
            }
            Text(task.name)
                .font(skin.font(AinkradFontToken(sizeKey: "t12", mono: "system")))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .frame(minWidth: skin.size.s96, alignment: .leading)
            Text(task.shows)
                .font(skin.font(AinkradFontToken(sizeKey: "t11", mono: "system")))
                .foregroundStyle(skin.color(skin.text.faint))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: skin.size.s8)
            outcome
        }
        .padding(.vertical, skin.size.s3)
        .padding(.horizontal, skin.size.s6)
        .ainkradRowBackground(isSelected: false, isHovered: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { model.runTask(task) }
        .help(task.command)
    }

    @ViewBuilder private var outcome: some View {
        let font = skin.font(AinkradFontToken(sizeKey: "t11", monospacedDigits: true))
        if isRunning {
            Text("running").font(font).foregroundStyle(skin.color(skin.text.muted))
        } else if let result = model.tasks.results[task.id] {
            let when = result.at.formatted(.relative(presentation: .named))
            Text(result.succeeded ? "✓ \(result.seconds) s · \(when)" : "✗ exit \(result.exitCode.map(String.init) ?? "?") · \(when)")
                .font(font)
                .foregroundStyle(result.succeeded ? status.success : status.danger)
        }
    }
}
