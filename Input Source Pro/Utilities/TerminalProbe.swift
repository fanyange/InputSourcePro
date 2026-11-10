import AppKit
import AXSwift
import Darwin

/// Reads the program in the focused pane of a terminal ISP pulls from (every
/// terminal but Herdr, which pushes): each terminal names the pane's tty its
/// own way, and the kernel's process table names the tty's foreground job.
/// Runs on `TerminalProcess.queue`, never on the main thread; AppleScript runs
/// in `osascript` (NSAppleScript is main-thread only).
enum TerminalProbe {
    // Confined to `TerminalProcess.queue`.
    private static var automationDenied: Set<Terminal> = []

    /// The focused pane's program, nil for a shell prompt or, in no known
    /// pane, when the terminal can't be asked. The tty it finds becomes the
    /// terminal's focused tty, which refreshes read again. Call on `TerminalProcess.queue`.
    static func program(_ terminal: Terminal) -> TerminalReading {
        terminal.focusedProgram(onTTY: focusedTTY(of: terminal))
    }

    private static func focusedTTY(of terminal: Terminal) -> String? {
        switch terminal {
        case .herdr:
            return nil
        case .ghostty:
            return askTTY(terminal, "get tty of focused terminal of selected tab of front window")
        case .iterm:
            return askTTY(terminal, "tell current session of current tab of current window to get tty")
        case .terminalApp:
            return askTTY(terminal, "get tty of selected tab of front window")
        case .wezterm:
            return weztermTTY()
        case .alacritty:
            return alacrittyTTY()
        }
    }

    // MARK: - AppleScript (Ghostty, iTerm2, Terminal)

    /// `command`'s answer when `terminal` is told it, if it is a tty path.
    private static func askTTY(_ terminal: Terminal, _ command: String) -> String? {
        // shortcut: a denial sticks until relaunch, so granting Automation later needs an app restart.
        guard !automationDenied.contains(terminal) else { return nil }

        // `is running` keeps the query from launching the terminal after it quits.
        let script = """
        if application id "\(terminal.rawValue)" is running then
            with timeout of 2 seconds
                tell application id "\(terminal.rawValue)" to \(command)
            end timeout
        end if
        """

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return nil
        }

        let tty = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        // -1743: the user denied Automation access; -1744: macOS won't ask.
        if error.contains("(-1743)") || error.contains("(-1744)") {
            automationDenied.insert(terminal)
            NSLog("\(terminal.displayName) automation is not permitted; Terminal Rules fall back to its App Rule.")
            return nil
        }

        guard process.terminationStatus == 0, tty.hasPrefix("/dev/") else { return nil }
        return tty
    }

    // MARK: - WezTerm

    private static let wezterm = "/opt/homebrew/bin/wezterm"

    /// The focused pane's tty from `wezterm cli`, which talks to the running
    /// GUI; nil when it isn't running (`--no-auto-start`: never start a mux server).
    private static func weztermTTY() -> String? {
        let cli = { (command: String) in
            Multiplexer.output(of: wezterm, arguments: ["cli", "--no-auto-start", command, "--format", "json"])
        }
        guard let clients = cli("list-clients"),
              let pane = focusedPaneID(fromClients: clients),
              let panes = cli("list")
        else { return nil }
        return tty(ofPane: pane, in: panes)
    }

    /// `focused_pane_id` of the first client in `wezterm cli list-clients --format json`.
    static func focusedPaneID(fromClients output: String) -> Int? {
        struct Client: Decodable { let focusedPaneId: Int? }
        return (try? snakeCaseDecoder.decode([Client].self, from: Data(output.utf8)))?.first?.focusedPaneId
    }

    /// `tty_name` of pane `id` in `wezterm cli list --format json`.
    static func tty(ofPane id: Int, in output: String) -> String? {
        struct Pane: Decodable {
            let paneId: Int
            let ttyName: String?
        }
        return (try? snakeCaseDecoder.decode([Pane].self, from: Data(output.utf8)))?
            .first { $0.paneId == id }?
            .ttyName
    }

    private static var snakeCaseDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    // MARK: - Alacritty

    /// Alacritty has no scripting interface, but each window's shell is a child
    /// of its process with its own tty; with several windows, the focused
    /// window's title picks one.
    private static func alacrittyTTY() -> String? {
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: Terminal.alacritty.rawValue)
            .first?.processIdentifier
        else { return nil }

        let ttys = childTTYs(of: pid)
        guard ttys.count > 1 else { return ttys.first }
        let programs = ttys.map { tty in
            (tty: tty, program: TerminalProcess.foregroundProcess(in: TerminalProcess.processes(onTTY: tty)).map {
                TerminalProcess.program(comm: $0.comm, arguments: TerminalProcess.arguments(pid: $0.pid))
            })
        }
        return tty(titled: focusedWindowTitle(of: pid), among: programs)
    }

    /// The window whose title names a tty's foreground program, or the only tty.
    /// shortcut: with several windows, a window whose program doesn't put its
    /// name in the title (a shell prompt, plain vim) matches nothing and gets the
    /// App Rule, and windows running the same program can't be told apart; ask
    /// Alacritty for its focused window if it ever gains an IPC query for it.
    static func tty(titled title: String?, among programs: [(tty: String, program: TerminalProgram?)]) -> String? {
        guard programs.count > 1 else { return programs.first?.tty }
        guard let title else { return nil }
        return programs.first { $0.program.map { title.localizedCaseInsensitiveContains($0.key) } ?? false }?.tty
    }

    /// The controlling ttys of `pid`'s children. They are `login`, owned by
    /// root, so this skips `TerminalProcess.ttyPath(ofPID:)`'s owner check.
    private static func childTTYs(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        // Room for processes started between the two calls.
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = entries.count * stride
        guard sysctl(&mib, u_int(mib.count), &entries, &size, nil, 0) == 0 else { return [] }

        return entries.prefix(size / stride).compactMap { entry in
            guard entry.kp_eproc.e_ppid == pid,
                  entry.kp_eproc.e_tdev != -1, // NODEV: no controlling tty
                  let name = devname(entry.kp_eproc.e_tdev, S_IFCHR)
            else { return nil }
            return "/dev/" + String(cString: name)
        }
    }

    private static func focusedWindowTitle(of pid: pid_t) -> String? {
        guard let app = Application(forProcessID: pid) else { return nil }
        // A hung terminal must not hold up the probes behind it.
        app.messagingTimeout = 0.25
        let window: UIElement? = try? app.attribute(.focusedWindow)
        window?.messagingTimeout = 0.25
        return try? window?.attribute(.title)
    }
}
