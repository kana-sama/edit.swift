import CoreServices
import Darwin
import Foundation

struct JJWorktreeDecorations {
    struct Override: Equatable {
        let path: String
        let status: JJPathStatus?
    }

    let contents: JJWorkspaceContents
    let override: Override?

    func status(at url: URL, directory: Bool) -> JJPathStatus? {
        guard let path = contents.relativePath(to: url) else { return nil }
        guard directory else {
            return override?.path == path ? override?.status : contents.files[path]
        }
        var counts = contents.directories[path] ?? JJStatusCounts()
        if let override, path.isEmpty || override.path.hasPrefix(path + "/") {
            counts.add(contents.files[override.path], count: -1)
            counts.add(override.status)
        }
        return counts.status
    }
}

struct JJStatusCounts: Sendable {
    private var added = 0
    private var modified = 0
    private var conflicts = 0

    mutating func add(_ status: JJPathStatus?, count: Int = 1) {
        switch status {
        case .added: added += count
        case .modified, .removed: modified += count
        case .conflict: conflicts += count
        case nil: break
        }
    }

    var status: JJPathStatus? {
        if conflicts > 0 { return .conflict }
        if modified > 0 { return .modified }
        return added > 0 ? .added : nil
    }
}

struct JJWorkspaceContents: Sendable {
    let repository: JJRepositoryState
    let files: [String: JJPathStatus]
    let directories: [String: JJStatusCounts]

    func relativePath(to url: URL) -> String? {
        let root = WorktreeFileOperations.path(repository.workspace.root)
        let path = WorktreeFileOperations.path(url)
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    @concurrent
    static func prepare(_ repository: JJRepositoryState) async throws -> Self {
        let root = repository.workspace.root
        var nested: [String: Bool] = ["": false]

        func parent(of path: String) -> String {
            path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
        }

        func inNestedWorkspace(_ path: String) -> Bool {
            var directory = parent(of: path)
            var unchecked: [String] = []
            while nested[directory] == nil {
                unchecked.append(directory)
                directory = parent(of: directory)
            }
            var found = nested[directory] == true
            for path in unchecked.reversed() {
                if !found {
                    let marker = root.appending(path: path, directoryHint: .isDirectory).appending(path: ".jj/repo")
                    found = FileManager.default.fileExists(atPath: marker.path)
                }
                nested[path] = found
            }
            return found
        }

        var files: [String: JJPathStatus] = [:]
        for (path, change) in repository.changes {
            try Task.checkCancellation()
            if !inNestedWorkspace(path) { files[path] = change.status }
            if change.isRename, let source = change.sourcePath, !inNestedWorkspace(source) {
                files[source] = files[source] ?? .removed
            }
        }
        for path in repository.conflicts {
            try Task.checkCancellation()
            if !inNestedWorkspace(path) { files[path] = .conflict }
        }

        var directories: [String: JJStatusCounts] = [:]
        for (path, status) in files {
            try Task.checkCancellation()
            var directory = parent(of: path)
            while true {
                directories[directory, default: JJStatusCounts()].add(status)
                if directory.isEmpty { break }
                directory = parent(of: directory)
            }
        }
        return Self(repository: repository, files: files, directories: directories)
    }
}

@MainActor
final class JJChangeMonitor {
    struct Subscription {
        fileprivate let workspace: JJWorkspace
        fileprivate let id: UUID
    }

    @MainActor
    private final class Workspace {
        let location: JJWorkspace
        let refreshRequests = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var contents: JJWorkspaceContents?
        var observers: [UUID: Observer] = [:]
        var task: Task<Void, Never>?
        var polling: Task<Void, Never>?
        var paths: JJWorkspacePaths?
        var mayNeedSnapshot = true
        var diskGeneration: UInt64 = 0
        var capturedDiskGeneration: UInt64 = 0
        var nextSnapshot: ContinuousClock.Instant
        var liveSnapshotDebounce: (deadline: ContinuousClock.Instant, task: Task<Void, Never>)?
        var liveSnapshotPending = false

        var observesLiveSnapshots: Bool { observers.values.contains { $0.liveSnapshots } }

        init(location: JJWorkspace, nextSnapshot: ContinuousClock.Instant) {
            self.location = location
            self.nextSnapshot = nextSnapshot
        }

        func stop() {
            paths = nil
            refreshRequests.continuation.finish()
            task?.cancel()
            polling?.cancel()
            clearLiveSnapshot()
        }

        func clearLiveSnapshot() {
            liveSnapshotDebounce?.task.cancel()
            liveSnapshotDebounce = nil
            liveSnapshotPending = false
        }

        isolated deinit { stop() }
    }

    private struct Observer {
        let liveSnapshots: Bool
        let updated: @MainActor (JJWorkspaceContents?) -> Void
        let diskChanged: @MainActor (Set<String>?) -> Void
    }

    private enum OperationWatch {
        case opening(Task<Void, Never>)
        case active(JJOperationWatcher)
        case unavailable
    }

