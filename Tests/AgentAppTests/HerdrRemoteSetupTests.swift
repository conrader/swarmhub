import Foundation
import Testing
@testable import AgentApp

@Suite struct HerdrRemoteSetupTests {
    private struct Remote {
        let home: URL
        let unit: URL
        let trace: URL

        init(home: URL) throws {
            self.home = home
            unit = home.appendingPathComponent(".config/systemd/user/swarmhub-herdr.service")
            trace = home.appendingPathComponent("trace")
            let bin = home.appendingPathComponent(".local/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let commands = [
                "hc": "exit 0",
                "swarmhub-herdr": "exit 0",
                "curl": #"""
                    if [ "$1" = -s ]; then [ "$SETUP_OCCUPIED" = yes ]; fi
                    """#,
                "systemctl": #"""
                    printf 'systemctl %s\n' "$*" >> "$SETUP_TRACE"
                    case "$2" in
                        is-active) test -n "$SETUP_OWN_PORT" ;;
                        show)
                            if [ "$5" = MainPID ]; then printf '1234\n'
                            else printf 'SWARMHUB_PORT=%s\n' "$SETUP_OWN_PORT"; fi
                            ;;
                    esac
                    """#,
                "ss": #"printf 'users:(("listener",pid=%s,fd=4))\n' "$SETUP_LISTENER_PID""#,
                "loginctl": #"""
                    printf 'loginctl %s\n' "$*" >> "$SETUP_TRACE"
                    if [ "$1" = show-user ]; then
                        if [ -e "$SETUP_LINGER_FILE" ]; then printf yes; else printf no; fi
                    else
                        [ "$SETUP_CAN_ENABLE" = yes ] && touch "$SETUP_LINGER_FILE"
                    fi
                    """#
            ]
            for (name, command) in commands {
                let executable = bin.appendingPathComponent(name)
                try ("#!/bin/sh\n" + command + "\n").write(to: executable, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            }
        }

        func setup(occupied: Bool = false, ownPort: Int? = nil, listenerPID: Int = 1234,
                   canEnable: Bool = false) throws -> (status: Int32, output: String, stderr: String) {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", HerdrRemoteSetup.linuxMoveSetup(port: 8787)]
            process.environment = [
                "HOME": home.path, "USER": "deployed", "PATH": "/usr/bin:/bin",
                "SETUP_TRACE": trace.path, "SETUP_OCCUPIED": occupied ? "yes" : "no",
                "SETUP_LISTENER_PID": String(listenerPID),
                "SETUP_OWN_PORT": ownPort.map(String.init) ?? "", "SETUP_CAN_ENABLE": canEnable ? "yes" : "no",
                "SETUP_LINGER_FILE": home.appendingPathComponent("linger").path
            ]
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus,
                    String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                    String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }

    private func withRemote(_ test: (Remote) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try test(Remote(home: home))
    }

    private let server = HerdrServer(id: "test", name: "VPS", kind: .ssh, address: HerdrServer.loopback(port: 8787), sshHost: "test")

    @Test func verifiesTheCandidateBeforeInstallingOrRepairingAWorkspace() throws {
        try withRemote { remote in
            let fm = FileManager.default
            let bin = remote.home.appendingPathComponent(".local/bin")
            let program = bin.appendingPathComponent("swarmhub-herdr")
            let candidate = remote.home.appendingPathComponent("candidate")
            let healthy = "#!/bin/sh\n[ \"$1 $2\" = 'version --json' ]\n"
            let broken = "#!/bin/sh\nexit 127\n"

            func install(_ contents: String, byteCount: Int? = nil) throws -> Int32 {
                let data = Data(contents.utf8)
                try data.write(to: candidate)
                let input = try FileHandle(forReadingFrom: candidate)
                defer { try? input.close() }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", HerdrRemoteSetup.placeProgram(byteCount: byteCount ?? data.count)]
                process.environment = ["HOME": remote.home.path, "PATH": "/usr/bin:/bin"]
                process.standardInput = input
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            }

            try fm.removeItem(at: program)
            #expect(try install(healthy, byteCount: 1) != 0)
            #expect(!fm.fileExists(atPath: program.path))
            #expect(try install(healthy) == 0)
            #expect(try install(healthy + "# second candidate\n") == 0)
            #expect(try String(contentsOf: program, encoding: .utf8) == healthy)
            try Data(broken.utf8).write(to: program)
            #expect(try install(broken) != 0)
            #expect(try String(contentsOf: program, encoding: .utf8) == broken)
            #expect(try install(healthy) == 0)
            #expect(try String(contentsOf: program, encoding: .utf8) == healthy)

            try fm.removeItem(at: program)
            let missing = remote.home.appendingPathComponent("missing")
            try fm.createSymbolicLink(at: program, withDestinationURL: missing)
            #expect(try install(healthy) != 0)
            #expect(try fm.destinationOfSymbolicLink(atPath: program.path) == missing.path)
            #expect(try fm.contentsOfDirectory(atPath: bin.path).allSatisfy { !$0.hasPrefix(".swarmhub-herdr.") })
        }
    }

    @Test func setupEnablesLingerAfterStartingTheServiceAndRechecksIt() throws {
        try withRemote { remote in
            let setup = try remote.setup(canEnable: true)
            #expect(setup.status == 0, Comment(rawValue: setup.stderr))
            #expect(HerdrRemoteSetup.lingerWarning(in: setup.output, for: server) == nil)
            let trace = try String(contentsOf: remote.trace, encoding: .utf8)
            #expect(trace.contains("""
            systemctl --user enable --now swarmhub-herdr.service
            loginctl show-user deployed -p Linger --value
            loginctl enable-linger deployed
            loginctl show-user deployed -p Linger --value
            """))
            let unit = try String(contentsOf: remote.unit, encoding: .utf8)
            #expect(unit.contains(#"Environment="PATH=%h/.local/bin:%h/.npm-global/bin:%h/.cargo/bin:/usr/local/bin:/usr/bin:/bin""#))
            let retry = try remote.setup(occupied: true, ownPort: 8787)
            #expect(retry.status == 0, Comment(rawValue: retry.stderr))
            #expect(HerdrRemoteSetup.lingerWarning(in: retry.output, for: server) == nil)
            let retryTrace = try String(contentsOf: remote.trace, encoding: .utf8).dropFirst(trace.count)
            #expect(retryTrace.contains("loginctl show-user deployed -p Linger --value"))
            #expect(!retryTrace.contains("loginctl enable-linger"))
        }
    }

    @Test func disabledLingerReturnsTheWarningShownInTheMoveSheet() throws {
        try withRemote { remote in
            let setup = try remote.setup()
            #expect(setup.status == 0, Comment(rawValue: setup.stderr))
            #expect(setup.output.contains("SWARMHUB_LINGER=disabled"))
            let warning = try #require(HerdrRemoteSetup.lingerWarning(in: setup.output, for: server))
            #expect(warning.contains("last SSH session") && warning.contains("reboot"))
            #expect(warning.contains("sudo loginctl enable-linger -- deployed"))
            #expect(HerdrRemoteSetup.lingerWarning(in: "echo SWARMHUB_LINGER=disabled", for: server) == nil)
        }
    }

    @Test func retryUpgradesTheExistingUnitAndRejectsAnUnrelatedListener() throws {
        try withRemote { remote in
            try FileManager.default.createDirectory(at: remote.unit.deletingLastPathComponent(), withIntermediateDirectories: true)
            let legacy = "[Service]\nEnvironment=SWARMHUB_PORT=8787\n"
            try legacy.write(to: remote.unit, atomically: true, encoding: .utf8)
            let conflict = try remote.setup(occupied: true, ownPort: 9878)
            #expect(conflict.status == 1 && conflict.stderr.contains("Port 8787 is already in use"))
            let unrelated = try remote.setup(occupied: true, ownPort: 8787, listenerPID: 4321)
            #expect(unrelated.status == 1 && unrelated.stderr.contains("Port 8787 is already in use"))
            let retry = try remote.setup(occupied: true, ownPort: 8787)
            #expect(retry.status == 0, Comment(rawValue: retry.stderr))
            #expect(try String(contentsOf: remote.unit, encoding: .utf8) == legacy)
            let dropIn = URL(fileURLWithPath: remote.unit.path + ".d/10-swarmhub-path.conf")
            #expect(try String(contentsOf: dropIn, encoding: .utf8).contains("PATH=%h/.local/bin:"))
        }
    }
}
