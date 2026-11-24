import Foundation

public struct ProcessSnapshot: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let state: String
    public let commandLine: String

    public init(pid: Int32, ppid: Int32, state: String, commandLine: String) {
        self.pid = pid
        self.ppid = ppid
        self.state = state
        self.commandLine = commandLine
    }

    public var isStopped: Bool {
        state.contains("T")
    }
}

/// Discovers running Claude Desktop processes and maps each PID cleanly to its AccountProfile.
public final class ProcessManager: Sendable {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    /// Reads current process table using `/bin/ps`.
    public func allProcesses() -> [ProcessSnapshot] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,ppid=,state=,command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return Self.parsePSOutput(output)
    }

    public static func parsePSOutput(_ output: String) -> [ProcessSnapshot] {
        var result: [ProcessSnapshot] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Fields: PID PPID STATE COMMAND...
            let parts = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else {
                continue
            }
            let state = String(parts[2])
            let cmd = String(parts[3])
            result.append(ProcessSnapshot(pid: pid, ppid: ppid, state: state, commandLine: cmd))
        }
        return result
    }

    /// Finds the main Claude Desktop browser process(es) belonging to an AccountProfile.
    public func matchingMainProcesses(
        for account: AccountProfile,
        in processes: [ProcessSnapshot]? = nil
    ) -> [ProcessSnapshot] {
        let list = processes ?? allProcesses()
        let expectedDir = account.userDataDirectory(homeDirectory: homeDirectory).path
        return Self.matchMainProcesses(
            expectedUserDataDir: expectedDir,
            isDefault: account.isDefault,
            in: list
        )
    }

    /// Pure matching function for deterministic unit testing.
    public static func matchMainProcesses(
        expectedUserDataDir: String,
        isDefault: Bool,
        in processes: [ProcessSnapshot]
    ) -> [ProcessSnapshot] {
        let flagPrefix = "--user-data-dir="
        var matched: [ProcessSnapshot] = []

        for proc in processes {
            let cmd = proc.commandLine
            // Must be the main Claude Desktop executable, not a Helper renderer/GPU subprocess
            guard cmd.contains("/Claude.app/Contents/MacOS/Claude") else { continue }
            guard !cmd.contains("--type=") else { continue }

            if let extracted = extractUserDataDir(from: cmd, flagPrefix: flagPrefix) {
                if normalizePath(extracted) == normalizePath(expectedUserDataDir) {
                    matched.append(proc)
                }
            } else if isDefault {
                // Default Claude.app launch passes no --user-data-dir flag
                matched.append(proc)
            }
        }
        return matched
    }

    /// Collects the main process and all descendant helper processes (Renderer, GPU, Network) for freeze/resume.
    public static func processTreePIDs(rootPIDs: [Int32], in processes: [ProcessSnapshot]) -> [Int32] {
        var childrenByParent: [Int32: [Int32]] = [:]
        for p in processes {
            childrenByParent[p.ppid, default: []].append(p.pid)
        }
        var visited = Set<Int32>()
        var queue = rootPIDs
        var ordered: [Int32] = []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard !visited.contains(current) else { continue }
            visited.insert(current)
            ordered.append(current)
            if let kids = childrenByParent[current] {
                queue.append(contentsOf: kids)
            }
        }
        return ordered
    }

    public func runningState(for account: AccountProfile, in processes: [ProcessSnapshot]? = nil) -> RunningState {
        let matched = matchingMainProcesses(for: account, in: processes)
        guard !matched.isEmpty else { return .stopped }
        let pids = matched.map(\.pid)
        if matched.allSatisfy(\.isStopped) {
            return .frozen(pids: pids)
        }
        return .running(pids: pids)
    }

    public func allRunningStates(for accounts: [AccountProfile]) -> [String: RunningState] {
        let snapshot = allProcesses()
        var out: [String: RunningState] = [:]
        for acc in accounts {
            out[acc.id] = runningState(for: acc, in: snapshot)
        }
        return out
    }

    /// Finds any running Claude Desktop main process (even unmanaged ones).
    public func allClaudeDesktopMainProcesses(in processes: [ProcessSnapshot]? = nil) -> [ProcessSnapshot] {
        let list = processes ?? allProcesses()
        return list.filter { $0.commandLine.contains("/Claude.app/Contents/MacOS/Claude") && !$0.commandLine.contains("--type=") }
    }

    public static func extractUserDataDir(from commandLine: String, flagPrefix: String = "--user-data-dir=") -> String? {
        guard let range = commandLine.range(of: flagPrefix) else { return nil }
        let after = commandLine[range.upperBound...]
        // Next Electron flag starts with " --"
        if let nextFlag = after.range(of: " --") {
            return String(after[..<nextFlag.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(after).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizePath(_ p: String) -> String {
        URL(fileURLWithPath: p).standardizedFileURL.path
    }
}
