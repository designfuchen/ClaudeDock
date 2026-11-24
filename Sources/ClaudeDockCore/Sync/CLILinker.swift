import Foundation

/// Links each AccountProfile to an isolated `CLAUDE_CONFIG_DIR` CLI wrapper (`claude-<slug>`)
/// with shared skills/memory and automatic Fail-Closed Egress Guard + proxy injection.
public final class CLILinker: Sendable {
    public let homeDirectory: URL
    public let binDirectory: URL
    private var fm: FileManager { .default }

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        binDirectory: URL? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.binDirectory = binDirectory ?? homeDirectory
            .appendingPathComponent(".claudedock", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    public func wrapperName(for account: AccountProfile) -> String {
        "claude-\(account.slug)"
    }

    public func wrapperURL(for account: AccountProfile) -> URL {
        binDirectory.appendingPathComponent(wrapperName(for: account))
    }

    /// Creates the isolated CLI profile directory, links shared resources from `~/.claude`,
    /// and writes the executable `claude-<slug>` wrapper script.
    @discardableResult
    public func installWrapper(for account: AccountProfile, shareResources: Bool = true, shareSessions: Bool = true) throws -> URL {
        try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let cfgDir = account.cliConfigDirectory(homeDirectory: homeDirectory)
        try fm.createDirectory(at: cfgDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        if shareResources && !account.isDefault {
            try linkSharedClaudeCodeResources(into: cfgDir)
        }
        if !account.isDefault {
            if shareSessions {
                try linkSharedSessions(into: cfgDir)
            } else {
                unlinkSharedSessions(from: cfgDir)
            }
        }

        let script = buildWrapperScript(for: account)
        let target = wrapperURL(for: account)
        try script.write(to: target, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)

        // Also expose symlink in ~/.local/bin if that directory exists and does not conflict with an unmanaged file
        let localBin = homeDirectory.appendingPathComponent(".local/bin", isDirectory: true)
        if fm.fileExists(atPath: localBin.path) {
            let link = localBin.appendingPathComponent(wrapperName(for: account))
            if let existingDest = try? fm.destinationOfSymbolicLink(atPath: link.path), existingDest == target.path {
                // Already linked cleanly
            } else if !fm.fileExists(atPath: link.path) {
                try? fm.createSymbolicLink(at: link, withDestinationURL: target)
            }
        }

        return target
    }

    public func removeWrapper(for account: AccountProfile) {
        let target = wrapperURL(for: account)
        try? fm.removeItem(at: target)

        let localLink = homeDirectory.appendingPathComponent(".local/bin/\(wrapperName(for: account))")
        if let dest = try? fm.destinationOfSymbolicLink(atPath: localLink.path), dest == target.path {
            try? fm.removeItem(at: localLink)
        }
    }

    /// Safely symlinks user-level `skills`, `agents`, `commands`, and `CLAUDE.md` from `~/.claude` into an isolated CLI profile
    /// without ever touching `.credentials.json` or `.claude.json` (which remain strictly per-account).
    public func linkSharedClaudeCodeResources(into profileConfigDir: URL) throws {
        let mainClaudeDir = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        try fm.createDirectory(at: mainClaudeDir, withIntermediateDirectories: true)

        for item in ["skills", "agents", "commands", "CLAUDE.md"] {
            let sharedSource = mainClaudeDir.appendingPathComponent(item)
            let profileDest = profileConfigDir.appendingPathComponent(item)
            guard fm.fileExists(atPath: sharedSource.path) else { continue }

            // Check if destination already exists (including broken symlinks)
            if let attrs = try? fm.attributesOfItem(atPath: profileDest.path) {
                if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                    let currentTarget = try? fm.destinationOfSymbolicLink(atPath: profileDest.path)
                    if currentTarget == sharedSource.path { continue }
                    try fm.removeItem(at: profileDest)
                } else {
                    // Never clobber user's private non-symlink directory/file
                    continue
                }
            }
            try fm.createSymbolicLink(at: profileDest, withDestinationURL: sharedSource)
        }
    }

    /// Conversation state Claude Code keeps per config dir. Sharing these lets any account resume any session;
    /// credentials (`.credentials.json`, keychain) and account settings (`.claude.json`) are never included.
    public static let sharedSessionItems = ["projects", "file-history", "plans", "todos", "tasks"]

    /// Points this profile's conversation folders at `~/.claude`.
    ///
    /// Migration never deletes anything: an existing private folder is first renamed to a unique, timestamped backup
    /// (one atomic rename), then any files missing from the shared folder are *copied* in. Copies never overwrite,
    /// never follow symlinks inside the shared tree, and the backup stays untouched for the user to keep or remove.
    public func linkSharedSessions(into profileConfigDir: URL) throws {
        let mainClaudeDir = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        for item in Self.sharedSessionItems {
            let shared = mainClaudeDir.appendingPathComponent(item, isDirectory: true)
            let local = profileConfigDir.appendingPathComponent(item, isDirectory: true)
            try fm.createDirectory(at: shared, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

            if let attrs = try? fm.attributesOfItem(atPath: local.path) {
                let type = attrs[.type] as? FileAttributeType
                if type == .typeSymbolicLink {
                    if (try? fm.destinationOfSymbolicLink(atPath: local.path)) == shared.path { continue }
                    try fm.removeItem(at: local) // only ever removes the link itself, not its target
                } else if type == .typeDirectory {
                    let backup = uniqueBackupURL(for: item, in: profileConfigDir)
                    try fm.moveItem(at: local, to: backup)
                    let failures = copyMissing(from: backup, into: shared)
                    if failures > 0 {
                        // Don't publish a shared link that would hide sessions we couldn't copy: put the folder back.
                        try? fm.moveItem(at: backup, to: local)
                        throw DockError.ioError("Could not merge \(failures) item(s) from \(local.path) into the shared history; nothing was changed.")
                    }
                } else {
                    continue // an unexpected regular file: leave it alone
                }
            }
            try fm.createSymbolicLink(at: local, withDestinationURL: shared)
        }
    }

    private func uniqueBackupURL(for item: String, in dir: URL) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var url = dir.appendingPathComponent("\(item).claudedock-backup-\(stamp)", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            url = dir.appendingPathComponent("\(item).claudedock-backup-\(stamp)-\(n)", isDirectory: true)
            n += 1
        }
        return url
    }

    /// Copies files from `source` into `destination` where nothing exists yet. Never overwrites, never deletes,
    /// and refuses to descend into or write through a symlink on the destination side.
    @discardableResult
    private func copyMissing(from source: URL, into destination: URL) -> Int {
        guard (try? fm.destinationOfSymbolicLink(atPath: destination.path)) == nil,
              let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return 1 }
        var failures = 0
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            let src = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if src?.isSymbolicLink == true { continue }
            // Anything already at the target (file, dir or link) is left exactly as it is.
            let targetIsLink = (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil
            if targetIsLink { continue }
            if src?.isDirectory == true {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: target.path, isDirectory: &isDir) {
                    if isDir.boolValue { failures += copyMissing(from: item, into: target) }
                } else if (try? fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil {
                    failures += copyMissing(from: item, into: target)
                } else {
                    failures += 1
                }
            } else if !fm.fileExists(atPath: target.path) {
                if (try? fm.copyItem(at: item, to: target)) == nil { failures += 1 }
            }
        }
        return failures
    }

