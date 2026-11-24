import Darwin
import Dispatch
import Foundation
import Synchronization

struct LSPDocument: Sendable {
    let url: URL?
    let text: String
    let revision: Int
}

struct LSPWorkDoneActivity: Equatable, Sendable {
    let title: String
    var message: String?
    var percentage: Int?
}

struct LSPCapabilities: Decodable, Sendable {
    enum Change: Int, Decodable { case none, full, incremental }

    let definition: Bool
    let references: Bool
    let hover: Bool
    let documentHighlight: Bool
    let documentSymbols: Bool
    let workspaceSymbols: Bool
    let rename: Bool
    let prepareRename: Bool
    let openClose: Bool
    let change: Change
    let positionEncoding: String

    private enum CodingKeys: String, CodingKey {
        case definitionProvider, referencesProvider, hoverProvider, textDocumentSync, positionEncoding
        case documentHighlightProvider, documentSymbolProvider, workspaceSymbolProvider, renameProvider
    }

    private struct SyncOptions: Decodable {
        let openClose: Bool?
        let change: Change?
    }

    private struct RenameOptions: Decodable { let prepareProvider: Bool? }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func supports(_ key: CodingKeys) -> Bool {
            if let enabled = try? values.decode(Bool.self, forKey: key) { return enabled }
            return (try? values.nestedContainer(keyedBy: CodingKeys.self, forKey: key)) != nil
        }
        definition = supports(.definitionProvider)
        references = supports(.referencesProvider)
        hover = supports(.hoverProvider)
        documentHighlight = supports(.documentHighlightProvider)
        documentSymbols = supports(.documentSymbolProvider)
        workspaceSymbols = supports(.workspaceSymbolProvider)
        rename = supports(.renameProvider)
        prepareRename = (try? values.decode(RenameOptions.self, forKey: .renameProvider))?.prepareProvider == true
        positionEncoding = try values.decodeIfPresent(String.self, forKey: .positionEncoding) ?? "utf-16"
        if let kind = try? values.decode(Change.self, forKey: .textDocumentSync) {
            openClose = kind != .none
            change = kind
        } else {
            let options = try values.decodeIfPresent(SyncOptions.self, forKey: .textDocumentSync)
            openClose = options?.openClose ?? false
            change = options?.change ?? .none
        }
    }
}

enum LSPFailure: LocalizedError {
    case unavailable, invalidPosition, invalidMessage, timedOut(String), server(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "ZLS is not ready."
        case .invalidPosition: "The position is no longer in the document."
        case .invalidMessage: "ZLS sent an invalid response."
        case .timedOut(let method): "ZLS did not respond to \(method)."
        case .server(let reason): reason
        }
    }
}

/// Owns one process and its ordered LSP byte streams. Process state, framing, and pending
/// continuations are confined to queue. DispatchIO keeps stalled reads and writes off that queue.
final class LanguageServerConnection: @unchecked Sendable {
    private enum Request: Sendable {
        case initialize, definition(Int), references(Int, Bool), hover(Int)
        case documentHighlight(Int), documentSymbols, workspaceSymbols(String)
        case prepareRename(Int), rename(Int, String)

        var method: String {
            switch self {
            case .initialize: "initialize"
            case .definition: "textDocument/definition"
            case .references: "textDocument/references"
            case .hover: "textDocument/hover"
            case .documentHighlight: "textDocument/documentHighlight"
            case .documentSymbols: "textDocument/documentSymbol"
            case .workspaceSymbols: "workspace/symbol"
            case .prepareRename: "textDocument/prepareRename"
            case .rename: "textDocument/rename"
            }
        }
    }

