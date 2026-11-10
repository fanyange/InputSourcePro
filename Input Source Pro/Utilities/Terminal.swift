import AppKit
import Combine
import Darwin

/// Terminals whose foreground program can drive Terminal Rules.
enum Terminal: String, CaseIterable {
    case herdr = "dev.herdr.app"
    case ghostty = "com.mitchellh.ghostty"
    case iterm = "com.googlecode.iterm2"
    case terminalApp = "com.apple.Terminal"
    case wezterm = "com.github.wez.wezterm"
    case alacritty = "org.alacritty"

    init?(_ app: NSRunningApplication) {
        guard let bundleIdentifier = app.bundleIdentifier else { return nil }
        self.init(rawValue: bundleIdentifier)
    }

    var displayName: String {
        switch self {
        case .herdr:
            return "Herdr"
        case .ghostty:
            return "Ghostty"
        case .iterm:
            return "iTerm2"
        case .terminalApp:
            return "Terminal"
        case .wezterm:
            return "WezTerm"
        case .alacritty:
            return "Alacritty"
        }
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) != nil
    }
}

// MARK: - Focused tty

extension Terminal {
    /// The outer tty each terminal's focused pane was last read from (a
    /// `TerminalProbe` answer, or the tty Herdr's view file led to) with its pane
    /// label, so a refresh reads it again without asking the terminal. Confined
    /// to `TerminalProcess.queue`, which orders it with the reads that use it.
    private static var focusedTTYs: [Terminal: (path: String, pane: String?)] = [:]

    /// What `tty` runs, which becomes this terminal's focused tty; nil forgets
    /// it and reads nothing, in no known pane. Call on `TerminalProcess.queue`.
    func focusedProgram(onTTY tty: String?, pane: String? = nil) -> TerminalReading {
        Self.focusedTTYs[self] = tty.map { ($0, pane) }
        return tty.map { TerminalProcess.foregroundProgram(onTTY: $0, pane: pane) } ?? TerminalReading(program: nil, pane: nil)
    }

    /// The focused pane, read again on the remembered tty; a terminal other
    /// than Herdr is probed for its tty when none is remembered. nil means there is nothing to read
    /// (Herdr's pane led to no tty). Call on `TerminalProcess.queue`.
    func refreshedProgram() -> TerminalReading? {
        let focused = Self.focusedTTYs[self]
        IndicatorDiagnostics.record("terminal.refresh bundle=\(rawValue) tty=\(focused?.path ?? "-")")
        if let focused {
            return TerminalProcess.foregroundProgram(onTTY: focused.path, pane: focused.pane)
        }
        return self == .herdr ? nil : TerminalProbe.program(self)
    }

    /// What a Herdr pane named by its view file runs: the tty of the pane's
    /// process (asked of `hc`), read like a lookup, which sees through shell
    /// wrappers and multiplexers; that tty becomes the focused one. With no
    /// tty, a shell in `pane`. Call on `TerminalProcess.queue`.
    func paneProgram(
        pane: String?,
        herdrPID: (String) -> pid_t? = { HerdrDesktop.pid(ofTerminal: $0) },
        ttyPath: (pid_t) -> String? = TerminalProcess.ttyPath(ofPID:)
    ) -> TerminalReading {
        let pid = self == .herdr ? pane.flatMap(herdrPID) : nil
        let tty = pid.flatMap(ttyPath)
        IndicatorDiagnostics.record("terminal.pane bundle=\(rawValue) pid=\(pid.map(String.init) ?? "-") tty=\(tty ?? "-") pane=\(pane ?? "-")")
        let found = focusedProgram(onTTY: tty, pane: pane)
        return tty == nil ? TerminalReading(program: nil, pane: pane) : found
    }
}

