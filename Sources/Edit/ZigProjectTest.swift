import Foundation

struct ZigProjectTest: Sendable {
    private let library: URL
    private let configurer: String
    private let relativeFile: String

    static func find(executable: URL, environment: [String: String], directory: URL, file: URL) async -> Self? {
        guard file.pathComponents.starts(with: directory.pathComponents),
              FileManager.default.fileExists(atPath: directory.appending(path: "build.zig").path),
              let library = await libraryPath(executable: executable, environment: environment, directory: directory),
              let configurer = try? String(contentsOf: library.appending(path: "compiler/configurer.zig"), encoding: .utf8) else {
            return nil
        }
        let hook = "    builder.runPackageScript(root);"
        // Zig 0.17 builds its configurer from this source. Keep the toolchain's own build
        // configuration pipeline and add one step before it serializes the project graph.
        guard let insertion = configurer.range(of: hook),
              configurer.range(of: hook, range: insertion.upperBound..<configurer.endIndex) == nil else { return nil }
        var source = configurer
        source.insert(contentsOf: "\n    try editSelectTest(builder);", at: insertion.upperBound)
        let relativeFile = file.pathComponents.dropFirst(directory.pathComponents.count).joined(separator: "/")
        return Self(library: library, configurer: source, relativeFile: relativeFile)
    }

    func cacheInputs(executable: URL, file: URL) -> [String] {
        [library.path, configuration(executable: executable, file: file, runner: URL(filePath: "/runner.zig"), step: "edit-selected-test")]
    }

    func arguments(executable: URL, file: URL, runner: URL, generated: URL, staging: URL?) throws -> [String] {
        let overlay = generated.appending(path: "zig-lib", directoryHint: .isDirectory)
        let step = "edit-selected-test-\(generated.lastPathComponent.prefix(16))"
        if let staging {
            let stagedOverlay = staging.appending(path: "zig-lib", directoryHint: .isDirectory)
            let compiler = stagedOverlay.appending(path: "compiler", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: compiler, withIntermediateDirectories: true)
            try linkEntries(in: library, to: stagedOverlay, excluding: "compiler")
            try linkEntries(in: library.appending(path: "compiler", directoryHint: .isDirectory), to: compiler, excluding: "configurer.zig")
            try configuration(executable: executable, file: file, runner: runner, step: step)
                .write(to: compiler.appending(path: "configurer.zig"), atomically: true, encoding: .utf8)
        }
        return ["build", "--zig-lib=\(overlay.path)", step, "--summary", "all"]
    }

    private func configuration(executable: URL, file: URL, runner: URL, step: String) -> String {
        configurer + "\n" + selector(executable: executable, file: file, runner: runner, step: step)
    }

    private static func libraryPath(executable: URL, environment: [String: String], directory: URL) async -> URL? {
        if let override = environment["ZIG_LIB_DIR"], !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory, relativeTo: directory).standardizedFileURL
        }
        guard let result = try? await JJCommand.run(executable, arguments: ["env"], in: directory,
                                                    limit: 64 * 1024, timeout: 5),
              result.status == 0, let output = String(data: result.stdout, encoding: .utf8) else { return nil }
        for line in output.split(separator: "\n") {
            let field = line.trimmingCharacters(in: .whitespaces)
            guard let prefix = [".lib_dir = ", "\"lib_dir\":"].first(where: field.hasPrefix) else { continue }
            let value = field.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            let literal = value.hasSuffix(",") ? value.dropLast() : value[...]
            guard let path = try? JSONDecoder().decode(String.self, from: Data(literal.utf8)),
                  path.hasPrefix("/") else { return nil }
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return nil
    }

    private func linkEntries(in directory: URL, to target: URL, excluding name: String) throws {
        let files = FileManager.default
        let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for entry in entries where entry.lastPathComponent != name {
            try files.createSymbolicLink(at: target.appending(path: entry.lastPathComponent), withDestinationURL: entry)
        }
    }

    private func selector(executable: URL, file: URL, runner: URL, step: String) -> String {
        let relative = ZigTestDeclaration.quoted(relativeFile)
        let absolute = ZigTestDeclaration.quoted(file.path)
        let executable = ZigTestDeclaration.quoted(executable.path)
        let runner = ZigTestDeclaration.quoted(runner.path)
        return """
        fn editFindTestRun(step: *Step, builder: *std.Build, visited: *std.AutoHashMap(*Step, void), selected: *?*Step.Run) !void {
            if ((try visited.getOrPut(step)).found_existing) return;
            if (step.cast(Step.Run)) |run| {
                if (run.producer) |artifact| {
                    if (artifact.kind == .@"test" and editMatchesTestSource(artifact, builder)) {
                        const target = artifact.rootModuleTarget();
                        const host = builder.graph.host.result;
                        if (target.cpu.arch == host.cpu.arch and target.os.tag == host.os.tag) {
                            if (selected.* != null) return error.AmbiguousTestArtifact;
                            selected.* = run;
                        }
                    }
                }
            }
            for (step.dependencies.items) |dependency| try editFindTestRun(dependency, builder, visited, selected);
        }

        fn editMatchesTestSource(artifact: *Step.Compile, builder: *std.Build) bool {
            const source = artifact.root_module.root_source_file orelse return false;
            return switch (source) {
                .src_path => |path| path.owner == builder and mem.eql(u8, path.sub_path, \(relative)),
                .cwd_relative => |path| mem.eql(u8, path, \(absolute)) or mem.eql(u8, path, \(relative)),
                else => false,
            };
        }

        fn editSelectTest(builder: *std.Build) !void {
            var visited = std.AutoHashMap(*Step, void).init(builder.allocator);
            defer visited.deinit();
            var selected: ?*Step.Run = null;
            if (builder.top_level_steps.get("test")) |test_step| {
                try editFindTestRun(&test_step.step, builder, &visited, &selected);
            }
            const step = builder.step("\(step)", "Run the selected test");
            if (selected) |run| {
                const artifact = run.producer.?;
                if (artifact.test_runner != null or run.stdio != .zig_test) return error.CustomProjectTestRunner;
                artifact.test_runner = .{ .path = .{ .cwd_relative = \(runner) }, .mode = .simple };
                run.stdio = .inherit;
                run.has_side_effects = true;
                step.dependOn(&run.step);
            } else {
                const run = builder.addSystemCommand(&.{ \(executable), "test", \(absolute), "--test-runner", \(runner) });
                run.stdio = .inherit;
                step.dependOn(&run.step);
            }
        }
        """
    }
}
