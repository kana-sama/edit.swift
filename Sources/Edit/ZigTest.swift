import Darwin
import Foundation

struct ZigTestDeclaration: Equatable, Sendable {
    struct Capture {
        let header: Range<Int>
        let name: Range<Int>
        let isIdentifier: Bool
    }

    var header: NSRange
    let name: String
    let namePrefix: String
    let nameLiteral: String

    static func read(_ captures: [Capture], from units: [UInt16]) -> [Self] {
        var anonymous = 0
        return captures.compactMap { capture in
            let header = NSRange(capture.header)
            guard !capture.name.isEmpty else {
                let ordinal = anonymous
                anonymous += 1
                return Self(header: header, name: "Unnamed test", namePrefix: ".test_", nameLiteral: quoted(String(ordinal)))
            }
            let token = String(decoding: units[capture.name], as: UTF16.self)
            let literal = capture.isIdentifier && token.hasPrefix("@\"") ? String(token.dropFirst()) : token
            let prefix = capture.isIdentifier ? ".decltest." : ".test."
            if literal.first == "\"", literal.last == "\"", literal.count >= 2 {
                return Self(header: header, name: String(literal.dropFirst().dropLast()), namePrefix: prefix, nameLiteral: literal)
            }
            guard capture.isIdentifier else { return nil }
            return Self(header: header, name: token, namePrefix: prefix, nameLiteral: quoted(token))
        }
    }

    static func quoted(_ string: String) -> String {
        "\"" + string.utf8.map { String(format: "\\x%02x", $0) }.joined() + "\""
    }
}

