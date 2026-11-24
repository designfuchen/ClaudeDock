import AppKit
import Darwin
import Foundation

/// Controls macOS windows & lifecycle for specific Claude Desktop account instances by verified PID.
/// Hardened against PID reuse races, root-spawning-helper races during SIGSTOP, and unsafe SIGCONT on frozen leaks.
public final class WindowController: @unchecked Sendable {
    private let processManager: ProcessManager
    private let lifecycleLock = NSLock()

    public init(processManager: ProcessManager = ProcessManager()) {
        self.processManager = processManager
    }

    /// Brings the exact macOS Claude Desktop window(s) for `account` to the foreground.
    @discardableResult
    public func focus(account: AccountProfile) -> Bool {
        let state = processManager.runningState(for: account)
        guard let pid = state.pids.first, !state.isFrozen, isVerifiedClaudePID(pid) else {
            return false
        }

        // Native activation first: instant and needs no Automation permission.
        if let app = NSRunningApplication(processIdentifier: pid) {
            if app.isHidden { app.unhide() }
            if app.activate(options: [.activateAllWindows]) { return true }
        }
        // Fallback only when native activation was refused.
        return raiseWindows(pid: pid)
    }

    /// Freezes the entire Claude Desktop process tree for `account` with SIGSTOP.
    /// Stops root processes FIRST so they cannot spawn replacement helpers, then iterates until all descendants are stopped.
    @discardableResult
    public func freeze(account: AccountProfile) -> Int {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        var stoppedPIDs = Set<Int32>()
        // Up to 3 passes until no unstopped descendants remain
        for _ in 0..<3 {
            let all = processManager.allProcesses()
            let roots = processManager.matchingMainProcesses(for: account, in: all).map(\.pid)
            guard !roots.isEmpty else { break }

            // Stop roots first so they can't fork new helpers while we enumerate children
            for rootPID in roots where !stoppedPIDs.contains(rootPID) {
                if isVerifiedClaudePID(rootPID), kill(rootPID, SIGSTOP) == 0 {
                    stoppedPIDs.insert(rootPID)
                }
            }

            let tree = ProcessManager.processTreePIDs(rootPIDs: roots, in: all)
            let parents = Dictionary(all.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
            var newlyStopped = 0
            // Parents come before children (BFS), so each child is checked against an already-stopped parent.
            for pid in tree where !stoppedPIDs.contains(pid) {
                if isSignalable(pid, snapshotParent: parents[pid], handled: stoppedPIDs), kill(pid, SIGSTOP) == 0 {
                    stoppedPIDs.insert(pid)
                    newlyStopped += 1
                }
            }
            if newlyStopped == 0 && tree.allSatisfy({ stoppedPIDs.contains($0) }) {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return stoppedPIDs.count
    }

    /// Resumes a previously frozen Claude Desktop process tree with SIGCONT.
    @discardableResult
    public func resume(account: AccountProfile) -> Int {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let all = processManager.allProcesses()
        let roots = processManager.matchingMainProcesses(for: account, in: all).map(\.pid)
        guard !roots.isEmpty else { return 0 }
        let tree = ProcessManager.processTreePIDs(rootPIDs: roots, in: all)
        let parents = Dictionary(all.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        var handled = Set<Int32>()
        var count = 0
        for pid in tree {
            guard isSignalable(pid, snapshotParent: parents[pid], handled: handled) else { continue }
            handled.insert(pid)
            if kill(pid, SIGCONT) == 0 {
                count += 1
            }
        }
        return count
    }

    /// Terminates a specific Claude Desktop instance.
    /// If the instance is currently FROZEN (e.g., stopped due to unsafe egress),
    /// we terminate the verified stopped process tree directly with SIGKILL WITHOUT sending SIGCONT,
    /// preventing it from leaking packets during shutdown.
    @discardableResult
    public func quit(account: AccountProfile, timeoutSeconds: Double = 6.0) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let all = processManager.allProcesses()
        let mains = processManager.matchingMainProcesses(for: account, in: all)
        guard !mains.isEmpty else { return true }

        let roots = mains.map(\.pid)
        if mains.allSatisfy(\.isStopped) {
            // Never SIGCONT a frozen, unsafe account: kill its verified lineage directly (children first),
            // so paused helpers (Claude Code, MCP servers) don't linger stopped forever.
            let tree = ProcessManager.processTreePIDs(rootPIDs: roots, in: all)
            let parents = Dictionary(all.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
            var handled = Set<Int32>()
            var lineage: [Int32] = []
            for pid in tree where isSignalable(pid, snapshotParent: parents[pid], handled: handled) {
                handled.insert(pid)
                lineage.append(pid)
            }
            for pid in lineage.reversed() {
                _ = kill(pid, SIGKILL)
            }
            Thread.sleep(forTimeInterval: 0.2)
            return !processManager.runningState(for: account).isActive
        }

        for pid in roots where isVerifiedClaudePID(pid) {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.terminate()
            } else {
                _ = kill(pid, SIGTERM)
            }
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !processManager.runningState(for: account).isActive {
                return true
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        // Re-query fresh PIDs (never reuse stale PIDs across timeout!) before fallback SIGTERM
        let remaining = processManager.matchingMainProcesses(for: account).map(\.pid)
        for pid in remaining where isVerifiedClaudePID(pid) {
            _ = kill(pid, SIGTERM)
        }
        Thread.sleep(forTimeInterval: 0.2)
        return !processManager.runningState(for: account).isActive
    }

    /// Gracefully quits all running Claude Desktop instances (and kills frozen unsafe instances without unfreezing).
    @discardableResult
    public func quitAllClaudeDesktop(timeoutSeconds: Double = 8.0) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let all = processManager.allProcesses()
        let mains = processManager.allClaudeDesktopMainProcesses(in: all)
        guard !mains.isEmpty else { return true }

        let parents = Dictionary(all.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        for proc in mains where isVerifiedClaudePID(proc.pid) {
            if proc.isStopped {
                // Same lineage rule as quit(account:): frozen helpers outside Claude.app (MCP servers, Claude Code)
                // were SIGSTOPped with the tree, so they must be killed with it or they stay stopped forever.
                let tree = ProcessManager.processTreePIDs(rootPIDs: [proc.pid], in: all)
                var handled = Set<Int32>()
                var lineage: [Int32] = []
                for pid in tree where isSignalable(pid, snapshotParent: parents[pid], handled: handled) {
                    handled.insert(pid)
                    lineage.append(pid)
                }
                for p in lineage.reversed() {
                    _ = kill(p, SIGKILL)
                }
            } else if let app = NSRunningApplication(processIdentifier: proc.pid) {
                app.terminate()
            } else {
                _ = kill(proc.pid, SIGTERM)
            }
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if processManager.allClaudeDesktopMainProcesses().isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return processManager.allClaudeDesktopMainProcesses().isEmpty
    }

    /// Whether `pid` may receive a signal as part of this account's process tree:
    /// - a verified Claude.app executable (kernel `proc_pidpath`), or
    /// - a helper Claude started (bundled Claude Code, MCP servers…) whose *live* parent, read from the kernel right
    ///   now, is the same already-verified process the snapshot said — so a recycled PID can never be signalled.
    private func isSignalable(_ pid: Int32, snapshotParent: Int32?, handled: Set<Int32>) -> Bool {
        if isVerifiedClaudePID(pid) { return true }
        guard let parent = snapshotParent, handled.contains(parent),
              let live = Self.liveParentPID(of: pid), live == parent else { return false }
        return true
    }

    /// The parent PID of a running process, straight from the kernel; nil if it is gone.
    public static func liveParentPID(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
    }

    /// Verifies via macOS kernel `proc_pidpath` that `pid` is actually a Claude.app executable before signaling.
    private func isVerifiedClaudePID(_ pid: Int32) -> Bool {
        var pathBuf = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        guard len > 0 else { return false }
        let path = String(decoding: pathBuf.prefix(Int(len)), as: UTF8.self)
        return path.contains("/Claude.app/")
    }

    @discardableResult
    private func raiseWindows(pid: Int32) -> Bool {
        let script = """
        tell application "System Events"
            set targetProcs to every process whose unix id is \(pid)
            if (count of targetProcs) > 0 then
                set frontmost of item 1 of targetProcs to true
            end if
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return false
        }
        // osascript can hang (e.g. while macOS shows an Automation prompt). Never read terminationStatus
        // of a running task — Foundation raises an uncatchable exception. Stop it, wait, then read.
        guard ProcessWait.wait(proc, timeout: 1.5) else { return false }
        return proc.terminationStatus == 0
    }
}

/// Waits for a `Process` with a deadline. On timeout: SIGTERM, then SIGKILL, and waits until it has really exited,
/// so reading `terminationStatus` afterwards is always safe. Returns false if it had to be killed.
enum ProcessWait {
    static func wait(_ proc: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.03) }
        guard proc.isRunning else { return true }
        proc.terminate()
        let killAt = Date().addingTimeInterval(0.5)
        while proc.isRunning && Date() < killAt { Thread.sleep(forTimeInterval: 0.03) }
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        proc.waitUntilExit()
        return false
    }
}
