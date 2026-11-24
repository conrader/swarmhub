import Foundation

extension AppStore {
    /// Installs a signed workspace build for the SSH account, then uses the service's own setup commands.
    func installHerdrMoveDestination(_ server: HerdrServer) async throws -> String? {
        let password = herdrTunnels.password(for: server)
        let platform = try await HerdrTunnel.run("uname -s && uname -m", on: server, password: password)
        let target: String
        let mac: Bool
        switch platform {
        case "Darwin\narm64": target = "aarch64-macos"; mac = true
        case "Darwin\nx86_64": target = "x86_64-macos"; mac = true
        case "Linux\nx86_64": target = "x86_64-linux"; mac = false
        case "Linux\naarch64": target = "aarch64-linux"; mac = false
        default: throw BackendError.unavailable("Automatic setup is unavailable for this server’s operating system or processor.")
        }

        let installed = try await HerdrTunnel.run(
            #"if test -x "$HOME/.local/bin/swarmhub-herdr"; then printf yes; fi"#, on: server, password: password
        )
        if installed != "yes" {
            let release = try await WorkspaceRelease.latest()
            let program = try await release.downloadProgram(for: target, progress: { _ in })
            try Task.checkCancellation()

            // Use a file on stdin so the program never appears in process arguments or in a remote command.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("workspace")
            try program.write(to: file)
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            _ = try await HerdrTunnel.run(#"""
                set -eu
                umask 077
                bin="$HOME/.local/bin"
                mkdir -p "$bin"
                draft=$(mktemp "$bin/.swarmhub-herdr.XXXXXX")
                trap 'rm -f "$draft"' EXIT
                cat > "$draft"
                test "$(wc -c < "$draft" | tr -d ' ')" = "\#(program.count)"
                chmod 700 "$draft"
                ln "$draft" "$bin/swarmhub-herdr"
                """#, on: server, password: password, timeout: .seconds(180), standardInput: input)
        }

        if mac {
            _ = try await HerdrTunnel.run(#"""
                "$HOME/.local/bin/swarmhub-herdr" service install --port \#(server.port)
                """#, on: server, password: password, timeout: .seconds(180))
            return nil
        }
        let output = try await HerdrTunnel.run(HerdrRemoteSetup.linuxMoveSetup(port: server.port), on: server,
                                               password: password, timeout: .seconds(180))
        return HerdrRemoteSetup.lingerWarning(in: output, for: server)
    }
}

enum HerdrRemoteSetup {
    static func lingerWarning(in output: String, for server: HerdrServer) -> String? {
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.contains("SWARMHUB_LINGER=disabled") else { return nil }
        let prefix = "SWARMHUB_LINGER_USER="
        let reportedUser = lines.last { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        let user = [reportedUser, server.sshUser].compactMap { $0 }.first { !$0.isEmpty && HerdrTunnel.isSafe(user: $0) } ?? "<user>"
        return "Bots on \(server.name) may stop when the last SSH session closes and may not start at reboot. To keep them running, run sudo loginctl enable-linger -- \(user) on the server."
    }

    static func linuxMoveSetup(port: Int) -> String {
        #"""
        set -eu
        umask 077
        export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.cargo/bin:$PATH"
        url="http://127.0.0.1:\#(port)/"
        unit_name=swarmhub-herdr.service
        systemd_user=no
        if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
            systemd_user=yes
        fi
        if curl -s --max-time 2 "$url" >/dev/null; then
            own_service=no
            if [ "$systemd_user" = yes ] && systemctl --user is-active --quiet "$unit_name"; then
                case " $(systemctl --user show "$unit_name" -p Environment --value) " in
                    *" SWARMHUB_PORT=\#(port) "*) own_service=yes ;;
                esac
                if [ "$own_service" = yes ] && command -v ss >/dev/null 2>&1; then
                    pid=$(systemctl --user show "$unit_name" -p MainPID --value)
                    if ! ss -H -ltnp "sport = :\#(port)" | grep -Fq "pid=$pid,"; then own_service=no; fi
                fi
            fi
            if [ "$own_service" = no ]; then
                echo "Port \#(port) is already in use on this server. Check the existing service or choose a different port." >&2
                exit 1
            fi
        fi
        if ! command -v hc >/dev/null 2>&1; then
            installer=$(mktemp)
            trap 'rm -f "$installer"' EXIT
            curl -fsSL https://releases.herdr.dev/core/install.sh -o "$installer"
            sh "$installer" >/dev/null
            command -v hc >/dev/null 2>&1 || { echo "Herdr Core was not found on the server after setup." >&2; exit 1; }
        fi

        config="${XDG_CONFIG_HOME:-$HOME/.config}/swarmhub-herdr"
        mkdir -p "$config"
        # Register only installed programs. The service preserves existing templates.
        for ai in claude codex opencode gemini antigravity; do
            "$HOME/.local/bin/swarmhub-herdr" service add-ai "$ai" > /dev/null 2>&1 || :
        done

        unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$unit_name"
        if [ "$systemd_user" = yes ]; then
            service_path='Environment="PATH=%h/.local/bin:%h/.npm-global/bin:%h/.cargo/bin:/usr/local/bin:/usr/bin:/bin"'
            if [ ! -e "$unit" ]; then
                mkdir -p "$(dirname "$unit")"
                (set -C; cat > "$unit" <<SERVICE
        [Unit]
        Description=SwarmHub Herdr workspace

        [Service]
        ExecStart=%h/.local/bin/swarmhub-herdr service run
        Environment=SWARMHUB_PORT=\#(port)
        $service_path
        Restart=on-failure

        [Install]
        WantedBy=default.target
        SERVICE
                )
            elif ! grep -Fxq "$service_path" "$unit"; then
                # Upgrade the old unit without editing its contents or interrupting running bots.
                mkdir -p "$unit.d"
                printf '[Service]\n%s\n' "$service_path" > "$unit.d/10-swarmhub-path.conf"
            fi
            systemctl --user daemon-reload
            systemctl --user enable --now "$unit_name" >/dev/null
            if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)" != yes ]; then
                loginctl enable-linger "$USER" 2>/dev/null || true
                if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)" != yes ]; then
                    printf 'SWARMHUB_LINGER=disabled\nSWARMHUB_LINGER_USER=%s\n' "$USER"
                fi
            fi
        else
            SWARMHUB_PORT=\#(port) nohup "$HOME/.local/bin/swarmhub-herdr" service run </dev/null >>"$config/ssh-setup.log" 2>&1 &
        fi
        for attempt in $(seq 1 30); do
            if curl -fsS --max-time 1 "$url" >/dev/null 2>&1; then exit 0; fi
            sleep 1
        done
        echo "SwarmHub did not start. Check the user service logs on the server and retry." >&2
        exit 1
        """#
    }
}
