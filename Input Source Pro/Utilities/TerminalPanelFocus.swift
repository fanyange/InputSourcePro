import AppKit
import AXSwift
import Combine

/// Tracks which watched terminal has a floating panel with key focus while
/// another app is frontmost, such as Ghostty's quick terminal (⌥`). The panel
/// doesn't activate its app, so NSWorkspace still names the other app and the
/// system-wide `focusedApplication` fails (cannotComplete).
///
/// Contract: every notification re-evaluates whether the terminal reports
/// `AXFrontmost` and its focused window is an `AXFloatingWindow`; no single
/// notification is trusted to mean shown or hidden. Only a change of the
/// result reaches `changed`. A terminal that is itself frontmost never counts:
/// its windows, the panel included, go through activation. Each terminal has
/// at most one read in flight; evaluations asked meanwhile become one more.
@MainActor
final class TerminalPanelFocus {
    struct Attributes: Equatable {
        var isFrontmost: Bool
        var focusedWindowSubrole: String?
    }

    struct Environment {
        /// The frontmost app's pid, as NSWorkspace sees it.
        var frontmostPID: () -> pid_t?
        /// Reads `pid`'s attributes off the main thread and answers later on
        /// it, unless cancelled first; nil when AX can't answer (no permission,
        /// app busy or gone).
        var read: (_ pid: pid_t, _ answer: @escaping (Attributes?) -> Void) -> AnyCancellable
    }

    /// Notifications that may come with the panel showing or hiding; each one
    /// only asks for a new evaluation.
    static let notifications: [AXNotification] = [
        .focusedWindowChanged,
        .mainWindowChanged,
        .focusedUIElementChanged,
        .windowCreated,
        .uiElementDestroyed,
        .windowMiniaturized,
        .applicationActivated,
        .applicationDeactivated,
        .applicationHidden,
        .applicationShown,
    ]

    /// The terminal whose panel has focus.
    private(set) var focusedPID: pid_t?
    private var watchedPIDs: Set<pid_t> = []
    private var reads: [pid_t: AnyCancellable] = [:]
    /// Terminals evaluated again while their read was in flight.
    private var rereads: Set<pid_t> = []
    private let environment: Environment
    private let changed: (_ focusedPID: pid_t?) -> Void

    init(environment: Environment = .live, changed: @escaping (_ focusedPID: pid_t?) -> Void) {
        self.environment = environment
        self.changed = changed
    }

    /// The terminals to track; one that leaves (quit, rules turned off) loses its panel.
    func watch(_ pids: Set<pid_t>) {
        watchedPIDs = pids
        // Work for a terminal that left is void: a queued read is skipped, an evaluation asked again dropped.
        reads = reads.filter { pids.contains($0.key) }
        rereads.formIntersection(pids)
        if let focusedPID, !pids.contains(focusedPID) { set(nil) }
    }

    func evaluate(_ pid: pid_t) {
        guard watchedPIDs.contains(pid) else { return }
        guard environment.frontmostPID() != pid else { return apply(pid, isFocused: false) }
        // A slow terminal must not pile up reads: the one in flight is followed by one more.
        guard reads[pid] == nil else {
            rereads.insert(pid)
            return
        }
        reads[pid] = environment.read(pid) { [weak self] attributes in
            guard let self else { return }
            self.reads[pid] = nil
            self.apply(pid, isFocused: attributes.map(Self.isPanelFocused) ?? false)
            if self.rereads.remove(pid) != nil { self.evaluate(pid) }
        }
    }

    static func isPanelFocused(_ attributes: Attributes) -> Bool {
        attributes.isFrontmost && attributes.focusedWindowSubrole == kAXFloatingWindowSubrole
    }

    private func apply(_ pid: pid_t, isFocused: Bool) {
        // A read answered after the terminal left the watch or came to the front is stale.
        guard watchedPIDs.contains(pid) else { return }
        if isFocused, environment.frontmostPID() != pid {
            set(pid)
        } else if focusedPID == pid {
            set(nil)
        }
    }

    private func set(_ pid: pid_t?) {
        guard pid != focusedPID else { return }
        focusedPID = pid
        changed(pid)
    }
}

extension TerminalPanelFocus.Environment {
    static let live = Self(
        frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        read: { pid, answer in
            let flag = CancelFlag()
            queue.async {
                guard !flag.isCancelled else { return }
                let attributes = TerminalPanelFocus.attributes(of: pid)
                DispatchQueue.main.async { if !flag.isCancelled { answer(attributes) } }
            }
            return AnyCancellable(flag)
        }
    )

    /// AX reads, off the main thread and in order.
    private static let queue = DispatchQueue(label: "dev.inputsourcepro.terminal-panel", qos: .userInitiated)
}

extension TerminalPanelFocus {
    /// The app's `AXFrontmost` and, when set, its focused window's subrole;
    /// nil when AX can't answer.
    nonisolated static func attributes(of pid: pid_t) -> Attributes? {
        guard let app = Application(forProcessID: pid) else { return nil }
        // A hung terminal must not hold up the reads behind it.
        app.messagingTimeout = 0.25
        guard let isFrontmost: Bool = try? app.attribute(.frontmost) else { return nil }
        guard isFrontmost else { return Attributes(isFrontmost: false) }
        let window: UIElement? = try? app.attribute(.focusedWindow)
        window?.messagingTimeout = 0.25
        let subrole: String? = try? window?.attribute(.subrole)
        return Attributes(isFrontmost: true, focusedWindowSubrole: subrole)
    }
}