// Zig's compiler filter matches substrings. Compare the complete compiler name before invoking a test.
final class ZigTestInvocation: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let directory: URL
    private let runnerDirectory: URL

    @concurrent static func prepare(test: ZigTestDeclaration, file: URL, folder: URL?) async throws -> ZigTestInvocation {
        let environment = await launchEnvironment()
        try Task.checkCancellation()
        guard let executable = LanguageServerSession.executable(in: environment["PATH"] ?? "", named: "zig") else {
            throw RunError.zigUnavailable
        }
        let parent = file.deletingLastPathComponent()
        let discoveredRoot = LanguageServer.zig.projectRoot(in: folder ?? parent, activeFile: file, previousRoot: nil,
                                                             searchesParents: folder == nil) ?? parent
        let root = FileBuffer.canonicalURL(discoveredRoot)
        let project = await ZigProjectTest.find(executable: executable, environment: environment, directory: root, file: file)
        try Task.checkCancellation()
        return try ZigTestInvocation(test: test, file: file, directory: root, executable: executable,
                                     environment: environment, project: project)
    }

    private init(test: ZigTestDeclaration, file: URL, directory: URL, executable: URL,
                 environment: [String: String], project: ZigProjectTest?) throws {
        let prefix = ZigTestDeclaration.quoted(file.deletingPathExtension().lastPathComponent + test.namePrefix)
        let runnerDirectory = FileManager.default.temporaryDirectory.appending(path: "Edit-Zig-Test-\(UUID())",
                                                                                  directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runnerDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let runner = runnerDirectory.appending(path: "runner.zig")
        let arguments: [String]
        do {
            try Self.runner(selected: "\(prefix) ++ \(test.nameLiteral)").write(to: runner, atomically: true, encoding: .utf8)
            if let project {
                arguments = try project.arguments(executable: executable, file: file, runner: runner, staging: runnerDirectory)
            } else {
                arguments = ["test", file.path, "--test-runner", runner.path]
            }
        } catch {
            try? FileManager.default.removeItem(at: runnerDirectory)
            throw error
        }
        self.runnerDirectory = runnerDirectory
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }

    deinit { try? FileManager.default.removeItem(at: runnerDirectory) }

    var displayCommand: String {
        let command = ([executable.path] + arguments).map(Self.shellArgument).joined(separator: " ")
        return "$ cd \(Self.shellArgument(directory.path))\r\n$ \(command)"
    }

    private static func shellArgument(_ argument: String) -> String {
        let unquoted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-=+:")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(unquoted.contains) { return argument }
        if argument.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return "$'" + argument.utf8.map { String(format: "\\x%02x", $0) }.joined() + "'"
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func launchEnvironment() async -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        guard getppid() == 1 else { return inherited }
        // Tools launched from the Dock need the same exported project settings as an interactive terminal.
        if let shell = getpwuid(getuid())?.pointee.pw_shell.map({ String(cString: $0) }),
           FileManager.default.isExecutableFile(atPath: shell),
           let result = try? await JJCommand.run(URL(filePath: shell),
                arguments: ["-i", "-l", "-c", "/usr/bin/printf '\\000'; /usr/bin/env -0"],
                in: FileManager.default.homeDirectoryForCurrentUser, limit: 512 * 1024, timeout: 5),
           result.status == 0, let start = result.stdout.firstIndex(of: 0) {
            let exports = result.stdout.suffix(from: result.stdout.index(after: start)).split(separator: 0)
            var environment = inherited
            for field in exports {
                guard let assignment = String(data: Data(field), encoding: .utf8),
                      let equals = assignment.firstIndex(of: "="), equals != assignment.startIndex else { continue }
                environment[String(assignment[..<equals])] = String(assignment[assignment.index(after: equals)...])
            }
            return environment
        }
        return await LanguageServerSession.launchEnvironment()
    }

    private enum RunError: LocalizedError {
        case zigUnavailable

        var errorDescription: String? { "Zig was not found on PATH." }
    }

    private static func runner(selected: String) -> String {
        """
        const std = @import("std");
        const builtin = @import("builtin");
        const selected = \(selected);
        var logged_error = std.atomic.Value(bool).init(false);
        pub const std_options: std.Options = .{ .logFn = log };
        pub const main = if (@hasDecl(std.testing, "io_instance")) mainWithEnvironment else mainLegacy;

        fn mainWithEnvironment(init: std.process.Init.Minimal) !void {
            return runSelected(init);
        }

        fn mainLegacy() !void {
            return runSelected({});
        }

        fn runSelected(init: anytype) !void {
            for (builtin.test_functions) |test_fn| {
                if (!std.mem.eql(u8, test_fn.name, selected)) continue;
                return run(test_fn, init);
            }
            std.debug.print("Test not found: {s}\\n", .{selected});
            return error.TestNotFound;
        }

        fn run(test_fn: anytype, init: anytype) !void {
            if (@hasDecl(std.testing, "io_instance")) {
                std.testing.allocator_instance = .init(std.heap.page_allocator, .{});
                std.testing.io_instance = .init(std.testing.allocator, .{ .argv0 = .init(init.args), .environ = init.environ });
                if (@hasDecl(std.testing, "environ")) std.testing.environ = init.environ;
            } else {
                std.testing.allocator_instance = .{};
            }
            std.debug.print("{s}\\n", .{test_fn.name});
            const result = test_fn.func();
            if (@hasDecl(std.testing, "io_instance")) std.testing.io_instance.deinit();
            const leaks = std.testing.allocator_instance.deinit();
            if (if (@TypeOf(leaks) == usize) leaks != 0 else leaks != .ok) return error.TestLeakedMemory;
            if (logged_error.load(.monotonic)) return error.TestLoggedError;
            result catch |err| {
                if (err != error.SkipZigTest) return err;
                std.debug.print("Skipped\\n", .{});
                return;
            };
            std.debug.print("Passed\\n", .{});
        }

        fn log(comptime level: std.log.Level, comptime scope: @TypeOf(.default),
            comptime format: []const u8, args: anytype) void {
            if (level == .err) logged_error.store(true, .monotonic);
            std.log.defaultLog(level, scope, format, args);
        }

        pub fn fuzz(context: anytype, comptime testOne: anytype, options: anytype) !void {
            if (@hasDecl(std.testing, "Smith")) {
                for (options.corpus) |input| {
                    var smith: std.testing.Smith = .{ .in = input };
                    try testOne(context, &smith);
                }
                var smith: std.testing.Smith = .{ .in = "" };
                try testOne(context, &smith);
            } else {
                for (options.corpus) |input| try testOne(context, input);
                try testOne(context, "");
            }
        }
        """
    }
}
