import Darwin
import Foundation

/// OpenSSH invokes askpass with stdin closed. Give that child one response through a private FIFO.
final class SSHPasswordInput {
    private let directory: URL
    private let descriptor: Int32

    init(password: String) throws {
        let bytes = Array((password + "\n").utf8)
        guard !password.isEmpty, !password.contains(where: { $0.isNewline || $0 == "\0" }), bytes.count <= 4096 else {
            throw HerdrTunnel.Failure.ended("Enter a single-line password of up to 4095 bytes.")
        }
        let files = FileManager.default
        let dir = files.temporaryDirectory.appendingPathComponent("swarmhub-askpass-" + UUID().uuidString)
        try files.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var fd: Int32 = -1
        do {
            let fifo = dir.appendingPathComponent("input").path
            guard mkfifo(fifo, 0o600) == 0 else { throw POSIXError(.EIO) }
            fd = open(fifo, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0, bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count else { throw POSIXError(.EIO) }
            let helper = dir.appendingPathComponent("askpass")
            let script = #"""
            #!/bin/sh
            [ "$PPID" = "$SWARMHUB_SSH_PID" ] && [ -z "${SSH_ASKPASS_PROMPT:-}" ] || exit 1
            case "$1" in *[Pp]assword:|*[Pp]assword:\ ) ;; *) exit 1 ;; esac
            dir=${0%/*}
            /bin/mv "$dir/input" "$dir/answer" 2>/dev/null || exit 1
            IFS= read -r answer < "$dir/answer" || exit 1
            printf '%s\n' "$answer"
            """#
            try Data(script.utf8).write(to: helper)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        } catch {
            if fd >= 0 { Darwin.close(fd) }
            try? files.removeItem(at: dir)
            throw error
        }
        directory = dir
        descriptor = fd
    }

    /// The wrapper records the PID before exec so a jump host's separate SSH process cannot consume the password.
    func configure(_ process: Process, arguments: [String]) {
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = directory.appendingPathComponent("askpass").path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["LC_ALL"] = "C"
        process.environment = env
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"export SWARMHUB_SSH_PID=$$; exec /usr/bin/ssh "$@""#, "ssh",
                             "-o", "BatchMode=no", "-o", "PreferredAuthentications=password,keyboard-interactive",
                             "-o", "NumberOfPasswordPrompts=1", "-o", "ControlPath=none"] + arguments
    }

    deinit {
        Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: directory)
    }
}
