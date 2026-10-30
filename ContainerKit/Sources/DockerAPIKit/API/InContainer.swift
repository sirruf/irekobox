import Foundation
import ContainerKit

/// Runs a command inside a running container over XPC, the way `container
/// exec` does (the container's environment, working directory and user), but
/// without a CLI process per run: health probes and /etc/hosts writes do this
/// every few seconds.
enum InContainer {
    struct Result: Sendable {
        let code: Int32
        /// Stdout and stderr together, up to `limit` bytes.
        let output: Data
    }

    static func run(_ command: [String], in container: Container, input: Data? = nil,
                    backend: DockerBackend, limit: Int = 4096) async throws -> Result {
        guard let executable = command.first, !executable.isEmpty else {
            throw DockerAPIError.badParameter("empty command")
        }
        let process = container.configuration.initProcess
        let spec = ProcessSpec(executable: executable, arguments: Array(command.dropFirst()),
                               environment: process.environment,
                               workingDirectory: process.workingDirectory.isEmpty ? "/" : process.workingDirectory,
                               user: process.user ?? .id(uid: 0, gid: 0))
        let id = "ib-run-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let output = Pipe()
        let stdin = input == nil ? nil : Pipe()
        // A process that exits without reading its input must not take this
        // one down with SIGPIPE when we write it.
        if let stdin { _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }
        let stdio = ProcessStdio(stdin: stdin?.fileHandleForReading.fileDescriptor,
                                 stdout: output.fileHandleForWriting.fileDescriptor,
                                 stderr: output.fileHandleForWriting.fileDescriptor)
        do {
            try await backend.createProcess(container.id, process: id, spec: spec, stdio: stdio)
        } catch {
            try? output.fileHandleForWriting.close()
            try? stdin?.fileHandleForReading.close()
            try? stdin?.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            throw error
        }
        // The runtime holds its own copies now; ours would keep the pipes open.
        try? output.fileHandleForWriting.close()
        try? stdin?.fileHandleForReading.close()
        let reader = Task.detached { () -> Data in
            var kept = Data()
            let handle = output.fileHandleForReading
            while let chunk = try? handle.read(upToCount: 64 << 10), !chunk.isEmpty {
                if kept.count < limit { kept.append(chunk.prefix(limit - kept.count)) }
            }
            try? handle.close()
            return kept
        }
        do {
            try await backend.startProcess(container.id, process: id)
        } catch {
            try? stdin?.fileHandleForWriting.close()
            reader.cancel()
            throw error
        }
        if let input, let writer = stdin?.fileHandleForWriting {
            try? writer.write(contentsOf: input)
            try? writer.close()
        }
        let exit = try await backend.waitProcess(container.id, process: id)
        // The output ends when the runtime closes its end after the exit;
        // don't hang on a runtime that keeps it a while.
        let captured = await withTaskGroup(of: Data?.self) { group in
            group.addTask { await reader.value }
            group.addTask { try? await Task.sleep(for: .seconds(1)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return Result(code: exit.code, output: captured ?? Data())
    }
}
