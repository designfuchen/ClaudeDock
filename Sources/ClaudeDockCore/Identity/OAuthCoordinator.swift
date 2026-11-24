import Foundation

public struct OAuthConflictCheck: Equatable, Sendable {
    public let conflictingAccounts: [String]
    public let hasUnmanagedClaude: Bool

    public var hasConflicts: Bool {
        !conflictingAccounts.isEmpty || hasUnmanagedClaude
    }

    public var guidanceMessage: String {
        if !hasConflicts {
            return "No other Claude Desktop windows are running. Browser OAuth callback will route cleanly to this account."
        }
        var parts: [String] = []
        if !conflictingAccounts.isEmpty {
            parts.append("running accounts: \(conflictingAccounts.joined(separator: ", "))")
        }
        if hasUnmanagedClaude {
            parts.append("unmanaged Claude.app window")
        }
        return "macOS routes claude:// OAuth callbacks to the first running Claude Desktop process (\(parts.joined(separator: " + "))). Temporarily quit other windows before signing in to prevent cross-window login."
    }
}

/// Coordinates safe OAuth sign-in (preventing claude:// callback hijack) and safe Claude.app updates (quit-all -> update -> restore).
public final class OAuthAndUpdateCoordinator: Sendable {
    private let processManager: ProcessManager
    private let windowController: WindowController

    public init(
        processManager: ProcessManager = ProcessManager(),
        windowController: WindowController = WindowController()
    ) {
        self.processManager = processManager
        self.windowController = windowController
    }

    /// Checks whether other Claude Desktop windows might intercept the `claude://` browser OAuth callback.
    public func checkOAuthConflicts(targetAccount: AccountProfile, allAccounts: [AccountProfile]) -> OAuthConflictCheck {
        let allProcs = processManager.allProcesses()
        let allMains = processManager.allClaudeDesktopMainProcesses(in: allProcs)
        var matchedPIDs = Set<Int32>()
        var conflicts: [String] = []

        for acc in allAccounts {
            let matched = processManager.matchingMainProcesses(for: acc, in: allProcs)
            for p in matched { matchedPIDs.insert(p.pid) }
            if acc.id != targetAccount.id && !matched.isEmpty {
                conflicts.append(acc.name)
            }
        }

        let unmanaged = allMains.contains { !matchedPIDs.contains($0.pid) }
        return OAuthConflictCheck(conflictingAccounts: conflicts, hasUnmanagedClaude: unmanaged)
    }

    /// Prepares a clean state for updating `/Applications/Claude.app`:
    /// 1. Records all currently open managed account IDs
    /// 2. Gracefully quits every Claude Desktop instance so Sparkle/Squirrel update succeeds without corruption
    public func prepareForUpdate(accounts: [AccountProfile]) -> (savedAccountIDs: [String], allClosed: Bool) {
        let states = processManager.allRunningStates(for: accounts)
        let openIDs = accounts.filter { states[$0.id]?.isActive == true }.map(\.id)
        let closed = windowController.quitAllClaudeDesktop(timeoutSeconds: 8.0)
        return (openIDs, closed)
    }
}