    private enum MessageID: Codable, Hashable {
        case string(String), integer(Int)

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let integer = try? value.decode(Int.self) { self = .integer(integer) }
            else { self = .string(try value.decode(String.self)) }
        }

        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .integer(let integer): try value.encode(integer)
            case .string(let string): try value.encode(string)
            }
        }

        var value: Any {
            switch self {
            case .string(let string): string
            case .integer(let integer): integer
            }
        }
    }

    private struct Message: Decodable {
        struct Failure: Decodable { let message: String }
        let id: MessageID?
        let method: String?
        let error: Failure?
    }

    private struct ProgressToken: Decodable {
        let token: MessageID
    }

    private struct ProgressNotification: Decodable {
        struct Value: Decodable {
            enum Kind: String, Decodable { case begin, report, end }

            let kind: Kind
            let title: String?
            let message: String?
            let percentage: Int?
        }

        let token: MessageID
        let value: Value
    }

    private struct WorkDoneProgress {
        let token: MessageID
        var activity: LSPWorkDoneActivity?
    }

    private struct Reply<Value: Decodable>: Decodable { let result: Value? }
    private struct Initialize: Decodable {
        struct ServerInfo: Decodable {
            let name: String
            let version: String?
        }

        let capabilities: LSPCapabilities
        let serverInfo: ServerInfo?

        var dropsClosedFilesFromWorkspace: Bool { serverInfo?.name == "zls" && serverInfo?.version == "0.17.0" }
    }
    private struct DocumentHighlight: Decodable { let range: LSPRange }

    private struct Definitions: Decodable {
        let locations: [LSPLocation]

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let one = try? value.decode(LSPLocation.self) { locations = [one] }
            else { locations = try value.decode([LSPLocation].self) }
        }
    }

    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: DispatchWorkItem
    }

    private let queue = DispatchQueue(label: "Edit.ZLS.Connection", qos: .utility)
    private let executable: URL
    private let root: URL
    private let environment: [String: String]
    private let onFailure: @Sendable (String) -> Void
    let progress: AsyncStream<[LSPWorkDoneActivity]>
    private let progressUpdates: AsyncStream<[LSPWorkDoneActivity]>.Continuation
    private let decoder = JSONDecoder()
    private var process: Process?
    private var input: DispatchIO?
    private var output: DispatchIO?
    private var standardError: DispatchIO?
    private var errorOutput = Data()
    private var buffer = Data()
    private var contentLength: Int?
    private var pending: [String: Pending] = [:]
    private var workDone: [WorkDoneProgress] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownID: String?
    private var stopping = false
    private var closed = false
    private var capabilities: LSPCapabilities?
    private var dropsClosedFilesFromWorkspace = false
    private var workspaceSymbolsNeedRefresh = false
    private var document: LSPDocument?
    private var index: LSPTextIndex?

    init(executable: URL, root: URL, environment: [String: String], onFailure: @escaping @Sendable (String) -> Void) {
        self.executable = executable
        self.root = root
        self.environment = environment
        self.onFailure = onFailure
        (progress, progressUpdates) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func start() async throws -> LSPCapabilities {
        try await onQueue { try self.launch() }
        let response = try await request(.initialize, timeout: 15)
        guard let result = try JSONDecoder().decode(Reply<Initialize>.self, from: response).result else {
            throw LSPFailure.invalidMessage
        }
        let capabilities = result.capabilities
        guard capabilities.positionEncoding == "utf-16" else {
            throw LSPFailure.server("ZLS selected an unsupported position encoding.")
        }
        try await onQueue {
            guard !self.stopping else { throw CancellationError() }
            try self.notify("initialized", [:])
            self.capabilities = capabilities
            self.dropsClosedFilesFromWorkspace = result.dropsClosedFilesFromWorkspace
        }
        return capabilities
    }

    func updateDocument(_ snapshot: LSPDocument) {
        queue.async {
            guard !self.stopping, !self.closed, self.capabilities != nil else { return }
            do { try self.synchronize(snapshot) }
            catch is CancellationError { return }
            catch { self.fail(error.localizedDescription) }
        }
    }

    func definition(at offset: Int, in snapshot: LSPDocument) async throws -> [LSPLocation] {
        let response = try await request(.definition(offset), document: snapshot)
        let locations = try JSONDecoder().decode(Reply<Definitions>.self, from: response).result?.locations ?? []
        return Self.fileLocations(locations)
    }

    func references(at offset: Int, includeDeclaration: Bool, in snapshot: LSPDocument) async throws -> [LSPLocation] {
        let response = try await request(.references(offset, includeDeclaration), document: snapshot)
        let locations = try JSONDecoder().decode(Reply<[LSPLocation]>.self, from: response).result ?? []
        return Self.fileLocations(locations)
    }

    func hover(at offset: Int, in snapshot: LSPDocument) async throws -> LSPHover? {
        let response = try await request(.hover(offset), document: snapshot)
        let hover = try JSONDecoder().decode(Reply<LSPHover>.self, from: response).result
        return hover.flatMap { $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    func documentHighlights(at offset: Int, in snapshot: LSPDocument) async throws -> [NSRange] {
        let response = try await request(.documentHighlight(offset), document: snapshot)
        let ranges = try JSONDecoder().decode(Reply<[DocumentHighlight]>.self, from: response).result?.map(\.range) ?? []
        return try await onQueue {
            guard let index = self.index, self.document?.revision == snapshot.revision else { throw CancellationError() }
            return ranges.compactMap { index.nsRange($0, clampingColumns: false) }
        }
    }

    func documentSymbols(in snapshot: LSPDocument) async throws -> [LSPSymbol] {
        guard let url = snapshot.url else { throw LSPFailure.unavailable }
        let response = try await request(.documentSymbols, document: snapshot)
        let result = try JSONDecoder().decode(Reply<LSPDocumentSymbols>.self, from: response).result
        return result?.symbols(in: url).filter { $0.location.url.standardizedFileURL == url } ?? []
    }

    func workspaceSymbols(query: String, synchronizing snapshot: LSPDocument) async throws -> [LSPSymbol] {
        let response = try await request(.workspaceSymbols(query), document: snapshot, timeout: 15)
        let result = try JSONDecoder().decode(Reply<[LSPDocumentSymbols.SymbolInformation]>.self, from: response).result
        return result?.map(\.symbol).filter { $0.location.url.isFileURL } ?? []
    }

    func prepareRename(at offset: Int, in snapshot: LSPDocument) async throws -> LSPPreparedRename? {
        let response = try await request(.prepareRename(offset), document: snapshot)
        return try JSONDecoder().decode(Reply<LSPPreparedRename>.self, from: response).result
    }

    func rename(at offset: Int, to name: String, in snapshot: LSPDocument) async throws -> LSPWorkspaceEdit? {
        let response = try await request(.rename(offset, name), document: snapshot, timeout: 15)
        return try JSONDecoder().decode(Reply<LSPWorkspaceEdit>.self, from: response).result
    }

    private static func fileLocations(_ locations: [LSPLocation]) -> [LSPLocation] {
        var seen = Set<LSPLocation>()
        return locations.filter { location in
            guard location.url.isFileURL, location.range.start.line >= 0, location.range.start.character >= 0,
                  location.range.start <= location.range.end else { return false }
            return seen.insert(LSPLocation(url: location.url.standardizedFileURL, range: location.range)).inserted
        }
    }

    private func onQueue<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }

    private var workspace: [String: String] {
        ["uri": root.absoluteString, "name": root.lastPathComponent]
    }

    private func request(_ request: Request, document snapshot: LSPDocument? = nil,
                         timeout: TimeInterval = 5) async throws -> Data {
        let id = UUID().uuidString
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !cancelled.withLock({ $0 }) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.beginRequest(request, id: id, snapshot: snapshot, timeout: timeout, continuation: continuation)
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
            queue.async { self.cancelRequest(id, error: CancellationError()) }
        }
    }

    private func beginRequest(_ request: Request, id: String, snapshot: LSPDocument?, timeout: TimeInterval,
                              continuation: CheckedContinuation<Data, Error>) {
        do {
            guard !stopping, !closed else { throw CancellationError() }
            if let snapshot { try synchronize(snapshot) }
            if case .workspaceSymbols = request, workspaceSymbolsNeedRefresh {
                // ZLS 0.17.0 drops a document from its workspace index on didClose.
                // Reload once before the next search, even if several documents closed.
                try notify("workspace/didChangeWorkspaceFolders", ["event": ["added": [], "removed": [workspace]]])
                try notify("workspace/didChangeWorkspaceFolders", ["event": ["added": [workspace], "removed": []]])
                workspaceSymbolsNeedRefresh = false
            }
            let params = try parameters(for: request)
            try send(["id": id, "method": request.method, "params": params])
            let expiry = DispatchWorkItem { [weak self] in
                self?.cancelRequest(id, error: LSPFailure.timedOut(request.method))
            }
            pending[id] = Pending(continuation: continuation, timeout: expiry)
            queue.asyncAfter(deadline: .now() + timeout, execute: expiry)
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func parameters(for request: Request) throws -> [String: Any] {
        if case .initialize = request {
            return ["processId": ProcessInfo.processInfo.processIdentifier, "rootUri": root.absoluteString,
                    "workspaceFolders": [workspace], "clientInfo": ["name": "Edit"],
                    "capabilities": ["general": ["positionEncodings": ["utf-16"]],
                                     "window": ["workDoneProgress": true],
                                     "workspace": ["workspaceFolders": true, "workspaceEdit": ["documentChanges": true]],
                                     "textDocument": ["definition": ["linkSupport": true],
                                                      "hover": ["contentFormat": ["markdown", "plaintext"]],
                                                      "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                                                      "rename": ["prepareSupport": true]]]]
        }
        if case .workspaceSymbols(let query) = request { return ["query": query] }
        guard let url = document?.url else { throw LSPFailure.invalidPosition }
        var params: [String: Any] = ["textDocument": ["uri": url.absoluteString]]
        let offset: Int
        switch request {
        case .initialize, .workspaceSymbols: return [:]
        case .documentSymbols: return params
        case .definition(let value), .references(let value, _), .hover(let value), .documentHighlight(let value),
             .prepareRename(let value), .rename(let value, _): offset = value
        }
        guard let position = index?.position(at: offset) else { throw LSPFailure.invalidPosition }
        params["position"] = position.parameters
        if case .references(_, let include) = request { params["context"] = ["includeDeclaration": include] }
        if case .rename(_, let name) = request { params["newName"] = name }
        return params
    }

    private func synchronize(_ snapshot: LSPDocument) throws {
        guard let capabilities else { throw LSPFailure.unavailable }
        if let document, snapshot.revision <= document.revision {
            if snapshot.revision < document.revision { throw CancellationError() }
            return
        }
        let previous = document
        if previous?.url != snapshot.url, capabilities.openClose {
            if let previousURL = previous?.url {
                try notify("textDocument/didClose", ["textDocument": ["uri": previousURL.absoluteString]])
                if dropsClosedFilesFromWorkspace { workspaceSymbolsNeedRefresh = true }
            }
            if let url = snapshot.url {
                try notify("textDocument/didOpen", ["textDocument": ["uri": url.absoluteString, "languageId": "zig",
                                                                   "version": snapshot.revision, "text": snapshot.text]])
            }
        } else if let url = snapshot.url, let previous, capabilities.change != .none,
                  !previous.text.utf8.elementsEqual(snapshot.text.utf8) {
            var change: [String: Any] = ["text": snapshot.text]
            if capabilities.change == .incremental, let index { change["range"] = index.fullRange.parameters }
            try notify("textDocument/didChange", ["textDocument": ["uri": url.absoluteString, "version": snapshot.revision],
                                                 "contentChanges": [change]])
        }
        document = snapshot
        index = snapshot.url.map { _ in LSPTextIndex(snapshot.text) }
    }

    private func launch() throws {
        guard !closed, !stopping else { throw CancellationError() }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        // An unexpected server exit must not make a queued pipe write signal the editor.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        process.executableURL = executable
        process.currentDirectoryURL = root
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            self?.queue.async { [weak self] in self?.processExited(status) }
        }
        try process.run()
        self.process = process
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        input = channel(for: stdin.fileHandleForWriting)
        output = channel(for: stdout.fileHandleForReading)
        standardError = channel(for: stderr.fileHandleForReading)
        output?.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            self?.receive(data, done: done, error: error)
        }
        standardError?.read(offset: 0, length: Int.max, queue: queue) { [weak self] _, data, _ in
            guard let self, let data, !data.isEmpty, !self.closed else { return }
            self.errorOutput.append(Data(data))
            if self.errorOutput.count > 8_192 { self.errorOutput.removeFirst(self.errorOutput.count - 8_192) }
        }
    }

    private func channel(for handle: FileHandle) -> DispatchIO {
        let channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in
            try? handle.close()
        }
        channel.setLimit(highWater: 32 * 1024)
        channel.setLimit(lowWater: 1)
        return channel
    }

    private func send(_ message: [String: Any]) throws {
        guard let input, !closed else { throw LSPFailure.unavailable }
        var message = message
        message["jsonrpc"] = "2.0"
        let payload = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        var wire = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        wire.append(payload)
        let bytes = wire.withUnsafeBytes { DispatchData(bytes: $0) }
        input.write(offset: 0, data: bytes, queue: queue) { [weak self] _, _, error in
            guard let self, error != 0, !self.stopping, !self.closed else { return }
            self.fail("Could not send a message to ZLS.")
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) throws {
        try send(["method": method, "params": params])
    }

    private func receive(_ data: DispatchData?, done: Bool, error: Int32) {
        guard !closed else { return }
        if error == 0 {
            do {
                if let data { buffer.append(Data(data)) }
                try readMessages()
            } catch {
                fail(error.localizedDescription)
                return
            }
        }
        // The process-exit callback supplies the normal exit reason. If stdout closes while
        // the process remains alive, the connection is broken even if the process hangs on.
        if done || error != 0 {
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, !self.closed, !self.stopping else { return }
                self.fail("ZLS closed its communication stream.")
            }
        }
    }

    private func readMessages() throws {
        let separator = Data("\r\n\r\n".utf8)
        while !buffer.isEmpty {
            if contentLength == nil {
                guard let boundary = buffer.range(of: separator) else {
                    if buffer.count > 8_192 { throw LSPFailure.invalidMessage }
                    return
                }
                let header = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self)
                let lengths = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
                    let fields = line.split(separator: ":", maxSplits: 1)
                    guard fields.count == 2, fields[0].lowercased() == "content-length" else { return nil }
                    return Int(fields[1].trimmingCharacters(in: .whitespaces))
                }
                guard lengths.count == 1, let length = lengths.first, (1...(64 * 1024 * 1024)).contains(length) else {
                    throw LSPFailure.invalidMessage
                }
                contentLength = length
                buffer.removeSubrange(..<boundary.upperBound)
            }
            guard let length = contentLength, buffer.count >= length else { return }
            let message = Data(buffer.prefix(length))
            buffer.removeFirst(length)
            contentLength = nil
            try handleMessage(message)
        }
    }

    private func handleMessage(_ data: Data) throws {
        let message = try decoder.decode(Message.self, from: data)
        if let method = message.method {
            guard let id = message.id?.value else {
                if method == "$/progress", !stopping,
                   let notification = try? decoder.decode(Parameters<ProgressNotification>.self, from: data) {
                    updateProgress(notification.params)
                }
                return
            }
            if method == "workspace/workspaceFolders" {
                try send(["id": id, "result": [workspace]])
            } else if method == "window/workDoneProgress/create" {
                if let request = try? decoder.decode(Parameters<ProgressToken>.self, from: data) {
                    if !stopping, !workDone.contains(where: { $0.token == request.params.token }) {
                        workDone.append(WorkDoneProgress(token: request.params.token))
                    }
                    try send(["id": id, "result": NSNull()])
                } else {
                    try send(["id": id, "error": ["code": -32602, "message": "Invalid progress token"]])
                }
            } else {
                try send(["id": id, "error": ["code": -32601, "message": "Unsupported method"]])
            }
        } else if case .string(let id) = message.id {
            if id == shutdownID {
                shutdownID = nil
                try send(["method": "exit"])
                input?.close()
            } else if let request = pending.removeValue(forKey: id) {
                request.timeout.cancel()
                if let error = message.error {
                    request.continuation.resume(throwing: LSPFailure.server(error.message))
                } else {
                    request.continuation.resume(returning: data)
                }
            }
        }
    }

    private struct Parameters<Value: Decodable>: Decodable { let params: Value }

    private func updateProgress(_ notification: ProgressNotification) {
        guard let index = workDone.firstIndex(where: { $0.token == notification.token }) else { return }
        let value = notification.value
        let percentage = value.percentage.flatMap { (0...100).contains($0) ? $0 : nil }
        let previous = workDone[index].activity
        switch value.kind {
        case .begin:
            guard let title = value.title, !title.isEmpty else { return }
            workDone[index].activity = LSPWorkDoneActivity(title: title, message: value.message, percentage: percentage)
        case .report:
            guard var activity = previous else { return }
            activity.message = value.message ?? activity.message
            activity.percentage = percentage ?? activity.percentage
            guard activity != previous else { return }
            workDone[index].activity = activity
        case .end:
            workDone.remove(at: index)
            guard previous != nil else { return }
        }
        progressUpdates.yield(workDone.compactMap(\.activity))
    }

    private func cancelRequest(_ id: String, error: Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        try? notify("$/cancelRequest", ["id": id])
        request.continuation.resume(throwing: error)
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.closed, self.process != nil else {
                    self.finish(error: CancellationError())
                    continuation.resume()
                    return
                }
                self.stopWaiters.append(continuation)
                if !self.stopping { self.beginStop() }
            }
        }
    }

    private func beginStop() {
        stopping = true
        for id in Array(pending.keys) { cancelRequest(id, error: CancellationError()) }
        guard let capabilities else {
            killProcess()
            return
        }
        do {
            if capabilities.openClose, let url = document?.url {
                try notify("textDocument/didClose", ["textDocument": ["uri": url.absoluteString]])
            }
            let id = UUID().uuidString
            shutdownID = id
            try send(["id": id, "method": "shutdown"])
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.killProcess() }
        } catch {
            killProcess()
        }
    }

    private func killProcess() {
        if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    private func processExited(_ status: Int32) {
        if stopping {
            finish(error: CancellationError())
        } else {
            let lastLine = String(decoding: errorOutput, as: UTF8.self).split(whereSeparator: \.isNewline).last
            fail(lastLine.map { String($0.prefix(240)) } ?? "ZLS exited (\(status)).")
        }
    }

    private func fail(_ reason: String) {
        guard !closed else { return }
        let shouldReport = !stopping
        killProcess()
        finish(error: LSPFailure.server(reason))
        if shouldReport { onFailure(reason) }
    }

    private func finish(error: Error) {
        guard !closed else { return }
        closed = true
        progressUpdates.finish()
        workDone.removeAll()
        process?.terminationHandler = nil
        process = nil
        input?.close(flags: .stop)
        output?.close(flags: .stop)
        standardError?.close(flags: .stop)
        input = nil
        output = nil
        standardError = nil
        for request in pending.values {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
        pending.removeAll()
        for waiter in stopWaiters { waiter.resume() }
        stopWaiters.removeAll()
    }
}
