import Foundation

/// Splits a byte stream into lines, carrying a partial last line over to the next chunk.
final class LineSplitter {
    private var buffer: Data = Data()

    func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData: Data = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            lines.append(LineSplitter.decode(lineData))
        }
        // Keep indices simple for the next round.
        if buffer.startIndex != 0 { buffer = Data(buffer) }
        return lines
    }

    /// Returns whatever is left (a last line without a newline), if anything.
    func flush() -> [String] {
        if buffer.isEmpty { return [] }
        let line = LineSplitter.decode(buffer)
        buffer = Data()
        return [line]
    }

    static func decode(_ data: Data) -> String {
        var s = String(decoding: data, as: UTF8.self)
        while s.hasSuffix("\r") { s.removeLast() }
        return s
    }
}

/// State for one pipe. Only touched from that pipe's readability handler, then (after EOF) from the main queue.
private final class PipeDrain: @unchecked Sendable {
    let splitter: LineSplitter = LineSplitter()
    var raw: Data = Data()
    var done: Bool = false
}

/// Runs rclone as a child process (no shell). Reads stdout and stderr incrementally so neither pipe
/// can fill up and block the child, hands complete lines to `onLine` on the main actor (in order),
/// and tees every line into the given log file handles.
public final class RcloneRunner: @unchecked Sendable {
    public let executablePath: String
    public let arguments: [String]

    private let logHandles: [FileHandle]
    private let onLine: (@MainActor (String) -> Void)?
    private let lock: NSLock = NSLock()
    private var process: Process?
    private var stopRequested: Bool = false
    private var killRequested: Bool = false
    private var started: Bool = false

    /// - Parameters:
    ///   - logHandles: open file handles that receive every raw line (stdout and stderr). Write errors are ignored.
    ///   - onLine: called on the main actor for every stderr and stdout line, in the order read.
    public init(executablePath: String, arguments: [String], logHandles: [FileHandle] = [],
                onLine: (@MainActor (String) -> Void)? = nil) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.logHandles = logHandles
        self.onLine = onLine
    }

    /// Runs to completion and returns the exit status (-1 if rclone could not be started).
    /// All lines have been delivered to `onLine` before this returns.
    public func run() async -> Int32 {
        let result = await runCollecting(timeout: nil)
        return result.status
    }

    /// Runs and returns everything printed. For short commands like `about` and `size`.
    public func capture(timeout: TimeInterval? = 120) async -> (status: Int32, stdout: String, stderr: String) {
        let result = await runCollecting(timeout: timeout)
        return (result.status, String(decoding: result.stdout, as: UTF8.self), String(decoding: result.stderr, as: UTF8.self))
    }

    /// Convenience for one-off commands.
    public static func capture(executablePath: String, arguments: [String],
                               timeout: TimeInterval? = 120) async -> (status: Int32, stdout: String, stderr: String) {
        let runner = RcloneRunner(executablePath: executablePath, arguments: arguments)
        return await runner.capture(timeout: timeout)
    }

    /// Asks rclone to stop cleanly (SIGINT, like Ctrl-C). If it is still running after `grace`
    /// seconds, it is terminated. Safe to call before the process has started or after it ended.
    public func interrupt(grace: TimeInterval = 15) {
        lock.lock()
        stopRequested = true
        let p: Process? = process
        lock.unlock()
        guard let proc = p, proc.isRunning else { return }
        proc.interrupt()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            if proc.isRunning { proc.terminate() }
        }
    }

    /// Stops the process right away (SIGTERM).
    public func terminate() {
        lock.lock()
        stopRequested = true
        killRequested = true
        let p: Process? = process
        lock.unlock()
        guard let proc = p, proc.isRunning else { return }
        proc.terminate()
    }

    // MARK: - Internals

    private struct RawResult {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    private func runCollecting(timeout: TimeInterval?) async -> RawResult {
        return await withCheckedContinuation { (continuation: CheckedContinuation<RawResult, Never>) in
            self.start(timeout: timeout) { (result: RawResult) in
                continuation.resume(returning: result)
            }
        }
    }

    private func start(timeout: TimeInterval?, completion: @escaping (RawResult) -> Void) {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        if alreadyStarted {
            DispatchQueue.main.async { completion(RawResult(status: -1, stdout: Data(), stderr: Data())) }
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        let outDrain = PipeDrain()
        let errDrain = PipeDrain()
        let group = DispatchGroup()
        group.enter() // stdout EOF
        group.enter() // stderr EOF
        group.enter() // process exit

        outPipe.fileHandleForReading.readabilityHandler = { (handle: FileHandle) in
            let data: Data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if !outDrain.done {
                    outDrain.done = true
                    group.leave()
                }
                return
            }
            outDrain.raw.append(data)
            self.deliver(outDrain.splitter.append(data))
        }
        errPipe.fileHandleForReading.readabilityHandler = { (handle: FileHandle) in
            let data: Data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if !errDrain.done {
                    errDrain.done = true
                    group.leave()
                }
                return
            }
            errDrain.raw.append(data)
            self.deliver(errDrain.splitter.append(data))
        }
        proc.terminationHandler = { (_: Process) in
            group.leave()
        }

        do {
            try proc.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let message = "Failed to start rclone at \(executablePath): \(error.localizedDescription)"
            deliver([message])
            DispatchQueue.main.async {
                completion(RawResult(status: -1, stdout: Data(), stderr: Data(message.utf8)))
            }
            return
        }

        lock.lock()
        process = proc
        let stopEarly = stopRequested
        let killEarly = killRequested
        lock.unlock()
        if killEarly {
            proc.terminate()
        } else if stopEarly {
            interrupt()
        }

        if let limit = timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) {
                if proc.isRunning { proc.terminate() }
            }
        }

        group.notify(queue: .main) {
            // Both pipes hit EOF, so nothing else touches the drains now.
            var tail: [String] = errDrain.splitter.flush()
            tail.append(contentsOf: outDrain.splitter.flush())
            self.deliver(tail)
            let status: Int32 = proc.terminationStatus
            let result = RawResult(status: status, stdout: outDrain.raw, stderr: errDrain.raw)
            // Queued after the tail lines, so every line reaches `onLine` before completion.
            DispatchQueue.main.async {
                self.lock.lock()
                self.process = nil
                self.lock.unlock()
                completion(result)
            }
        }
    }

    /// Writes lines to the log files and forwards them to `onLine` on the main queue (FIFO keeps order).
    private func deliver(_ lines: [String]) {
        if lines.isEmpty { return }
        if !logHandles.isEmpty {
            var chunk = Data()
            for line in lines {
                chunk.append(Data(line.utf8))
                chunk.append(0x0A)
            }
            lock.lock()
            for handle in logHandles {
                do { try handle.write(contentsOf: chunk) } catch { /* a log write failure must not stop the run */ }
            }
            lock.unlock()
        }
        guard let callback = onLine else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for line in lines { callback(line) }
            }
        }
    }
}
