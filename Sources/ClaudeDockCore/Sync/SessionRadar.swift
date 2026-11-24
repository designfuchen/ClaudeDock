import Darwin
import Foundation

public struct LiveClaudeSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let pid: Int32
    public let accountName: String
    public let status: String
    public let name: String
    public let hostSessionID: String?
    public let cwd: String?

    public init(
        id: String,
        pid: Int32,
        accountName: String,
        status: String,
        name: String,
        hostSessionID: String?,
        cwd: String?
    ) {
        self.id = id
        self.pid = pid
        self.accountName = accountName
        self.status = status
        self.name = name
        self.hostSessionID = hostSessionID
        self.cwd = cwd
    }
}

/// Discovers live Claude Code sessions across all Desktop accounts and CLI profiles,
/// and creates clean structured handoff briefs for cross-account collaboration.
public final class SessionRadar: Sendable {
    private let homeDirectory: URL
    private var fm: FileManager { .default }

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func discoverLiveSessions(accounts: [AccountProfile]) -> [LiveClaudeSession] {
        var sessionDirs: [(dir: URL, explicitAccount: String?)] = [
            (homeDirectory.appendingPathComponent(".claude/sessions", isDirectory: true), nil)
        ]
        for acc in accounts where !acc.isDefault {
            let cliSessions = acc.cliConfigDirectory(homeDirectory: homeDirectory)
                .appendingPathComponent("sessions", isDirectory: true)
            sessionDirs.append((cliSessions, acc.name))
        }

        var seenPIDs = Set<Int32>()
        var results: [LiveClaudeSession] = []

        for entry in sessionDirs {
            guard let files = try? fm.contentsOfDirectory(at: entry.dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for file in files where file.pathExtension == "json" {
                let stem = file.deletingPathExtension().lastPathComponent
                // pid <= 0 would make kill() address a process group, which always "exists".
                guard let pid = Int32(stem), pid > 0, !seenPIDs.contains(pid), kill(pid, 0) == 0 else {
                    continue
                }
                guard let data = try? Data(contentsOf: file),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                seenPIDs.insert(pid)
                let hostID = obj["hostSessionId"] as? String
                let status = (obj["status"] as? String) ?? "active"
                let name = (obj["name"] as? String) ?? "(unnamed)"
                let cwd = obj["cwd"] as? String
                let owner = entry.explicitAccount ?? resolveDesktopOwner(hostSessionID: hostID, accounts: accounts)

                results.append(LiveClaudeSession(
                    id: "\(pid)",
                    pid: pid,
                    accountName: owner,
                    status: status,
                    name: name,
                    hostSessionID: hostID,
                    cwd: cwd
                ))
            }
        }

        return results.sorted { ($0.accountName, $0.name) < ($1.accountName, $1.name) }
    }

    /// Generates a clean, self-contained Handoff Brief ready to paste or send via `SendMessage`.
    public static func buildHandoffBrief(
        fromAccount: String,
        toAccount: String,
        taskSummary: String,
        workingDirectory: String? = nil,
        completedSteps: [String] = [],
        remainingSteps: [String] = []
    ) -> String {
        var lines: [String] = [
            "## Cross-Account Session Handoff (\(fromAccount) -> \(toAccount))",
            "",
            "**Task**: \(taskSummary)",
        ]
        if let dir = workingDirectory, !dir.isEmpty {
            lines.append("**Workspace**: `\(dir)`")
        }
        if !completedSteps.isEmpty {
            lines.append("")
            lines.append("### Already Completed")
            for step in completedSteps { lines.append("- [x] \(step)") }
        }
        if !remainingSteps.isEmpty {
            lines.append("")
            lines.append("### Remaining Work")
            for step in remainingSteps { lines.append("- [ ] \(step)") }
        }
        lines.append("")
        lines.append("### Continuation Rules")
        lines.append("- Inspect existing workspace files and git status before editing.")
        lines.append("- Do not repeat completed commands or external side effects.")
        lines.append("- Verify any uncertain tool outcomes before re-running.")
        lines.append("- Report concise results when finished.")
        return lines.joined(separator: "\n") + "\n"
    }

    private func resolveDesktopOwner(hostSessionID: String?, accounts: [AccountProfile]) -> String {
        guard let rawHost = hostSessionID, !rawHost.isEmpty else {
            return "terminal"
        }
        let needle = rawHost.hasPrefix("local_") ? String(rawHost.dropFirst("local_".count)) : rawHost
        for acc in accounts {
            let sessDir = acc.userDataDirectory(homeDirectory: homeDirectory)
                .appendingPathComponent("claude-code-sessions", isDirectory: true)
            if directoryContains(sessDir, substring: needle) {
                return acc.name
            }
        }
        // Fallback: scan ~/Library/Application Support/Claude*
        let support = homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        if let dirs = try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for dir in dirs where dir.lastPathComponent == "Claude" || dir.lastPathComponent.hasPrefix("Claude-") {
                let sessDir = dir.appendingPathComponent("claude-code-sessions", isDirectory: true)
                if directoryContains(sessDir, substring: needle) {
                    let base = dir.lastPathComponent
                    return base == "Claude" ? "default" : String(base.dropFirst("Claude-".count))
                }
            }
        }
        return "unknown"
    }

    private func directoryContains(_ root: URL, substring: String) -> Bool {
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return false
        }
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "json" else { continue }
            if fileURL.lastPathComponent.contains(substring) {
                return true
            }
            if let text = try? String(contentsOf: fileURL, encoding: .utf8), text.contains(substring) {
                return true
            }
        }
        return false
    }
}