/// What a lookup found in a terminal's focused pane: its program, nil for a
/// shell prompt, and the pane read (the program's own pane when there is one),
/// so a shell is tied to its pane too. `pane` is nil when no pane was read.
/// `trail` is what the lookup went through, for `TerminalWatcher`; it is not
/// part of what was read, so two readings compare equal without it. `tty` is
/// the innermost tty read (through multiplexers), nil when none was; it is left
/// out of `==` too, since `pane` already tells panes apart.
struct TerminalReading: Equatable {
    let program: TerminalProgram?
    let pane: String?
    var trail = TerminalTrail()
    var tty: String? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.program == rhs.program && lhs.pane == rhs.pane
    }
}

/// The program running in the focused terminal pane. `key` is the terminal's
/// own identifier for it (Herdr's program key, or the process's `argv[0]`);
/// `name` is an alternative label (Herdr's display name, or the kernel's
/// process name when it differs, e.g. Claude Code's `2.1.318`). `pane` names
/// the terminal instance (Herdr's terminal address, Ghostty's tty path, or,
/// inside a multiplexer, the inner pane's tty, `zellij:<session>/<pane>` or `herdr:<pane>`), so
/// moving to another pane running the same program is a new context. `tty` is
/// the pane's own tty when known, which editor mode messages are keyed by.
struct TerminalProgram: Equatable {
    let key: String
    let name: String?
    let pane: String?
    let tty: String?

    init(key: String, name: String? = nil, pane: String? = nil, tty: String? = nil) {
        self.key = key
        self.name = name == key ? nil : name
        self.pane = pane
        self.tty = tty
    }

    /// Stable per-program part of `AppKind.getId()` when no rule matches. Leaves
    /// out `pane`, so panes running the same program share one remembered input
    /// source, like tabs on the same website.
    var id: String {
        [key, name].compactMap { $0 }.joined(separator: "/").lowercased()
    }
}

/// One process attached to a tty, as the kernel's process table reports it.
struct TerminalProcess: Equatable {
    let pid: pid_t
    let pgid: pid_t
    let foregroundPgid: pid_t
    let startTime: TimeInterval
    /// `p_comm`, the executable's file name (at most 16 bytes).
    let comm: String

