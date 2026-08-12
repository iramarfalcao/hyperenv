//
//  ProcessRunner.swift
//  hyperenv
//
//  Spawning external processes, behind a protocol so the probe can be driven
//  by a scripted fake in tests.
//

import Foundation

nonisolated struct ProcessResult: Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
    let timedOut: Bool
}

nonisolated protocol ProcessRunner: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> ProcessResult
}

// MARK: - Real implementation

nonisolated struct RealProcessRunner: ProcessRunner {

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.spawnAndWait(
                        executable: executable,
                        arguments: arguments,
                        environment: environment,
                        timeout: timeout)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func spawnAndWait(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {

        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw HyperEnvError.probeSentinelMissing
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // stdin from /dev/null: an interactive zsh with a chatty rc file can
        // otherwise block forever waiting on a prompt (compinit's "insecure
        // directories" question is the usual culprit).
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], 2)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // Put the child in its own process group so a timeout can kill the
        // whole tree. An interactive shell spawns children of its own, and
        // signalling only the direct child leaves them running.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv: [UnsafeMutablePointer<CChar>?] =
            ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)

        close(outPipe[1])
        close(errPipe[1])

        guard spawnResult == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw HyperEnvError.unsupportedLoginShell(path: executable)
        }

        // Drain both pipes on their own threads. Reading them sequentially
        // deadlocks as soon as one fills its buffer.
        let outData = UnsafeDataBox()
        let errData = UnsafeDataBox()
        let group = DispatchGroup()

        for (descriptor, box) in [(outPipe[0], outData), (errPipe[0], errData)] {
            DispatchQueue.global().async(group: group) {
                var collected = Data()
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let count = read(descriptor, &buffer, buffer.count)
                    if count <= 0 { break }
                    collected.append(contentsOf: buffer[0..<count])
                }
                close(descriptor)
                box.set(collected)
            }
        }

        let timedOut = UnsafeFlagBox()
        let watchdog = DispatchWorkItem {
            timedOut.set()
            kill(-pid, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        watchdog.cancel()
        group.wait()

        let exitCode: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1

        return ProcessResult(
            exitCode: exitCode,
            standardOutput: outData.value,
            standardError: errData.value,
            timedOut: timedOut.value
        )
    }
}

// MARK: - Small thread-safe boxes

nonisolated private final class UnsafeDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        storage = data
    }
}

nonisolated private final class UnsafeFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }
}