    private let clock = ContinuousClock()
    private let checkInterval: Duration
    private let snapshotInterval: Duration
    private let writeSnapshot: @MainActor (JJWorkspace) async throws -> Void
    private var workspaces: [JJWorkspace: Workspace] = [:]
    private var operationWatchers: [URL: OperationWatch] = [:]
    private var suspendedDeadlines: [JJWorkspace: (next: ContinuousClock.Instant, expires: ContinuousClock.Instant)] = [:]
    private var snapshotting: Set<URL> = []

    init(checkInterval: Duration = .seconds(2), snapshotInterval: Duration = .seconds(180),
         writeSnapshot: @escaping @MainActor (JJWorkspace) async throws -> Void = JJRepository.snapshot) {
        self.checkInterval = checkInterval
        self.snapshotInterval = snapshotInterval
        self.writeSnapshot = writeSnapshot
    }

    func subscribe(
        to location: JJWorkspace,
        liveSnapshots: Bool = false,
        updated: @escaping @MainActor (JJWorkspaceContents?) -> Void,
        diskChanged: @escaping @MainActor (Set<String>?) -> Void = { _ in }
    ) -> Subscription {
        let id = UUID()
        let workspace: Workspace
        if let existing = workspaces[location] {
            workspace = existing
        } else {
            let now = clock.now
            suspendedDeadlines = suspendedDeadlines.filter { $0.value.expires >= now }
            let deadline = suspendedDeadlines.removeValue(forKey: location)?.next ?? now.advanced(by: snapshotInterval)
            workspace = Workspace(location: location, nextSnapshot: deadline)
            workspaces[location] = workspace
            workspace.paths = JJWorkspacePaths(root: location.root) { [weak self, weak workspace] paths in
                guard let self, let workspace else { return }
                workspace.mayNeedSnapshot = true
                workspace.diskGeneration &+= 1
                for observer in Array(workspace.observers.values) { observer.diskChanged(paths) }
                enqueueLiveSnapshot(for: workspace)
            }
            workspace.task = Task { [weak self, weak workspace, stream = workspace.refreshRequests.stream] in
                for await _ in stream {
                    guard !Task.isCancelled, let self, let workspace else { return }
                    await self.refresh(workspace)
                }
            }
            // Keep checking when file events are unavailable and advance scheduled snapshots.
            workspace.polling = Task { [checkInterval, requests = workspace.refreshRequests.continuation] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: checkInterval) } catch { return }
                    requests.yield()
                }
            }
            workspace.refreshRequests.continuation.yield()
        }
        workspace.observers[id] = Observer(liveSnapshots: liveSnapshots, updated: updated, diskChanged: diskChanged)
        if liveSnapshots, workspace.diskGeneration != workspace.capturedDiskGeneration { enqueueLiveSnapshot(for: workspace) }
        updated(workspace.contents)
        return Subscription(workspace: location, id: id)
    }

    func unsubscribe(_ subscription: Subscription?) {
        guard let subscription, let workspace = workspaces[subscription.workspace] else { return }
        workspace.observers.removeValue(forKey: subscription.id)
        if !workspace.observesLiveSnapshots { workspace.clearLiveSnapshot() }
        if workspace.observers.isEmpty {
            // File-to-file navigation can temporarily leave the workspace without an observer.
            suspendedDeadlines[subscription.workspace] = (workspace.nextSnapshot, clock.now.advanced(by: .seconds(10)))
            workspaces.removeValue(forKey: subscription.workspace)
            workspace.stop()
            let repository = workspace.location.repository
            if !workspaces.keys.contains(where: { $0.repository == repository }) {
                let watch = operationWatchers.removeValue(forKey: repository)
                if case .opening(let task) = watch { task.cancel() }
            }
        }
    }

    func refreshSoon(_ subscription: Subscription?) {
        guard let subscription, let workspace = workspaces[subscription.workspace] else { return }
        // Recheck a file's disk revision on return even if no watcher event was delivered.
        workspace.observers[subscription.id]?.diskChanged(nil)
        workspace.refreshRequests.continuation.yield()
    }

    private func watchOperations(in repository: URL) {
        guard operationWatchers[repository] == nil else { return }
        let opening = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let descriptor = await JJOperationWatcher.openHeads(in: repository)
            guard !Task.isCancelled, let self else {
                if descriptor >= 0 { close(descriptor) }
                return
            }
            guard descriptor >= 0 else {
                operationWatchers[repository] = .unavailable
                return
            }
            operationWatchers[repository] = .active(JJOperationWatcher(descriptor: descriptor) { [weak self] ended in
                guard let self else { return }
                if ended { operationWatchers.removeValue(forKey: repository) }
                requestRefreshes(in: repository)
            })
        }
        operationWatchers[repository] = .opening(opening)
    }

    private func requestRefreshes(in repository: URL) {
        for workspace in workspaces.values where workspace.location.repository == repository {
            workspace.refreshRequests.continuation.yield()
        }
    }

    private func refresh(_ workspace: Workspace) async {
        let location = workspace.location
        watchOperations(in: location.repository)
        scheduleSnapshot(for: workspace)
        do {
            let operation = try await JJRepository.operation(in: location)
            try Task.checkCancellation()
            guard workspace.contents?.repository.operationID != operation else { return }
            let state = try await JJRepository.read(location, at: operation)
            let contents = try await JJWorkspaceContents.prepare(state)
            try Task.checkCancellation()
            let latest = try await JJRepository.operation(in: location)
            guard !Task.isCancelled, workspaces[location] === workspace else { return }
            guard latest == operation else {
                workspace.refreshRequests.continuation.yield()
                return
            }
            install(contents, for: workspace)
        } catch {
            if !Task.isCancelled, !snapshotting.contains(location.repository), workspace.contents != nil {
                install(nil, for: workspace)
            }
        }
    }

    private func scheduleSnapshot(for workspace: Workspace) {
        let location = workspace.location
        guard workspace.mayNeedSnapshot, workspace.liveSnapshotPending || clock.now >= workspace.nextSnapshot,
              snapshotting.insert(location.repository).inserted else { return }
        workspace.clearLiveSnapshot()
        let generation = workspace.diskGeneration
        workspace.nextSnapshot = clock.now.advanced(by: snapshotInterval)
        // Let an in-flight repository write finish even if its last observer closes.
        Task { [weak self, weak workspace, writeSnapshot] in
            defer { self?.snapshotting.remove(location.repository) }
            do { try await writeSnapshot(location) }
            catch { return }
            if let workspace {
                workspace.capturedDiskGeneration = generation
                if generation == workspace.diskGeneration { workspace.mayNeedSnapshot = workspace.paths == nil }
            }
            self?.requestRefreshes(in: location.repository)
        }
    }

    private func enqueueLiveSnapshot(for workspace: Workspace) {
        guard workspace.observesLiveSnapshots, !workspace.liveSnapshotPending else { return }
        // A burst of disk writes usually comes from one save. Bound the wait when writes continue.
        let now = clock.now
        let deadline = workspace.liveSnapshotDebounce?.deadline ?? now.advanced(by: .milliseconds(1500))
        let next = min(deadline, now.advanced(by: .milliseconds(350)))
        workspace.liveSnapshotDebounce?.task.cancel()
        let task = Task { [clock, weak workspace] in
            do { try await clock.sleep(until: next) } catch { return }
            guard let workspace, !Task.isCancelled else { return }
            workspace.liveSnapshotDebounce = nil
            workspace.liveSnapshotPending = true
            workspace.refreshRequests.continuation.yield()
        }
        workspace.liveSnapshotDebounce = (deadline, task)
    }

    private func install(_ contents: JJWorkspaceContents?, for workspace: Workspace) {
        workspace.contents = contents
        for observer in Array(workspace.observers.values) { observer.updated(contents) }
    }
}