    static let shells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh",
        "nu", "elvish", "xonsh", "pwsh", "login",
    ]

    var isShell: Bool {
        Self.shells.contains(comm.hasPrefix("-") ? String(comm.dropFirst()) : comm)
    }

    /// The process that stands for the tty's foreground job: the earliest-started
    /// non-shell member of the foreground process group. That is the group leader
    /// (`nvim`, `claude`), or the command a shell leader started (`bash -c
    /// lazygit`); children a program spawns later into its group (an agent's MCP
    /// servers, `caffeinate`) start after it and never win. A shell alone means
    /// no program.
    static func foregroundProcess(in processes: [TerminalProcess]) -> TerminalProcess? {
        processes
            .filter { $0.pgid == $0.foregroundPgid && !$0.isShell }
            .min { ($0.startTime, $0.pid) < ($1.startTime, $1.pid) }
    }

    /// `argv[0]` names the command people typed (`claude`), while `p_comm` is the
    /// resolved file name (`2.1.318` for Claude Code's versioned binary), so the
    /// rule can match either. A script run by an interpreter (`node …/cli.js`,
    /// `bun ~/.bun/bin/omp`) is named after the script: the bin name its npm
    /// package gives it, else the file name without extension.
    static func program(comm: String, arguments: [String]) -> TerminalProgram {
        let command = arguments.first
            .map { ($0 as NSString).lastPathComponent }
            .map { $0.hasPrefix("-") ? String($0.dropFirst()) : $0 }
            .flatMap { $0.isEmpty ? nil : $0 }

        if let command, interpreters.contains(command),
           let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") && $0 != "run" }) {
            return TerminalProgram(key: packageBinName(ofScript: script) ?? (script as NSString).lastPathComponent.components(separatedBy: ".")[0], name: comm)
        }
        return TerminalProgram(key: command ?? comm, name: comm)
    }

    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "perl"]

    /// The `bin` name the nearest `package.json` above `script` gives it
    /// (`pi` for `…/pi-coding-agent/dist/bundle/cli.js`), nil when none does.
    static func packageBinName(ofScript script: String) -> String? {
        var directory = (script as NSString).deletingLastPathComponent
        while directory.count > 1 {
            let manifest = directory + "/package.json"
            if let data = FileManager.default.contents(atPath: manifest) {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return binName(in: json, packageDirectory: directory, script: script)
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// `bin` is a map of name → script path relative to the package, or one
    /// path for a bin named after the package.
    static func binName(in manifest: [String: Any], packageDirectory: String, script: String) -> String? {
        let scriptPath = (script as NSString).standardizingPath
        let resolves: (String) -> Bool = { ((packageDirectory + "/" + $0) as NSString).standardizingPath == scriptPath }
        if let bins = manifest["bin"] as? [String: String] {
            return bins.first { resolves($0.value) }?.key
        }
        if let bin = manifest["bin"] as? String, resolves(bin), let name = manifest["name"] as? String {
            return (name as NSString).lastPathComponent
        }
        return nil
    }
}

// MARK: - Process table

extension TerminalProcess {
    /// Runs probes one at a time and off the main thread: multiplexer lookups
    /// spawn processes, and `TerminalProbe` runs here too.
    static let queue = DispatchQueue(label: "dev.inputsourcepro.terminal-probe", qos: .userInitiated)

    /// The foreground program on the tty at `path` (e.g. `/dev/ttys008`), nil
    /// for a shell prompt or an unreadable tty. Its pane is `pane`, or the tty path.
    /// A multiplexer (tmux, zellij, herdr) is looked through to the program in its
    /// focused pane, nested up to `Multiplexer.maxDepth`; when it can't be asked,
    /// the multiplexer itself is the program. Spawns processes then, so call it
    /// on `queue`.
    static func foregroundProgram(onTTY path: String, pane: String? = nil) -> TerminalReading {
        var trail = TerminalTrail()
        var reading = foregroundProgram(onTTY: path, pane: pane, depth: 0, trail: &trail)
        reading.trail = trail
        return reading
    }

    private static func foregroundProgram(onTTY path: String, pane: String?, depth: Int, trail: inout TerminalTrail) -> TerminalReading {
        let pane = pane ?? path
        let processes = processes(onTTY: path)
        if let tty = TerminalTrail.TTY(watching: processes, foregroundPgid: TerminalTrail.foregroundPgid(ofPID:)) {
            trail.ttys.append(tty)
        }
        guard let process = foregroundProcess(in: processes) else {
            // Non-shell processes that are not in the foreground group explain a surprising "shell".
            if processes.contains(where: { !$0.isShell }) {
                IndicatorDiagnostics.record("terminal.tty tty=\(path) tpgid=\(processes.first?.foregroundPgid ?? 0) procs=\(processes.map { "\($0.comm):\($0.pgid)" }.joined(separator: ","))")
            }
            return TerminalReading(program: nil, pane: pane, tty: path)
        }
        let arguments = arguments(pid: process.pid)
        let found = program(comm: process.comm, arguments: arguments)
        let reading = TerminalReading(program: TerminalProgram(key: found.key, name: found.name, pane: pane, tty: path), pane: pane, tty: path)
        guard depth < Multiplexer.maxDepth, let multiplexer = Multiplexer(rawValue: found.key) else { return reading }

        let inner: TerminalReading
        var paneTTY: String?
        switch multiplexer.focusedPane(clientPID: process.pid, clientTTY: path, arguments: arguments, trail: &trail) {
        case nil:
            inner = reading
        case let .tty(tty, label)?:
            paneTTY = tty
            inner = foregroundProgram(onTTY: tty, pane: label, depth: depth + 1, trail: &trail)
        case let .program(paneProgram, label)?:
            inner = TerminalReading(program: paneProgram, pane: label)
        }
        IndicatorDiagnostics.record("terminal.mux kind=\(multiplexer.rawValue) client=\(path) pane=\(inner.pane ?? "-") paneTTY=\(paneTTY ?? "-") program=\(inner.program?.id ?? "shell")")
        return inner
    }

    /// Runs `body` on `queue` and delivers its result on the main queue.
    static func onQueue<Output>(_ body: @escaping () -> Output) -> AnyPublisher<Output, Never> {
        Future { promise in
            queue.async { promise(.success(body())) }
        }
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()
    }

    /// The controlling tty of `pid` (e.g. `/dev/ttys002`), or nil when the process
    /// is gone, has no tty, or belongs to another user. Herdr reports the shell
    /// wrapping a program (`sh -c 'lazygit'`), and its tty leads to the program.
    static func ttyPath(ofPID pid: pid_t) -> String? {
        processInfo(pid)?.tty
    }

    /// The nearest process at or above `pid` (up to `maxDepth` parents) that has a tty
    /// of ours, with that tty: a program's helper (`nvim --embed`) has none, its parent does.
    static func ttyOwner(ofPID pid: pid_t, maxDepth: Int = 4) -> (pid: pid_t, tty: String)? {
        ttyOwner(ofPID: pid, maxDepth: maxDepth, info: processInfo)
    }

    /// `info` reads a process's parent and tty; nil when it is gone or not ours.
    static func ttyOwner(
        ofPID pid: pid_t,
        maxDepth: Int,
        info: (pid_t) -> (ppid: pid_t, tty: String?)?
    ) -> (pid: pid_t, tty: String)? {
        var current = pid
        for _ in 0 ... maxDepth {
            guard let entry = info(current) else { return nil }
            if let tty = entry.tty { return (current, tty) }
            guard entry.ppid > 1 else { return nil }
            current = entry.ppid
        }
        return nil
    }

    private static func processInfo(_ pid: pid_t) -> (ppid: pid_t, tty: String?)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var entry = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // An exited pid still succeeds, with size 0.
        guard sysctl(&mib, u_int(mib.count), &entry, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride,
              entry.kp_eproc.e_ucred.cr_uid == getuid()
        else { return nil }
        let dev = entry.kp_eproc.e_tdev
        // NODEV: no controlling tty
        let tty = dev == -1 ? nil : devname(dev, S_IFCHR).map { "/dev/" + String(cString: $0) }
        return (entry.kp_eproc.e_ppid, tty)
    }

    /// The paths the unix sockets of `pid` are connected to, e.g. a multiplexer
    /// client's server socket; empty when the process is gone or not ours.
    static func unixSocketPeers(ofPID pid: pid_t) -> [String] {
        let stride = Int32(MemoryLayout<proc_fdinfo>.stride)
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size / stride) + 8)
        let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count) * stride)
        guard read > 0 else { return [] }

        return fds.prefix(Int(read / stride)).compactMap { fd -> String? in
            guard fd.proc_fdtype == PROX_FDTYPE_SOCKET else { return nil }
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_family == AF_UNIX
            else { return nil }
            let peer = withUnsafeBytes(of: info.psi.soi_proto.pri_un.unsi_caddr.ua_sun.sun_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return peer.isEmpty ? nil : peer
        }
    }

    static func processes(onTTY path: String) -> [TerminalProcess] {
        var info = stat()
        guard stat(path, &info) == 0 else { return [] }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, info.st_rdev]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        // Room for processes started between the two calls.
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
        size = entries.count * stride
        guard sysctl(&mib, u_int(mib.count), &entries, &size, nil, 0) == 0 else { return [] }

        return entries.prefix(size / stride).map { entry in
            let startTime = entry.kp_proc.p_un.__p_starttime
            let comm = withUnsafeBytes(of: entry.kp_proc.p_comm) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }

            return TerminalProcess(
                pid: entry.kp_proc.p_pid,
                pgid: entry.kp_eproc.e_pgid,
                foregroundPgid: entry.kp_eproc.e_tpgid,
                startTime: TimeInterval(startTime.tv_sec) + TimeInterval(startTime.tv_usec) / 1_000_000,
                comm: comm
            )
        }
    }

    /// The argv of `pid`, empty when it can't be read.
    static func arguments(pid: pid_t) -> [String] {
        var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        guard sysctl(&argMaxMib, 2, &argMax, &argMaxSize, nil, 0) == 0, argMax > 0 else { return [] }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }

        return arguments(fromProcArgs: buffer.prefix(size))
    }

    /// Parses a `KERN_PROCARGS2` buffer: `argc` (Int32), the executable path,
    /// NUL padding, then `argc` NUL-terminated arguments (the environment follows).
    static func arguments(fromProcArgs buffer: ArraySlice<UInt8>) -> [String] {
        let countSize = MemoryLayout<Int32>.size
        guard buffer.count > countSize else { return [] }
        let argc = Array(buffer.prefix(countSize)).withUnsafeBytes { $0.load(as: Int32.self) }
        var index = buffer.startIndex + countSize

        while index < buffer.endIndex, buffer[index] != 0 { index += 1 }
        while index < buffer.endIndex, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < argc, index < buffer.endIndex {
            let start = index
            while index < buffer.endIndex, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start ..< index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}

// MARK: - Program control

/// Panes whose program (nvim, ...) took over the input source with `isp:` commands,
/// per tty, in memory only. A controlled pane skips Terminal and App rules: it
/// goes back to `current`, which follows every change made while it has focus,
/// so the program can `push` the source it wants, `pop` back to what was there,
/// and `release` the pane to the rules. The last program to command a tty is
/// its `pid`; a shell result releases the pane only once that process is gone.
struct TerminalControlTracker<Source> {
    static var maxStack: Int { 16 }

    private struct Entry {
        var stack: [Source] = []
        var current: Source?
        var pid: pid_t = 0
    }

    private var entries: [String: Entry] = [:]

    func isControlled(_ tty: String) -> Bool {
        entries[tty] != nil
    }

    /// The source the pane should have; nil for an uncontrolled pane, or when none is known.
    func current(on tty: String) -> Source? {
        entries[tty]?.current
    }

    mutating func select(_ source: Source, on tty: String, pid: pid_t) {
        entries[tty, default: Entry()].current = source
        entries[tty]?.pid = pid
    }

    /// Stacks the pane's source, `live` when none is recorded yet and nil when unknown, then makes `source` current.
    mutating func push(_ source: Source, on tty: String, pid: pid_t, live: Source?) {
        var entry = entries[tty] ?? Entry()
        entry.pid = pid
        if let base = entry.current ?? live {
            entry.stack.append(base)
            if entry.stack.count > Self.maxStack { entry.stack.removeFirst() }
        }
        entry.current = source
        entries[tty] = entry
    }

    /// The source `pop` returns to, now current; nil, changing nothing, for an empty stack.
    mutating func pop(on tty: String, pid: pid_t) -> Source? {
        guard let popped = entries[tty]?.stack.popLast() else { return nil }
        entries[tty]?.current = popped
        entries[tty]?.pid = pid
        return popped
    }

    /// The pane has focus and its source changed, whoever changed it.
    mutating func follow(_ source: Source, on tty: String) {
        guard entries[tty] != nil else { return }
        entries[tty]?.current = source
    }

    /// The program let go.
    mutating func release(_ tty: String) {
        entries[tty] = nil
    }

    /// The pane reads as a shell: the program is gone unless its process is still
    /// alive on the tty (suspended with Ctrl-Z, or a stale read taken before it started).
    mutating func releaseUnlessAlive(_ tty: String, isAlive: (pid_t, String) -> Bool) {
        guard let pid = entries[tty]?.pid, !isAlive(pid, tty) else { return }
        entries[tty] = nil
    }
}
