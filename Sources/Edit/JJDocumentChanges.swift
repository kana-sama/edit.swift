import Foundation

@MainActor
final class JJDocumentChanges {
    private struct File {
        let url: URL
        let revision: FileRevision?
    }

    private struct Comparison {
        let operation: String
        let value: JJFileComparison?
    }

    private struct LocalStatus: Equatable {
        let operation: String
        let override: JJWorktreeDecorations.Override
    }

    private let monitor: JJChangeMonitor
    private let text: @MainActor () -> String?
    private let showMarks: @MainActor ([JJLineMark], [Int]) -> Void
    private let showWorktree: @MainActor (JJWorktreeDecorations?) -> Void
    private var file: File?
    private var folder: URL?
    private var fileSubscription: JJChangeMonitor.Subscription?
    private var folderSubscription: JJChangeMonitor.Subscription?
    private var findingFile: Task<Void, Never>?
    private var findingFolder: Task<Void, Never>?
    private var rendering: Task<Void, Never>?
    private var fileContents: JJWorkspaceContents?
    private var folderContents: JJWorkspaceContents?
    private var comparison: Comparison?
    private var diskMatchesBuffer: Bool?
    private var localStatus: LocalStatus?

    init(
        monitor: JJChangeMonitor,
        text: @escaping @MainActor () -> String?,
        showMarks: @escaping @MainActor ([JJLineMark], [Int]) -> Void,
        showWorktree: @escaping @MainActor (JJWorktreeDecorations?) -> Void
    ) {
        self.monitor = monitor
        self.text = text
        self.showMarks = showMarks
        self.showWorktree = showWorktree
    }

    func update(file url: URL?, revision: FileRevision?, folder: URL?) {
        if file?.url != url {
            stopFile()
            file = url.map { File(url: $0, revision: revision) }
            findFileWorkspace()
        } else if let url, file?.revision != revision {
            file = File(url: url, revision: revision)
            diskMatchesBuffer = nil
            render()
        }
        if self.folder != folder {
            stopFolder()
            self.folder = folder
            findFolderWorkspace()
        }
    }

    func bufferChanged(immediately: Bool = false) {
        showMarks([], [])
        render(after: immediately ? .zero : .milliseconds(150))
    }

    func recheck() {
        monitor.refreshSoon(fileSubscription)
        if fileSubscription == nil { findFileWorkspace() }
        if folderSubscription == nil { findFolderWorkspace() }
    }

    func stop() {
        stopFile()
        stopFolder()
    }

    private func findFileWorkspace() {
        guard let url = file?.url, findingFile == nil else { return }
        findingFile = Task { [weak self] in
            let workspace = await JJRepository.discover(at: url.deletingLastPathComponent())
            guard let self, !Task.isCancelled else { return }
            findingFile = nil
            guard let workspace else { return }
            fileSubscription = monitor.subscribe(to: workspace) { [weak self] contents in
                self?.updateFileContents(contents)
            } diskChanged: { [weak self] paths in
                self?.filesChanged(paths)
            }
        }
    }

    private func findFolderWorkspace() {
        guard let folder, findingFolder == nil else { return }
        findingFolder = Task { [weak self] in
            let workspace = await JJRepository.discover(at: folder)
            guard let self, !Task.isCancelled else { return }
            findingFolder = nil
            guard let workspace else { return }
            folderSubscription = monitor.subscribe(to: workspace) { [weak self] contents in
                self?.folderContents = contents
                self?.publishWorktree()
            }
        }
    }

    private func stopFile() {
        findingFile?.cancel()
        findingFile = nil
        monitor.unsubscribe(fileSubscription)
        fileSubscription = nil
        file = nil
        updateFileContents(nil)
    }

    private func stopFolder() {
        findingFolder?.cancel()
        findingFolder = nil
        monitor.unsubscribe(folderSubscription)
        folderSubscription = nil
        folder = nil
        folderContents = nil
        publishWorktree()
    }

