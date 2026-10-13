import AinkradAppKit
import Foundation

/// A Grimoire turn as Grimoire announces it: which thread, which turn, the request, and the files its edit tools
/// wrote. Grimoire posts it in-process (plugins share the host process) on `notification`, as a JSON string — the
/// launch payload's encoding, without opening a pane every turn.
struct AgentTurn: Codable, Equatable {
    static let kind = "agentTurn"
    static let notification = Notification.Name("com.ainkrad.agentTurn")

    let kind: String
    /// The thread's working directory.
    let root: String
    let thread: String
    let turn: Int
    /// "Claude", "Codex", …
    let agent: String
    let prompt: String?
    /// Absolute paths, as Grimoire announces them; workspace-relative once Forge adopts the turn.
    var files: [String]
    /// Seconds since 1970.
    let startedAt: Double
    let endedAt: Double

    var id: String { "\(thread)#\(turn)" }

    static func decode(_ payload: String?) -> AgentTurn? {
        guard let data = payload?.data(using: .utf8), let turn = try? JSONDecoder().decode(AgentTurn.self, from: data),
            turn.kind == kind
        else { return nil }
        return turn
    }
}

/// What another app asked Forge to open. Rides `AinkradLaunchIntent` (`openDocument`), so the host brings an
/// open Forge forward and remounts it to collect the payload instead of opening a second Forge; the extra fields
/// are Forge's own. A bare path works too.
struct ForgeLaunch: Decodable, Equatable {
    let path: String
    /// 1-based; the caret goes there.
    var line: Int?
    /// Open the review of outside changes (Grimoire's "Review in Forge").
    var review: Bool?

    static func decode(_ payload: String?) -> ForgeLaunch? {
        guard let payload else { return nil }
        guard let intent = AinkradLaunchIntent.decode(payload) else { return ForgeLaunch(path: payload) }
        var launch = (try? JSONDecoder().decode(ForgeLaunch.self, from: Data(payload.utf8))) ?? ForgeLaunch(path: intent.path)
        launch.line = launch.line.map { max(1, $0) }
        return launch
    }
}

/// Line-level three-way merging: carrying one change onto a text that has moved on since.
enum LineMerge {
    /// Old lines `range` replaced by `lines`.
    struct Region: Equatable {
        let range: Range<Int>
        let lines: [String]
    }

    /// Foundation's split: a "\r\n" pair is one Swift Character, but two UTF-16 units here.
    static func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    /// The runs where `new` differs from `old`, in `old`'s coordinates.
    static func regions(_ old: [String], _ new: [String]) -> [Region] {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var regions: [Region] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, !removed.contains(i), !inserted.contains(j) {
                i += 1
                j += 1
                continue
            }
            let (i0, j0) = (i, j)
            while i < old.count, removed.contains(i) { i += 1 }
            while j < new.count, inserted.contains(j) { j += 1 }
            regions.append(Region(range: i0..<i, lines: Array(new[j0..<j])))
        }
        return regions
    }

    /// Two changes to the same lines (or inserting at the same place).
    static func overlaps(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        a.lowerBound == b.lowerBound || (a.lowerBound < b.upperBound && b.lowerBound < a.upperBound)
    }

    /// `text` with the change `old` → `new` made in it, where `text` grew from `old` too. Nil when the two touch
    /// the same lines: never a silent merge.
    static func carry(_ text: String, from old: String, to new: String) -> String? {
        let base = lines(old)
        let wanted = regions(base, lines(new))
        let theirs = regions(base, lines(text))
        for region in wanted where theirs.contains(where: { overlaps(region.range, $0.range) }) { return nil }
        var out: [String] = []
        var index = 0
        for region in (wanted + theirs).sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            out += base[index..<region.range.lowerBound]
            out += region.lines
            index = region.range.upperBound
        }
        out += base[index...]
        return out.joined(separator: "\n")
    }

    /// `+added −removed` of a change.
    static func counts(_ old: String?, _ new: String?) -> (added: Int, removed: Int) {
        let changes = regions(old.map(lines) ?? [], new.map(lines) ?? [])
        return (changes.reduce(0) { $0 + $1.lines.count }, changes.reduce(0) { $0 + $1.range.count })
    }
}

/// Outside writes to files in review, in the order Forge saw them, and the Grimoire turns that claim them. A
/// write belongs to the newest turn that names its file and was running when Forge saw it; any other write is an
/// outside edit, grouped by time window.
struct TurnLedger: Equatable {
    struct Step: Equatable {
        let id: Int
        let path: String
        /// Nil: the file did not exist (before) or was deleted (after).
        var before: String?
        var after: String?
        let at: Date
    }

    struct Turn: Equatable {
        let info: AgentTurn
        let arrived: Date
    }

    /// One file's change within a group: the first step's before to the last step's after.
    struct FileChange: Equatable {
        let path: String
        let before: String?
        let after: String?
        let steps: [Int]
    }

    struct Group: Equatable, Identifiable {
        let id: String
        /// Nil: outside edits.
        let turn: AgentTurn?
        let from: Date
        let to: Date
        let files: [FileChange]
        var kept = false
    }

    private(set) var steps: [Step] = []
    private(set) var turns: [Turn] = []
    /// Groups kept, as they were when kept (their steps may since have folded into the baseline).
    private(set) var kept: [String: Group] = [:]
    /// Changes unticked in the review, per group and file (`"group|path"`): Done undoes them.
    var unticked: [String: Set<Int>] = [:]
    private var nextID = 0