    /// Stops sharing: removes only our symlinks, so the account starts with its own empty history. No data is deleted.
    public func unlinkSharedSessions(from profileConfigDir: URL) {
        let mainClaudeDir = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        for item in Self.sharedSessionItems {
            let local = profileConfigDir.appendingPathComponent(item)
            let shared = mainClaudeDir.appendingPathComponent(item)
            if (try? fm.destinationOfSymbolicLink(atPath: local.path)) == shared.path {
                try? fm.removeItem(at: local)
            }
        }
    }

    /// Thin dynamic wrapper keyed by immutable `account.id`.
    /// Delegates to `claudedock cli-run <ID> -- "$@"` so live proxy, egress policy, and NO_PROXY stripping
    /// ALWAYS reflect the latest saved configuration (never stale!).
    public func buildWrapperScript(for account: AccountProfile) -> String {
        // Only the immutable UUID appears in the script, and only as a standalone quoted argument.
        let quotedID = LauncherBuilder.shellQuote(account.id)

        return """
        #!/bin/bash
        # Generated by ClaudeDock — dynamic Claude Code wrapper for one ClaudeDock account.
        set -euo pipefail

        # Always strip inherited proxy/bypass overrides before delegating
        unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy

        for B in "/Applications/ClaudeDock.app/Contents/MacOS/claudedock" "$HOME/Applications/ClaudeDock.app/Contents/MacOS/claudedock" "/usr/local/bin/claudedock" "/opt/homebrew/bin/claudedock" "$HOME/.local/bin/claudedock"; do
          if [ -x "$B" ]; then
            exec "$B" cli-run \(quotedID) -- "$@"
          fi
        done

        printf '%s\\n' 'ClaudeDock: claudedock binary not found; refusing an unguarded launch.' >&2
        exit 1
        """
    }
}
