import Darwin
import Dispatch
import Foundation

/// Collect a command's two streams and its exit status on a single event queue.
final class JJCommand: @unchecked Sendable {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    enum Failure: Error {
        case timedOut, outputTooLarge
    }

    private enum Stream: Int {
        case stdout, stderr
    }

    private let queue = DispatchQueue(label: "Edit.Jujutsu.Command", qos: .utility)
    private let executable: URL
    private let arguments: [String]
    private let directory: URL
    private let limit: Int
    private let timeout: TimeInterval?

    // All mutable state belongs to queue, including the cancellation and exit paths.
    private var continuation: CheckedContinuation<Output, Error>?
    private var process: Process?
    private var timer: DispatchSourceTimer?
    private var channels: [DispatchIO?] = [nil, nil]
    private var buffers = [Data(), Data()]
    private var exitStatus: Int32?
    private var cancelled = false

    private init(executable: URL, arguments: [String], directory: URL, limit: Int, timeout: TimeInterval?) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.limit = limit
        self.timeout = timeout
    }

    static func run(_ executable: URL, arguments: [String], in directory: URL,
                    limit: Int, timeout: TimeInterval?) async throws -> Output {
        let command = JJCommand(executable: executable, arguments: arguments, directory: directory,
                                limit: limit, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                command.queue.async { command.start(continuation) }
            }
        } onCancel: {
            command.queue.async { command.cancel() }
        }
    }

    private func start(_ continuation: CheckedContinuation<Output, Error>) {
        guard !cancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [self] process in
            let status = process.terminationStatus
            queue.async { self.exited(status) }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            finish(.failure(error))
            return
        }
        self.process = process
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        read(stdout.fileHandleForReading, stream: .stdout)
        read(stderr.fileHandleForReading, stream: .stderr)

        if let timeout {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.finish(.failure(Failure.timedOut)) }
            timer.schedule(deadline: .now() + timeout)
            self.timer = timer
            timer.activate()
        }
    }

    private func read(_ handle: FileHandle, stream: Stream) {
        let channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in
            try? handle.close()
        }
        channel.setLimit(highWater: 32 * 1024)
        channels[stream.rawValue] = channel
        channel.read(offset: 0, length: Int.max, queue: queue) { [self] done, data, error in
            receive(data, from: stream, done: done, error: error)
        }
    }

    private func receive(_ data: DispatchData?, from stream: Stream, done: Bool, error: Int32) {
        guard continuation != nil else { return }
        guard error == 0 else {
            finish(.failure(NSError(domain: NSPOSIXErrorDomain, code: Int(error))))
            return
        }
        let index = stream.rawValue
        if let data, !data.isEmpty {
            let remaining = (stream == .stdout ? limit : 2 * 1024 * 1024) - buffers[index].count
            if data.count > remaining, timeout != nil {
                finish(.failure(Failure.outputTooLarge))
                return
            }
            if data.count <= remaining {
                buffers[index].append(Data(data))
            } else if remaining > 0 {
                buffers[index].append(Data(data.subdata(in: 0..<remaining)))
            }
        }
        if done {
            channels[index]?.close()
            channels[index] = nil
            finishIfComplete()
        }
    }

    private func exited(_ status: Int32) {
        exitStatus = status
        finishIfComplete()
    }

    private func finishIfComplete() {
        if let exitStatus, channels.allSatisfy({ $0 == nil }) {
            finish(.success(Output(status: exitStatus, stdout: buffers[0], stderr: buffers[1])))
        }
    }

    private func cancel() {
        cancelled = true
        // An already-started snapshot owns its repository write until it exits.
        if timeout != nil { finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<Output, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        if let process {
            process.terminationHandler = nil
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process = nil
        for channel in channels { channel?.close(flags: .stop) }
        channels = [nil, nil]
        buffers = [Data(), Data()]
        continuation.resume(with: result)
    }
}
