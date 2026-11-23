import Foundation

@MainActor
final class DocumentFileRefresh {
    private let canRefresh: () -> Bool
    private let apply: (FileBuffer) -> Void
    private var url: URL?
    private var stamp: FileBuffer.DiskStamp?
    private var monitor: FileSystemEvents?
    private var worker: Task<Void, Never>?
    private var pending = false

    init(canRefresh: @escaping () -> Bool, apply: @escaping (FileBuffer) -> Void) {
        self.canRefresh = canRefresh
        self.apply = apply
    }

    func observe(_ url: URL, stamp: FileBuffer.DiskStamp?) {
        if url == self.url {
            self.stamp = stamp
            return
        }
        stop()
        self.url = url
        self.stamp = stamp
        let directory = url.deletingLastPathComponent()
        let path = url.path
        monitor = FileSystemEvents(directory: directory) { [weak self] events in
            if events.contains(where: {
                $0.requiresRescan || $0.path == directory.path || $0.path.caseInsensitiveCompare(path) == .orderedSame
            }) {
                self?.check()
            }
        }
        // Cover a write between opening the buffer and starting the stream.
        check()
    }

    func check() {
        guard url != nil else { return }
        pending = true
        resume()
    }

    func resume() {
        guard pending, worker == nil, let url else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            // Enter on the next main-actor turn so AppKit can finish changing first responder.
            while !Task.isCancelled, pending, canRefresh() {
                pending = false
                let stamp = self.stamp
                let file = await Task.detached(priority: .utility) {
                    try? FileBuffer.readIfChanged(url, since: stamp)
                }.value
                guard !Task.isCancelled else { return }
                if !canRefresh() {
                    pending = true
                    break
                }
                // A write or a newer notification during the read invalidates its result.
                if self.stamp != stamp { pending = true }
                if !pending, let file, file.url == url { apply(file) }
            }
            if !Task.isCancelled { worker = nil }
        }
    }

    func stop() {
        worker?.cancel()
        worker = nil
        monitor = nil
        pending = false
        url = nil
        stamp = nil
    }
}
