import Foundation

public struct SubprocessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool
}

/// Deadlock-free subprocess runner that drains stdout & stderr concurrently with strict timeout and output cap.
public enum SubprocessRunner {
    public static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        stdinData: Data? = nil,
        timeoutSeconds: Double = 10.0,
        maxOutputBytes: Int = 2 << 20
    ) async throws -> SubprocessResult {
        let state = RunState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let proc = Process()
                    proc.executableURL = executableURL
                    proc.arguments = arguments
                    if let environment { proc.environment = environment }
                    if let currentDirectoryURL { proc.currentDirectoryURL = currentDirectoryURL }

                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    proc.standardOutput = outPipe
                    proc.standardError = errPipe

                    var inPipe: Pipe?
                    if stdinData != nil {
                        let p = Pipe()
                        // A child that exits before reading must not SIGPIPE (and kill) us.
                        _ = fcntl(p.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                        proc.standardInput = p
                        inPipe = p
                    } else {
                        proc.standardInput = FileHandle.nullDevice
                    }

                    guard state.attach(proc) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        try proc.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }

                    // Throwing write: a closed pipe becomes an error, never an uncatchable ObjC exception.
                    if let stdinData, let inPipe {
                        DispatchQueue.global(qos: .userInitiated).async {
                            try? inPipe.fileHandleForWriting.write(contentsOf: stdinData)
                            try? inPipe.fileHandleForWriting.close()
                        }
                    }

                    // Drain stdout and stderr CONCURRENTLY to eliminate 64KB pipe buffer deadlocks
                    let drainGroup = DispatchGroup()
                    drainGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        readCapped(outPipe.fileHandleForReading, maxBytes: maxOutputBytes) { state.appendStdout($0) }
                        drainGroup.leave()
                    }
                    drainGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        readCapped(errPipe.fileHandleForReading, maxBytes: 256 * 1024) { state.appendStderr($0) }
                        drainGroup.leave()
                    }

                    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
                    timer.schedule(deadline: .now() + timeoutSeconds)
                    timer.setEventHandler {
                        if proc.isRunning {
                            state.markTimedOut()
                            state.terminate()
                        }
                    }
                    timer.resume()

                    proc.waitUntilExit()
                    timer.cancel()
                    // A descendant that inherited stdout/stderr (an MCP server, a helper) can hold the pipes open
                    // long after the child exits. Give the drains a short grace period, then return what arrived.
                    _ = drainGroup.wait(timeout: .now() + 2.0)

                    let out = state.snapshot()
                    continuation.resume(returning: SubprocessResult(
                        exitCode: proc.terminationStatus,
                        stdout: out.stdout,
                        stderr: out.stderr,
                        timedOut: out.timedOut
                    ))
                }
            }
        } onCancel: {
            // Cancelling the Swift task also stops the child process.
            state.cancel()
        }
    }

    /// Shared state between the runner thread, drain threads, timer and cancellation — always behind a lock.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var proc: Process?
        private var cancelled = false
        private var timedOut = false
        private var stdout = Data()
        private var stderr = Data()

        func attach(_ p: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if cancelled { return false }
            proc = p
            return true
        }
        func appendStdout(_ d: Data) { lock.lock(); stdout.append(d); lock.unlock() }
        func appendStderr(_ d: Data) { lock.lock(); stderr.append(d); lock.unlock() }
        func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }
        func snapshot() -> (stdout: Data, stderr: Data, timedOut: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (stdout, stderr, timedOut)
        }
        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
            terminate()
        }
        func terminate() {
            lock.lock(); let p = proc; lock.unlock()
            guard let p, p.isRunning else { return }
            p.terminate()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
                if p.isRunning { _ = kill(p.processIdentifier, SIGKILL) }
            }
        }
    }

    /// Streams chunks to `sink` as they arrive (so a stalled pipe still yields what was read), capped at `maxBytes`.
    private static func readCapped(_ handle: FileHandle, maxBytes: Int, sink: (Data) -> Void) {
        var collected = 0
        // POSIX read returns whatever is available (FileHandle.read(upToCount:) waits to fill the whole buffer),
        // and an I/O error simply ends the loop instead of raising an ObjC exception.
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            if collected < maxBytes {
                let take = min(n, maxBytes - collected)
                collected += take
                sink(Data(buffer[0..<take]))
            }
            // Keep draining even if capped so child process never blocks on SIGPIPE/full buffer
        }
    }
}
