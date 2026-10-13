import AinkradAppKit
import AppKit
import ForgeLanguage
import Foundation

/// The review by Grimoire turn (E5): Grimoire announces each turn; Keep / Undo act on one turn's changes only, and
/// "Ask about this turn…" goes back to the same Grimoire thread.
extension ForgeModel {
    /// Listens for Grimoire's turn notices (in-process: plugins share the host). Called once, from `init`.
    func observeTurns() {
        NotificationCenter.default.addObserver(forName: AgentTurn.notification, object: nil, queue: .main) { [weak self] note in
            let payload = note.object as? String
            MainActor.assumeIsolated { self?.receive(turn: payload) }
        }
    }

    /// A turn for this workspace joins the ledger, its files made workspace-relative; any other is not ours.
    func receive(turn payload: String?) {
        guard var turn = AgentTurn.decode(payload), let workspace else { return }
        turn.files = turn.files.compactMap { Self.relative($0, to: workspace) }
        guard !turn.files.isEmpty else { return }
        agent.turns.add(turn)
    }

    static func relative(_ path: String, to workspace: Workspace) -> String? {
        let url = URL(fileURLWithPath: path)
        if let relative = workspace.relativePath(of: url) { return relative }
        // The watcher reports resolved paths (`/private/var/…`); a turn may name either form.
        let base = workspace.root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : nil
    }

    /// Files waiting for review now.
    var reviewPaths: Set<String> { Set(agent.files.keys).union(agent.others.keys) }

    /// The review by turn, newest first.
    var turnGroups: [TurnLedger.Group] { agent.turns.groups(in: reviewPaths) }

    /// The review groups by turn once Grimoire has announced one; until then it is the plain list.
    var reviewsByTurn: Bool { !agent.turns.isEmpty }

    // MARK: - Keep / undo a group

    /// Keep turn: its changes become part of what Forge has seen.
    func keep(group: TurnLedger.Group) {
        agent.turns.keep(group)
        for file in group.files {
            guard let folded = agent.turns.foldKept(file.path) else { continue }
            agent.rebase(file.path, baseline: folded.after, text: text(of: file.path))
        }
    }

    /// Undoing `group` file by file: each file's text after the undo (nil: the file goes), or no entry where a newer
    /// change touched the same lines.
    func undoPlan(_ group: TurnLedger.Group) -> [String: String?] {
        var plan: [String: String?] = [:]
        for file in group.files {
            let current = currentText(file.path)
            switch (file.before, file.after) {
            case (let before, nil): if current == nil { plan[file.path] = .some(before) }
            case (nil, let after?): if current == after { plan[file.path] = .some(nil) }
            case (let before?, let after?):
                if let current, let undone = LineMerge.carry(current, from: after, to: before) { plan[file.path] = .some(undone) }
            }
        }
        return plan
    }

    /// The newer groups that also changed lines `group` changed, by title — what a forced undo takes with it.
    func newerConflicts(_ group: TurnLedger.Group) -> [String] {
        let plan = undoPlan(group)
        let blocked = Set(group.files.map(\.path).filter { plan[$0] == nil })
        return turnGroups.filter { $0.to > group.to && $0.files.contains { blocked.contains($0.path) } }.map(\.title)
    }

    /// Undo turn. False (nothing done) when a newer change touched the same lines and `force` is off — the window
    /// asks first; forced, those files go back to before the turn, the newer changes to them with it.
    @discardableResult
    func undo(group: TurnLedger.Group, force: Bool = false) -> Bool {
        let plan = undoPlan(group)
        guard force || plan.count == group.files.count else { return false }
        for file in group.files {
            let target = plan[file.path] ?? file.before
            let other = agent.others[file.path]
            agent.turns.undo(file.steps, path: file.path, force: plan[file.path] == nil)
            put(target, at: file.path)
            if let other { agent.restore(file.path, baseline: other.baseline, current: target, since: other.since) }
        }
        Task { await workspace?.refresh() }
        return true
    }

    /// Done, by turn: each file's unticked changes undone (where nothing newer touched them), the rest kept.
    func finishTurnReview() {
        var skipped = 0
        for group in turnGroups where !group.kept {
            for file in group.files {
                guard let rejected = agent.turns.unticked[group.id + "|" + file.path], !rejected.isEmpty else { continue }
                let diff = Self.diff(file)
                let partial = ReplacePlan.reconstruct(diff, rejecting: rejected)
                guard let current = currentText(file.path), let after = file.after,
                    let target = LineMerge.carry(current, from: after, to: partial)
                else {
                    skipped += 1
                    continue
                }
                put(target, at: file.path)
            }
        }
        keepAllOutside()
        if skipped > 0 { notice = "\(skipped) file\(skipped == 1 ? "" : "s") kept whole: a newer change touched the unticked lines." }
    }

    /// A group's change to one file, as the review shows it (and its hunk ticks number it).
    nonisolated static func diff(_ file: TurnLedger.FileChange) -> AinkradFileDiff {
        AinkradDiffEngine.compute(old: file.before ?? "", new: file.after ?? "", path: file.path, context: 2)
    }

    /// The file's text now: the buffer when open, else the disk (nil: it does not exist).
    func currentText(_ path: String) -> String? {
        if let document = documents[path], document.state == .ready { return document.storage.string }
        guard let workspace else { return nil }
        return SearchModel.readText(workspace.url(for: path))
    }

    /// Writes `text` (nil: the file goes) — through the editor when the file is open, so it is undoable there.
    private func put(_ text: String?, at path: String) {
        guard let workspace else { return }
        if let document = documents[path], document.state == .ready, let text {
            agent.expect(path)
            let old = document.storage.string
            apply([path: [TextChange(start: (0, 0), end: LineIndex(old).position(of: (old as NSString).length), newText: text)]])
            // Not on screen: the buffer changed without the editor reporting it.
            if !panes.contains(where: { $0.active == path }) { bufferChanged(path) }
            return
        }
        agent.treeChanged()
        let url = workspace.url(for: path)
        guard let text else {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return
        }
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: url)
        }
        _ = write(text, to: path, in: workspace)
    }

    // MARK: - Ask about this turn

    /// ↳ Ask about this turn: the request goes to the same Grimoire thread, with the turn's files attached; the
    /// thread's next turn lands back here.
    func askAbout(_ group: TurnLedger.Group, _ request: String) {
        let words = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let turn = group.turn, !words.isEmpty, let apps, let workspace else { return }
        let files = group.files.map { workspace.url(for: $0.path).path(percentEncoded: false) }
        let message = words + "\n\n(About turn \(turn.turn): " + files.map { "@" + $0 }.joined(separator: " ") + ")"
        let body: [String: Any] = [
            "kind": AinkradLaunchIntent.openDocumentKind, "path": turn.root, "prompt": message, "thread": turn.thread,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        apps.open(appID: Self.grimoireAppID, payload: String(decoding: data, as: UTF8.self))
        notice = "Sent to Grimoire — \(turn.agent)'s next turn lands here."
    }
}

extension TurnLedger.Group {
    /// "Claude · turn 3 · 4 files", or "Outside edits · 2 files".
    var title: String {
        let count = files.count == 1 ? "1 file" : "\(files.count) files"
        guard let turn else { return "Outside edits · " + count }
        return "\(turn.agent) · turn \(turn.turn) · " + count
    }
}
