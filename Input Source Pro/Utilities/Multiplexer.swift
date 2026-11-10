import Foundation

/// Terminal multiplexers whose focused pane Terminal Rules look into, so a rule
/// follows the program inside tmux, zellij or the herdr TUI rather than the
/// multiplexer itself. Each is asked through its own CLI at a fixed path: ISP
/// runs without a login PATH.
// shortcut: only tmux's default server is asked (no -L/-S socket), and for a multiplexer with several clients only the first or focused one counts; upgrade when those setups are in use.
enum Multiplexer: String {
    case tmux, zellij, herdr

    /// Nesting limit, e.g. Herdr → tmux → zellij.
    static let maxDepth = 3

    /// What a multiplexer's focused pane holds: a tty to read further (with
    /// the pane's label), or, for zellij, which names no tty, the program
    /// itself (nil for a shell) with the pane's label.
    enum Pane: Equatable {
        case tty(String, label: String)
        case program(TerminalProgram?, label: String)
    }

    var executable: String { "/opt/homebrew/bin/" + rawValue }

    /// The focused pane of the client running on `clientTTY` with `arguments`
    /// (its argv), or nil when the multiplexer can't be asked. A multiplexer
    /// that answered is noted in `trail`, so `TerminalWatcher` can listen to it.
    func focusedPane(clientPID: pid_t, clientTTY: String, arguments: [String], trail: inout TerminalTrail) -> Pane? {
        switch self {
        case .tmux:
            // The program is tmux, so a server is up or starting: the control-mode client retries until it answers.
            trail.tmux = true
            // A space, not a tab: without a UTF-8 locale (an app launched at login has none) tmux prints control characters as "_".
            return run(["list-clients", "-F", "#{client_tty} #{pane_tty}"])
                .flatMap { Self.pane(fromTmuxClients: $0, clientTTY: clientTTY) }
        case .zellij:
            // shortcut: a pane running a multiplexer inside zellij names no tty, so nesting stops there; upgrade if that setup shows up.
            // A bare `zellij` names its session only through the server socket it talks to.
            guard let session = Self.zellijSession(fromArguments: arguments)
                ?? Self.zellijSession(fromSocketPeers: TerminalProcess.unixSocketPeers(ofPID: clientPID))
                ?? run(["list-sessions", "-n"]).flatMap(Self.onlySession(fromList:)),
                let pane = Self.zellijPane(session: session)
            else { return nil }
            trail.zellij = TerminalTrail.Zellij(session: session, pane: pane)
            return pane
        case .herdr:
            let session = Self.herdrSession(fromArguments: arguments)
            guard let socket = Self.herdrSocket(session: session),
                  let shell = run((session.map { ["--session", $0] } ?? []) + ["pane", "process-info"])
                      .flatMap(Self.herdrShell(fromProcessInfo:)),
                  let tty = TerminalProcess.ttyPath(ofPID: shell.pid)
            else { return nil }
            trail.herdrSockets.append(socket)
            return .tty(tty, label: "herdr:" + shell.pane)
        }
    }

    /// The focused pane of zellij `session`'s first client, nil when zellij can't be asked.
    static func zellijPane(session: String) -> Pane? {
        Multiplexer.zellij.run(["-s", session, "action", "list-clients"])
            .flatMap { pane(fromZellijClients: $0, session: session) }
    }

    /// Runs the multiplexer's CLI and returns its output, or nil when it is
    /// missing, fails, or hangs.
    private func run(_ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        return Self.output(of: executable, arguments: arguments)
    }

    /// ISP's environment for the CLIs. zellij keeps its sockets under $TMPDIR,
    /// which a GUI app may lack.
    private static let environment: [String] = {
        var environment = ProcessInfo.processInfo.environment
        if environment["TMPDIR"] == nil {
            environment["TMPDIR"] = URL(fileURLWithPath: NSTemporaryDirectory()).path
        }
        return environment.map { "\($0)=\($1)" }
    }()