    private func updateFileContents(_ contents: JJWorkspaceContents?) {
        fileContents = contents
        comparison = nil
        diskMatchesBuffer = nil
        if contents == nil {
            showMarks([], [])
            setLocalStatus(nil)
        }
        render()
    }

    private func filesChanged(_ paths: Set<String>?) {
        guard let url = file?.url else { return }
        let path = WorktreeFileOperations.path(url)
        guard paths == nil || paths?.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) == true else { return }
        diskMatchesBuffer = nil
        render()
    }

    private func render(after delay: Duration = .zero) {
        rendering?.cancel()
        rendering = nil
        guard let file, let contents = fileContents, let path = contents.relativePath(to: file.url),
              !path.isEmpty else { return }
        let state = contents.repository
        rendering = Task { [weak self] in
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                if let self, !Task.isCancelled { await self.render(file, path: path, in: state) }
            } catch {
                return
            }
        }
    }

    private func render(_ file: File, path: String, in state: JJRepositoryState) async {
        do {
            let inSync: Bool
            if let diskMatchesBuffer {
                inSync = diskMatchesBuffer
            } else {
                inSync = await Self.matchesDisk(file.url, revision: file.revision)
                try Task.checkCancellation()
                diskMatchesBuffer = inSync
            }
            guard inSync else {
                showMarks([], [])
                setLocalStatus(nil)
                return
            }

            let pair: JJFileComparison?
            if let comparison, comparison.operation == state.operationID {
                pair = comparison.value
            } else {
                pair = try await JJRepository.compare(path, in: state)
                try Task.checkCancellation()
                comparison = Comparison(operation: state.operationID, value: pair)
            }
            guard let pair else {
                showMarks([], [])
                setLocalStatus(nil)
                return
            }
            guard let current = text() else { return }
            let result = await Self.analyze(pair, text: current)
            try Task.checkCancellation()
            showMarks(result.marks, result.lineStarts)
            let status: JJPathStatus?
            if pair.isConflicted && result.remainsConflicted != false {
                status = .conflict
            } else if !pair.existsInBase {
                status = .added
            } else if result.isChanged == false {
                status = state.changes[path]?.keepsModificationWhenTextMatchesBase == true ? .modified : nil
            } else if result.isChanged == true || pair.isConflicted {
                status = .modified
            } else {
                status = state.changes[path]?.status
            }
            setLocalStatus(LocalStatus(operation: state.operationID, override: .init(path: path, status: status)))
        } catch {
            if !Task.isCancelled {
                showMarks([], [])
                setLocalStatus(nil)
            }
        }
    }

    @concurrent
    private static func matchesDisk(_ url: URL, revision: FileRevision?) async -> Bool {
        guard let revision else { return false }
        return (try? FileBuffer.revision(at: url)) == revision
    }

    @concurrent
    private static func analyze(_ pair: JJFileComparison, text: String) async -> JJTextAnalysis {
        JJLineDiff.analyze(base: pair.base, current: text, isConflicted: pair.isConflicted,
                           recordedConflict: pair.isConflicted ? pair.recorded : nil,
                           normalizeCRLF: pair.normalizeCRLF)
    }

    private func setLocalStatus(_ status: LocalStatus?) {
        guard localStatus != status else { return }
        localStatus = status
        publishWorktree()
    }

    private func publishWorktree() {
        guard let folderContents else {
            showWorktree(nil)
            return
        }
        let override = fileContents?.repository.workspace == folderContents.repository.workspace &&
            localStatus?.operation == folderContents.repository.operationID ? localStatus?.override : nil
        showWorktree(JJWorktreeDecorations(contents: folderContents, override: override))
    }

    isolated deinit {
        findingFile?.cancel()
        findingFolder?.cancel()
        rendering?.cancel()
        monitor.unsubscribe(fileSubscription)
        monitor.unsubscribe(folderSubscription)
    }
}
