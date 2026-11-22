import Darwin
import Foundation

struct TerminalForegroundProcess: Sendable {
    let command: String?
    let workingDirectory: URL?

    private static let shells: Set<String> = [
        "ash", "bash", "csh", "dash", "elvish", "fish", "ksh", "nu", "oksh", "osh",
        "pwsh", "sh", "tcsh", "xonsh", "ysh", "zsh",
    ]
    private static let launchers: Set<String> = [
        "doas", "env", "node", "npm", "npx", "perl", "python", "python3", "ruby", "sudo", "time", "xcrun",
    ]

    static func inspect(shellPID: pid_t, shellName: String? = nil) -> Self? {
        guard let shell = processInfo(shellPID), shell.pbi_ppid == UInt32(getpid()) else { return nil }
        let foreground: proc_bsdinfo?
        if let group = pid_t(exactly: shell.e_tpgid), group > 0, shell.e_tpgid != shell.pbi_pgid {
            foreground = foregroundProcess(group: group, terminal: shell.e_tdev, shellName: shellName)
        } else {
            // An exec can replace the shell while keeping its PID and process group.
            foreground = shell
        }

        let name = foreground.flatMap(processName)
        let isShell = name.map { isShellName($0, expected: shellName) } ?? true
        let directoryPID = isShell ? foreground.map { pid_t($0.pbi_pid) } ?? shellPID : shellPID
        let directory = currentDirectory(of: directoryPID)
        // These are separate kernel queries. Ignore a sample if the shell or foreground job changed.
        guard let current = processInfo(shellPID),
              current.pbi_ppid == shell.pbi_ppid,
              current.pbi_start_tvsec == shell.pbi_start_tvsec,
              current.pbi_start_tvusec == shell.pbi_start_tvusec,
              current.e_tdev == shell.e_tdev, current.e_tpgid == shell.e_tpgid else { return nil }
        return Self(command: isShell ? nil : name, workingDirectory: directory)
    }

    private static func foregroundProcess(group: pid_t, terminal: UInt32, shellName: String?) -> proc_bsdinfo? {
        func member(_ pid: pid_t) -> proc_bsdinfo? {
            guard let info = processInfo(pid), info.pbi_pgid == UInt32(group), info.e_tdev == terminal else { return nil }
            return info
        }
        func isProgram(_ info: proc_bsdinfo) -> Bool {
            guard let name = processName(info) else { return false }
            return !isShellName(name, expected: shellName) && !launchers.contains(name.lowercased())
        }

        let leader = member(group)
        if let leader, isProgram(leader) { return leader }

        // Pipelines can outlive their group leader and launchers can hold the group for a child.
        let count = proc_listpgrppids(group, nil, 0)
        guard count > 0 else { return leader }
        var pids = [pid_t](repeating: 0, count: min(Int(count) + 8, 256))
        let read = pids.withUnsafeMutableBytes { proc_listpgrppids(group, $0.baseAddress, Int32($0.count)) }
        let members = pids.prefix(max(0, Int(read))).compactMap(member).sorted {
            ($0.pbi_start_tvsec, $0.pbi_start_tvusec, $0.pbi_pid) < ($1.pbi_start_tvsec, $1.pbi_start_tvusec, $1.pbi_pid)
        }
        return members.first(where: isProgram) ?? leader ?? members.first
    }

    private static func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_status != UInt32(SZOMB) else { return nil }
        return info
    }

    private static func isShellName(_ name: String, expected: String?) -> Bool {
        let normalized = name.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
        return shells.contains(normalized) || normalized == expected?.lowercased()
    }

    private static func processName(_ info: proc_bsdinfo) -> String? {
        let registered = string(from: info.pbi_name)
        let name = registered.isEmpty ? string(from: info.pbi_comm) : registered
        let printable = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return printable.isEmpty ? nil : printable
    }

    private static func currentDirectory(of pid: pid_t) -> URL? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = string(from: info.pvi_cdir.vip_path)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func string(from tuple: some Any) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
}