@MainActor
private final class JJOperationWatcher {
    private let source: DispatchSourceFileSystemObject

    nonisolated static func openHeads(in repository: URL) async -> Int32 {
        // The standard jj op-head store publishes operations as directory entries.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let heads = repository.appending(path: "op_heads/heads", directoryHint: .isDirectory)
                let descriptor = heads.withUnsafeFileSystemRepresentation { path in
                    path.map { open($0, O_EVTONLY | O_CLOEXEC | O_DIRECTORY) } ?? -1
                }
                continuation.resume(returning: descriptor)
            }
        }
    }

    init(descriptor: Int32, changed: @escaping @MainActor (Bool) -> Void) {
        let invalidation: DispatchSource.FileSystemEvent = [.delete, .rename, .revoke]
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, invalidation], queue: .main)
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                if let self { changed(!self.source.data.intersection(invalidation).isEmpty) }
            }
        }
        // Recheck if an operation was published while opening or registering the watch.
        source.setRegistrationHandler { [weak self] in
            MainActor.assumeIsolated {
                if self != nil { changed(false) }
            }
        }
        source.activate()
    }

    deinit { source.cancel() }
}

@MainActor
private final class JJWorkspacePaths {
    private var stream: FSEventStreamRef?
    private let prefix: String
    private let changed: @MainActor (Set<String>?) -> Void

    init?(root: URL, changed: @escaping @MainActor (Set<String>?) -> Void) {
        let rootPath = WorktreeFileOperations.path(root)
        prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let observer = Unmanaged<JJWorkspacePaths>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            MainActor.assumeIsolated { observer.receive(paths, flags: flags, count: count) }
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
        FSEventStreamCreateFlags(flags))
        guard let stream else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    private func receive(_ paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        let mustScan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
        var touched: Set<String> = []
        for index in 0..<min(count, paths.count) {
            if flags[index] & mustScan != 0 {
                changed(nil)
                return
            }
            let path = WorktreeFileOperations.path(URL(filePath: paths[index]))
            guard path.hasPrefix(prefix) else { continue }
            let components = path.dropFirst(prefix.count).split(separator: "/")
            guard !components.isEmpty, !components.contains(".jj"), !components.contains(".git") else { continue }
            touched.insert(path)
        }
        if !touched.isEmpty { changed(touched) }
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
