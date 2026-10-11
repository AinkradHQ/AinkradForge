import CoreServices
import Foundation

/// Watches a folder tree with FSEvents and reports, debounced, which paths changed. FSEvents (not a vnode
/// watch per file) because editors and agents save atomically — write a temp file, rename it over — which a
/// per-file watch loses track of.
final class FolderWatcher: @unchecked Sendable {
    /// What the stream holds: just the callback, retained — never the watcher, so a callback already queued
    /// when the watcher goes away cannot reach freed memory.
    private final class Box {
        let onChange: @Sendable ([String]) -> Void
        init(_ onChange: @escaping @Sendable ([String]) -> Void) { self.onChange = onChange }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.ainkrad.forge.watcher")
    private let box: Unmanaged<Box>

    /// `onChange` gets absolute paths, on a background queue, at most every `latency` seconds.
    init?(root: URL, latency: TimeInterval = 0.3, onChange: @escaping @Sendable ([String]) -> Void) {
        let box = Unmanaged.passRetained(Box(onChange))
        self.box = box
        var context = FSEventStreamContext(
            version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            box.onChange((0..<count).compactMap { array[$0] as? String })
        }
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, [root.path(percentEncoded: false)] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                // UseCFTypes: the paths argument is then a CFArray of strings — without it, a C `char **`.
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                        | kFSEventStreamCreateFlagUseCFTypes))
        else {
            box.release()
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        // Let a callback that was already running finish before its box goes.
        queue.sync {}
        box.release()
    }

    /// Whether a change under `.git` matters to the tree and status: the index, HEAD and refs do; objects,
    /// logs and lock files do not (they churn on every git command, including our own status calls).
    static func isRelevant(_ path: String) -> Bool {
        guard let range = path.range(of: "/.git/") else { return !path.hasSuffix("/.git") }
        let inside = path[range.upperBound...]
        if inside.hasSuffix(".lock") { return false }
        return inside == "index" || inside == "HEAD" || inside.hasPrefix("refs/")
    }
}