    /// A write seen up to this long after a turn's end (the watcher's lag) still belongs to it.
    static let grace: TimeInterval = 3
    /// Outside edits further apart than this are separate groups.
    static let window: TimeInterval = 120

    var isEmpty: Bool { turns.isEmpty }

    mutating func observe(_ path: String, before: String?, after: String?, at: Date = Date()) {
        guard before != after else { return }
        if let last = steps.last(where: { $0.path == path }), last.after == after { return }
        nextID += 1
        steps.append(Step(id: nextID, path: path, before: before, after: after, at: at))
    }

    mutating func add(_ turn: AgentTurn, at: Date = Date()) {
        guard !turns.contains(where: { $0.info.id == turn.id }) else { return }
        turns.append(Turn(info: turn, arrived: at))
    }

    /// The file left the review (kept, undone, typed in, opened).
    mutating func drop(_ path: String) {
        steps.removeAll { $0.path == path }
        unticked = unticked.filter { !$0.key.hasSuffix("|" + path) }
    }

    mutating func clear() { self = TurnLedger() }

    /// The turn that was running when Forge saw `step` and names its file — or, within the watcher's lag after a
    /// turn ended, that turn.
    func owner(of step: Step) -> AgentTurn? {
        let candidates = turns.filter { turn in
            turn.info.files.contains(step.path) && step.at.timeIntervalSince1970 >= turn.info.startedAt - 1
                && step.at <= turn.arrived.addingTimeInterval(Self.grace)
        }
        return (candidates.first { step.at <= $0.arrived } ?? candidates.first)?.info
    }

    /// Every group, newest first: turns, outside-edit windows, and kept groups. Only files still in `review`.
    func groups(in review: Set<String>) -> [Group] {
        var byTurn: [String: [Step]] = [:]
        var outside: [[Step]] = []
        for step in steps where review.contains(step.path) {
            if let turn = owner(of: step) {
                byTurn[turn.id, default: []].append(step)
            } else if let last = outside.last?.last, step.at.timeIntervalSince(last.at) <= Self.window {
                outside[outside.count - 1].append(step)
            } else {
                outside.append([step])
            }
        }
        var groups: [Group] = []
        for turn in turns {
            guard let steps = byTurn[turn.info.id], kept["turn:" + turn.info.id] == nil else { continue }
            groups.append(Self.group(id: "turn:" + turn.info.id, turn: turn.info, steps: steps, to: turn.arrived))
        }
        for run in outside {
            guard let first = run.first, let last = run.last, kept["outside:\(first.id)"] == nil else { continue }
            groups.append(Self.group(id: "outside:\(first.id)", turn: nil, steps: run, to: last.at))
        }
        groups += kept.values
        return groups.sorted { $0.to > $1.to }
    }

    private static func group(id: String, turn: AgentTurn?, steps: [Step], to: Date) -> Group {
        var order: [String] = []
        var byPath: [String: [Step]] = [:]
        for step in steps {
            if byPath[step.path] == nil { order.append(step.path) }
            byPath[step.path, default: []].append(step)
        }
        let files = order.compactMap { path -> FileChange? in
            guard let run = byPath[path], let first = run.first, let last = run.last else { return nil }
            return FileChange(path: path, before: first.before, after: last.after, steps: run.map(\.id))
        }
        let from = turn.map { Date(timeIntervalSince1970: $0.startedAt) } ?? steps.first?.at ?? to
        return Group(id: id, turn: turn, from: from, to: to, files: files)
    }

    /// Keep: the group is done; its rows stay as "Kept" until the review ends.
    mutating func keep(_ group: Group) {
        var done = group
        done.kept = true
        kept[group.id] = done
    }

    /// The steps of one file, oldest first.
    func steps(of path: String) -> [Step] { steps.filter { $0.path == path } }

    /// Leading steps of `path` whose groups are kept fold into the baseline: the last of them, if any (its
    /// `after` is the new baseline).
    mutating func foldKept(_ path: String) -> Step? {
        let keptSteps = Set(kept.values.flatMap { $0.files.filter { $0.path == path }.flatMap(\.steps) })
        var folded: Step?
        while let first = steps.first(where: { $0.path == path }), keptSteps.contains(first.id) {
            folded = first
            steps.removeAll { $0.id == first.id }
        }
        return folded
    }

    /// Takes a group's steps on `path` out, carrying their undo into every later step of that file so the chain
    /// stays consistent. `force` (a conflict the person accepted) drops the later steps instead: undone too.
    mutating func undo(_ ids: [Int], path: String, force: Bool) {
        guard let first = steps.firstIndex(where: { ids.contains($0.id) }), let last = steps.lastIndex(where: { ids.contains($0.id) })
        else { return }
        let before = steps[first].before ?? ""
        let after = steps[last].after ?? ""
        let (firstID, lastID) = (steps[first].id, steps[last].id)
        if force {
            steps.removeAll { $0.path == path && $0.id >= firstID }
            return
        }
        for index in steps.indices where steps[index].path == path && steps[index].id > lastID {
            steps[index].before = steps[index].before.map { LineMerge.carry($0, from: after, to: before) ?? $0 }
            steps[index].after = steps[index].after.map { LineMerge.carry($0, from: after, to: before) ?? $0 }
        }
        steps.removeAll { ids.contains($0.id) }
    }
}