    /// `path`'s standard output when it exits with status 0 within `timeout`.
    /// posix_spawn rather than `Process`: zellij's client list is polled several
    /// times a second, and `Process` costs about ten times the CPU per run.
    /// `watchdog` runs its handler `timeout` seconds on; tests fire it by hand.
    static func output(
        of path: String,
        arguments: [String],
        timeout: TimeInterval = 1,
        watchdog: (TimeInterval, @escaping () -> Void) -> Void = { DispatchQueue.global().asyncAfter(deadline: .now() + $0, execute: $1) }
    ) -> String? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let (readEnd, writeEnd) = (fds[0], fds[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only 0-2 reach the child: no other ISP descriptor (a watcher's socket, this pipe's read end) leaks into it.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        close(writeEnd)
        guard spawned == 0 else {
            close(readEnd)
            return nil
        }

        // A wedged server must not stall every lookup queued behind this one.
        // The child stays unreaped until `exited` is set, so its pid can't be reused under the kill.
        let lock = NSLock()
        var exited = false
        watchdog(timeout) {
            lock.withLock { if !exited { kill(pid, SIGKILL) } }
        }

        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(readEnd, &chunk, chunk.count)
            if count > 0 {
                output += chunk[..<count]
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        close(readEnd)

        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
        lock.withLock { exited = true }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        return status == 0 ? String(decoding: output, as: UTF8.self) : nil
    }
}

// MARK: - Parsing

extension Multiplexer {
    /// `tmux list-clients -F '#{client_tty} #{pane_tty}'`: one line per client
    /// with its session's active pane. The line for `clientTTY` names the
    /// pane; `display-message -c` can't be used instead, since its pane comes
    /// from the latest session, not the client's.
    static func pane(fromTmuxClients output: String, clientTTY: String) -> Pane? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0] == clientTTY, fields[1].hasPrefix("/dev/") else { continue }
            let tty = String(fields[1])
            return .tty(tty, label: tty)
        }
        return nil
    }

    /// The session a zellij client attached to, from its argv: `zellij -s X`,
    /// `--session X`, `--session=X`, `attach X` or `a X` (attach flags skipped).
    static func zellijSession(fromArguments arguments: [String]) -> String? {
        var index = 1 // skip argv[0]
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "-s", "--session":
                return index < arguments.endIndex ? arguments[index] : nil
            case "attach", "a":
                return arguments[index...].first { !$0.hasPrefix("-") }
            default:
                if argument.hasPrefix("--session=") { return String(argument.dropFirst("--session=".count)) }
            }
        }
        return nil
    }

    /// The session a zellij client is connected to, from the peer paths of its
    /// unix sockets: the server listens at `…/zellij-<uid>/<contract>/<session>`.
    static func zellijSession(fromSocketPeers peers: [String]) -> String? {
        peers.lazy
            .map { $0 as NSString }
            .first { $0.deletingLastPathComponent.contains("/zellij-") }
            .map { $0.lastPathComponent }
    }

    /// The named session a herdr TUI client attached to, from its argv:
    /// `herdr --session X`, `--session=X` or `herdr session attach X`; nil for
    /// the default session.
    static func herdrSession(fromArguments arguments: [String]) -> String? {
        var index = 1 // skip argv[0]
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            if argument == "--session" { return index < arguments.endIndex ? arguments[index] : nil }
            if argument.hasPrefix("--session=") { return String(argument.dropFirst("--session=".count)) }
            if argument == "session", arguments[index...].first == "attach" {
                return arguments[(index + 1)...].first { !$0.hasPrefix("-") }
            }
        }
        return nil
    }

    /// The socket of herdr `session` (nil: the default one), or nil for a name
    /// that would leave the sessions directory.
    static func herdrSocket(session: String?) -> String? {
        let herdr = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/herdr")
        guard let session else { return herdr.appendingPathComponent("herdr.sock").path }
        guard !session.isEmpty, !session.contains("/"), session != ".", session != ".." else { return nil }
        return herdr.appendingPathComponent("sessions/\(session)/herdr.sock").path
    }

    /// `zellij list-sessions -n`: `name [Created …]`, with `(EXITED - attach to resurrect)` after
    /// sessions that are gone but resurrectable; the name when exactly one session is running.
    static func onlySession(fromList output: String) -> String? {
        let names = output
            .split(whereSeparator: \.isNewline)
            .filter { !$0.contains("(EXITED") }
            .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
        return names.count == 1 ? names[0] : nil
    }

    /// `zellij action list-clients`: a header row, then `CLIENT_ID ZELLIJ_PANE_ID
    /// RUNNING_COMMAND` per client. RUNNING_COMMAND is the foreground process's
    /// argv, so its first word is the typed command (`claude`), not `p_comm`.
    static func pane(fromZellijClients output: String, session: String) -> Pane? {
        let rows = output.split(whereSeparator: \.isNewline)
        guard rows.count >= 2, rows[0].hasPrefix("CLIENT_ID") else { return nil }
        let columns = rows[1].split(whereSeparator: \.isWhitespace)
        guard columns.count >= 2 else { return nil }

        let paneID = String(columns[1])
        let label = "zellij:\(session)/\(paneID)"
        // A shell pane lists its command as "N/A", which must not read as a program named "A".
        guard !paneID.hasPrefix("plugin_"), columns.count >= 3, columns[2] != "N/A" else { return .program(nil, label: label) }
        let command = (String(columns[2]) as NSString).lastPathComponent
        let key = TerminalProcess.program(comm: command, arguments: columns[2...].map(String.init)).key
        guard !key.isEmpty, !TerminalProcess.shells.contains(key) else { return .program(nil, label: label) }
        return .program(TerminalProgram(key: key, pane: label), label: label)
    }

    /// `herdr pane process-info`: the focused pane's shell pid and pane id. An
    /// error reply (`server_not_running`) has no `result`.
    static func herdrShell(fromProcessInfo output: String) -> (pid: pid_t, pane: String)? {
        struct Reply: Decodable {
            struct Result: Decodable { let processInfo: Info }
            struct Info: Decodable {
                let shellPid: pid_t
                let paneId: String
            }

            let result: Result
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let info = (try? decoder.decode(Reply.self, from: Data(output.utf8)))?.result.processInfo,
              info.shellPid > 0
        else { return nil }
        return (info.shellPid, info.paneId)
    }
}
