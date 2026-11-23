import Foundation

struct JJWorkingCopyFileStatus: Equatable {
    let workspace: JJWorkspace
    let operationID: String
    let commitID: String
    let path: String
    let status: JJPathStatus?

    func applying(to files: [JJSourceControlFile]) -> [JJSourceControlFile] {
        let index = files.firstIndex { $0.path == path }
        let recorded = index.map { files[$0] }
        guard recorded?.status != status else { return files }
        var result = files
        if let index { result.remove(at: index) }
        guard let status else { return result }

        let file: JJSourceControlFile
        switch status {
        case .added:
            file = .init(path: path, sourcePath: nil, kind: .added, source: .absent, target: .file)
        case .modified:
            file = .init(path: path, sourcePath: recorded?.sourcePath, kind: .modified,
                         source: recorded?.source ?? .file, target: .file)
        case .removed:
            file = .init(path: path, sourcePath: nil, kind: .deleted, source: recorded?.source ?? .file, target: .absent)
        case .conflict:
            file = .init(path: path, sourcePath: recorded?.sourcePath, kind: .conflict,
                         source: recorded?.source ?? .file, target: .conflict)
        }
        result.insert(file, at: index ?? result.endIndex)
        return result
    }
}

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

    private let monitor: JJChangeMonitor
    private let text: @MainActor () -> String?
    private let showMarks: @MainActor (JJTextAnalysis?, Bool) -> Void
    private let suspendMarkerNavigation: @MainActor () -> Void
    private let showWorktree: @MainActor (JJWorktreeDecorations?) -> Void
    private let workingCopyStatusChanged: @MainActor () -> Void
    private var file: File?
    private var folder: URL?
    private var fileSubscription: JJChangeMonitor.Subscription?
    private var folderSubscription: JJChangeMonitor.Subscription?
    private var findingFile: Task<Void, Never>?
    private var findingFolder: Task<Void, Never>?
    private var pendingBufferRefresh: Task<Void, Never>?
    private var rendering: Task<Void, Never>?
    private var analyzingBuffer = false
    private var presentationExpiry: Task<Void, Never>?
    private var hasVisibleMarks = false
    private var fileContents: JJWorkspaceContents?
    private var folderContents: JJWorkspaceContents?
    private var comparison: Comparison?
    private var diskMatchesBuffer: Bool?
    private(set) var localStatus: JJWorkingCopyFileStatus?

    init(
        monitor: JJChangeMonitor,
        text: @escaping @MainActor () -> String?,
        showMarks: @escaping @MainActor (JJTextAnalysis?, Bool) -> Void,
        suspendMarkerNavigation: @escaping @MainActor () -> Void,
        showWorktree: @escaping @MainActor (JJWorktreeDecorations?) -> Void,
        workingCopyStatusChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.monitor = monitor
        self.text = text
        self.showMarks = showMarks
        self.suspendMarkerNavigation = suspendMarkerNavigation
        self.showWorktree = showWorktree
        self.workingCopyStatusChanged = workingCopyStatusChanged
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

    func bufferChanged() {
        guard fileContents != nil else { return }
        // A baseline already loading is still valid and will use the newest buffer.
        if analyzingBuffer {
            rendering?.cancel()
            rendering = nil
            analyzingBuffer = false
        }
        retainPresentation()
        // Batch edits from the first change so steady typing still gets periodic updates.
        guard pendingBufferRefresh == nil else { return }
        pendingBufferRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            pendingBufferRefresh = nil
            if rendering == nil { render() }
        }
    }

    func bufferReplaced() {
        clearPresentation()
        render()
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
        if contents == nil { clearPresentation() }
        render()
    }

    private func filesChanged(_ paths: Set<String>?) {
        guard let url = file?.url else { return }
        let path = WorktreeFileOperations.path(url)
        guard paths == nil || paths?.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) == true else { return }
        diskMatchesBuffer = nil
        render()
    }

    private func render() {
        pendingBufferRefresh?.cancel()
        pendingBufferRefresh = nil
        rendering?.cancel()
        rendering = nil
        analyzingBuffer = false
        guard let file, let contents = fileContents, let path = contents.relativePath(to: file.url),
              !path.isEmpty else { return }
        retainPresentation()
        let state = contents.repository
        rendering = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.render(file, path: path, in: state)
            if !Task.isCancelled {
                rendering = nil
                analyzingBuffer = false
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
                clearPresentation()
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
                clearPresentation()
                return
            }
            // The current text already includes every edit queued during the read.
            pendingBufferRefresh?.cancel()
            pendingBufferRefresh = nil
            guard let current = text() else { return }
            analyzingBuffer = true
            let result = await Self.analyze(pair, text: current)
            try Task.checkCancellation()
            present(result, normalizeCRLF: pair.normalizeCRLF)
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
            setLocalStatus(JJWorkingCopyFileStatus(workspace: state.workspace, operationID: state.operationID,
                                                  commitID: state.commitID, path: path, status: status))
        } catch {
            if !Task.isCancelled { clearPresentation() }
        }
    }

    private func retainPresentation() {
        guard presentationExpiry == nil, hasVisibleMarks || localStatus != nil else { return }
        if hasVisibleMarks { suspendMarkerNavigation() }
        // The deadline belongs to the visible result, so subsequent edits cannot extend it.
        presentationExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            presentationExpiry = nil
            clearPresentation()
        }
    }

    private func present(_ result: JJTextAnalysis?, normalizeCRLF: Bool = false) {
        presentationExpiry?.cancel()
        presentationExpiry = nil
        hasVisibleMarks = result?.marks.isEmpty == false
        showMarks(result, normalizeCRLF)
    }

    private func clearPresentation() {
        present(nil)
        setLocalStatus(nil)
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

    private func setLocalStatus(_ status: JJWorkingCopyFileStatus?) {
        guard localStatus != status else { return }
        localStatus = status
        publishWorktree()
        workingCopyStatusChanged()
    }

    private func publishWorktree() {
        guard let folderContents else {
            showWorktree(nil)
            return
        }
        let override: JJWorktreeDecorations.Override?
        if let localStatus, localStatus.workspace == folderContents.repository.workspace,
           localStatus.operationID == folderContents.repository.operationID {
            override = .init(path: localStatus.path, status: localStatus.status)
        } else {
            override = nil
        }
        showWorktree(JJWorktreeDecorations(contents: folderContents, override: override))
    }

    isolated deinit {
        findingFile?.cancel()
        findingFolder?.cancel()
        pendingBufferRefresh?.cancel()
        rendering?.cancel()
        presentationExpiry?.cancel()
        monitor.unsubscribe(fileSubscription)
        monitor.unsubscribe(folderSubscription)
    }
}
