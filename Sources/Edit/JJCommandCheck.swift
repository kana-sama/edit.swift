import Foundation

enum JJCommandCheck {
    static func run(in directory: URL) async throws {
        let output = try await shell(
            "/usr/bin/head -c 131072 /dev/zero; /usr/bin/head -c 131072 /dev/zero >&2; exit 7", in: directory
        )
        guard output.stdout == Data(repeating: 0, count: 131072), output.stderr == output.stdout, output.status == 7 else {
            throw Failure("drain both streams and keep the exit code")
        }
        do {
            _ = try await shell("/usr/bin/head -c 131072 /dev/zero", in: directory, limit: 4096)
            throw Failure("stop a read command at the output limit")
        } catch JJCommand.Failure.outputTooLarge {}

        do {
            _ = try await shell("exec 1>&- 2>&-; exec /bin/sleep 5", in: directory, timeout: 0.2)
            throw Failure("time out a process that closes its streams before exiting")
        } catch JJCommand.Failure.timedOut {}

        let reading = directory.appending(path: "read-started")
        let read = Task {
            try await shell("printf ready > \"$1\"; exec /bin/sleep 5", in: directory,
                            arguments: [reading.path])
        }
        defer { read.cancel() }
        try await waitForFile(reading)
        read.cancel()
        do {
            _ = try await read.value
            throw Failure("cancel a running read command")
        } catch is CancellationError {}

        let writing = directory.appending(path: "write-started")
        let release = directory.appending(path: "write-release")
        let write = Task {
            try await shell("""
                printf ready > "$1"
                for step in 1 2 3 4 5 6 7 8 9 10; do
                    if test -e "$2"; then printf finished; exit 0; fi
                    /bin/sleep 0.1
                done
                exit 1
                """, in: directory, arguments: [writing.path, release.path], timeout: nil)
        }
        try await waitForFile(writing)
        write.cancel()
        try Data().write(to: release)
        let finished = try await write.value
        guard finished.status == 0, finished.stdout == Data("finished".utf8) else {
            throw Failure("finish an already-running snapshot after cancellation")
        }
    }

    private static func shell(_ script: String, in directory: URL, arguments: [String] = [],
                              limit: Int = 256 * 1024, timeout: TimeInterval? = 3) async throws -> JJCommand.Output {
        try await JJCommand.run(URL(filePath: "/bin/sh"), arguments: ["-c", script, "edit-check"] + arguments,
                                in: directory, limit: limit, timeout: timeout)
    }

    private static func waitForFile(_ file: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: file.path) {
            guard ContinuousClock.now < deadline else { throw Failure("start the child process") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct Failure: LocalizedError {
        let description: String

        init(_ description: String) { self.description = description }

        var errorDescription: String? { "Failed jj command check to \(description)." }
    }
}
