import Combine
import CoreData
import XCTest
@testable import Input_Source_Pro

@MainActor
final class TerminalPanelFocusTests: XCTestCase {
    private static let ghostty: pid_t = 200
    private static let other: pid_t = 100
    private static let panel = TerminalPanelFocus.Attributes(isFrontmost: true, focusedWindowSubrole: "AXFloatingWindow")
    private static let window = TerminalPanelFocus.Attributes(isFrontmost: false, focusedWindowSubrole: "AXStandardWindow")

    /// A tracker on a fake frontmost app and fake AX reads, answered by hand.
    @MainActor
    private final class Harness {
        var frontmost: pid_t? = TerminalPanelFocusTests.other
        /// What the next reads answer; nil is AX failing (no permission).
        var attributes: TerminalPanelFocus.Attributes?
        /// Reads not answered yet; a cancelled one is dropped unanswered.
        var pendingReads: [(pid: pid_t, flag: CancelFlag, answer: (TerminalPanelFocus.Attributes?) -> Void)] = []
        var reads = 0
        var changes: [pid_t?] = []

        lazy var focus = TerminalPanelFocus(
            environment: TerminalPanelFocus.Environment(
                frontmostPID: { [unowned self] in frontmost },
                read: { [unowned self] pid, answer in
                    reads += 1
                    let flag = CancelFlag()
                    pendingReads.append((pid, flag, answer))
                    return AnyCancellable(flag)
                }
            ),
            changed: { [unowned self] in changes.append($0) }
        )

        init() {
            focus.watch([TerminalPanelFocusTests.ghostty])
        }

        /// A notification from Ghostty, its read answered at once.
        func notify() {
            focus.evaluate(TerminalPanelFocusTests.ghostty)
            answerReads()
        }

        func answerReads() {
            let reads = pendingReads
            pendingReads = []
            reads.filter { !$0.flag.isCancelled }.forEach { $0.answer(attributes) }
        }
    }

    func testAFocusedPanelStandsInAndItsCollapseHandsBack() {
        let harness = Harness()
        harness.attributes = Self.panel
        harness.notify()
        XCTAssertEqual(harness.changes, [Self.ghostty])
        XCTAssertEqual(harness.focus.focusedPID, Self.ghostty)

        harness.attributes = Self.window
        harness.notify()
        XCTAssertEqual(harness.changes, [Self.ghostty, nil])
        XCTAssertNil(harness.focus.focusedPID)
    }

    func testRepeatedNotificationsActOnlyOnAChange() {
        let harness = Harness()
        harness.attributes = Self.window
        harness.notify()
        harness.notify()
        XCTAssertEqual(harness.changes, [])

        harness.attributes = Self.panel
        harness.notify()
        harness.notify()
        harness.notify()
        XCTAssertEqual(harness.changes, [Self.ghostty])
        XCTAssertEqual(harness.reads, 5)
    }

    func testTheTerminalInFrontNeverCountsAndIsNotRead() {
        let harness = Harness()
        harness.frontmost = Self.ghostty
        harness.attributes = Self.panel
        harness.notify()
        XCTAssertEqual(harness.reads, 0)
        XCTAssertEqual(harness.changes, [])
    }

    func testTheTerminalComingToTheFrontEndsItsPanel() {
        let harness = Harness()
        harness.attributes = Self.panel
        harness.notify()

        // The user clicks one of Ghostty's own windows.
        harness.frontmost = Self.ghostty
        harness.notify()
        XCTAssertEqual(harness.changes, [Self.ghostty, nil])
        XCTAssertEqual(harness.reads, 1)
    }

    func testAReadAnsweredAfterTheTerminalCameToTheFrontIsStale() {
        let harness = Harness()
        harness.attributes = Self.panel
        harness.focus.evaluate(Self.ghostty)
        harness.frontmost = Self.ghostty
        harness.answerReads()
        XCTAssertEqual(harness.changes, [])
    }

    func testUnreadableAttributesCountAsNoPanel() {
        let harness = Harness()
        harness.attributes = nil
        harness.notify()
        XCTAssertEqual(harness.changes, [])

        harness.attributes = Self.panel
        harness.notify()
        // Permission revoked while the panel has focus.
        harness.attributes = nil
        harness.notify()
        XCTAssertEqual(harness.changes, [Self.ghostty, nil])
    }

    func testATerminalNoLongerWatchedLosesItsPanelAndLateReads() {
        let harness = Harness()
        harness.attributes = Self.panel
        harness.notify()

        harness.focus.evaluate(Self.ghostty)
        harness.focus.watch([])
        harness.answerReads()
        harness.focus.evaluate(Self.ghostty)
        XCTAssertEqual(harness.changes, [Self.ghostty, nil])
        XCTAssertEqual(harness.reads, 2)
    }

    func testABurstWhileAReadIsInFlightBecomesOneMoreRead() {
        let harness = Harness()
        harness.attributes = Self.window
        for _ in 0 ..< 5 { harness.focus.evaluate(Self.ghostty) }
        XCTAssertEqual(harness.reads, 1, "A slow terminal: one read in flight")

        // The slow read answers what it saw before the panel showed; the one after it sees the panel.
        harness.answerReads()
        XCTAssertEqual(harness.reads, 2, "The burst becomes one more read")
        XCTAssertEqual(harness.changes, [])

        harness.attributes = Self.panel
        harness.answerReads()
        XCTAssertEqual(harness.changes, [Self.ghostty])
        XCTAssertEqual(harness.reads, 2, "Nothing asked meanwhile: no more reads")
    }

    func testLeavingTheWatchCancelsTheReadInFlightAndItsReread() {
        let harness = Harness()
        harness.attributes = Self.panel
        harness.focus.evaluate(Self.ghostty)
        harness.focus.evaluate(Self.ghostty)

        harness.focus.watch([])
        XCTAssertTrue(harness.pendingReads.allSatisfy(\.flag.isCancelled))
        harness.answerReads()
        XCTAssertEqual(harness.reads, 1, "No reread for a terminal that left")
        XCTAssertEqual(harness.changes, [])

        // Watched again: a fresh read, not one left over.
        harness.focus.watch([Self.ghostty])
        harness.notify()
        XCTAssertEqual(harness.reads, 2)
        XCTAssertEqual(harness.changes, [Self.ghostty])
    }

    /// The quick terminal end to end through `ApplicationVM`, with only the
    /// system faked: running and frontmost apps, the panel's AX attributes and
    /// Ghostty's probe. The panel takes focus while TextEdit stays frontmost,
    /// so Ghostty's rules apply to the program on the panel's tty; once it
    /// collapses, TextEdit's apply again.
    func testAPanelHandsTheRulesToItsTerminalUntilItCollapses() throws {
        let textEdit = FakeApp(bundleIdentifier: "com.apple.TextEdit", pid: 999_001)
        let ghostty = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_002)
        let tty = "/dev/ttys009"
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var attributes = TerminalPanelFocusTests.panel
            var probes = 0
        }
        let state = State()

        let environment = ApplicationVM.Environment(
            frontmostApplication: { textEdit },
            focusedApplication: { nil },
            runningApplications: Just([textEdit, ghostty]).eraseToAnyPublisher(),
            isTerminalEnabled: { $0 == .ghostty },
            probedProgram: { _ in
                state.lock.withLock { state.probes += 1 }
                return TerminalReading(program: TerminalProgram(key: "claude", pane: tty), pane: tty)
            },
            terminalPanelFocus: TerminalPanelFocus.Environment(
                frontmostPID: { textEdit.processIdentifier },
                read: { _, answer in
                    let flag = CancelFlag()
                    DispatchQueue.main.async { if !flag.isCancelled { answer(state.attributes) } }
                    return AnyCancellable(flag)
                }
            )
        )
        let preferencesVM = try Self.inMemoryPreferencesVM()
        let applicationVM = ApplicationVM(preferencesVM: preferencesVM, environment: environment)
        let ruledApp = { applicationVM.appKind?.getApp() }

        waitUntil("Ghostty's panel stands in and its tty is probed") {
            ruledApp() === ghostty && preferencesVM.terminalPrograms[.ghostty]?.pane == tty
        }
        XCTAssertTrue(preferencesVM.terminalPanel === ghostty)
        XCTAssertGreaterThan(state.lock.withLock { state.probes }, 0)

        // Collapsed without a notification: the recheck while it had focus notices.
        state.attributes = Self.window
        waitUntil("TextEdit's rules apply again") { ruledApp() === textEdit }
        XCTAssertNil(preferencesVM.terminalPanel)
    }

    /// Each new focused pane of the terminal in front shows the indicator once,
    /// through the same path as a newly focused field; the same pane read
    /// again and a read without a pane don't.
    func testANewPaneOfTheFrontTerminalShowsTheIndicatorOnce() throws {
        let ghostty = FakeApp(bundleIdentifier: Terminal.ghostty.rawValue, pid: 999_003)
        let environment = ApplicationVM.Environment(
            frontmostApplication: { ghostty },
            focusedApplication: { nil },
            runningApplications: Just([ghostty]).eraseToAnyPublisher(),
            isTerminalEnabled: { $0 == .ghostty },
            probedProgram: { _ in TerminalReading(program: TerminalProgram(key: "claude", pane: "A"), pane: "A") },
            terminalPanelFocus: TerminalPanelFocus.Environment(
                frontmostPID: { ghostty.processIdentifier },
                read: { _, _ in AnyCancellable {} }
            )
        )
        let preferencesVM = try Self.inMemoryPreferencesVM()
        let applicationVM = ApplicationVM(preferencesVM: preferencesVM, environment: environment)
        var shows = 0
        let subscription = IndicatorWindowController.focusTriggeredIndicatorPublisher(
            initialEvent: nil,
            inputSource: InputSource.getCurrentInputSource(),
            focusedInputs: applicationVM.terminalPaneFocusChanges.filter { $0 == .ghostty }.mapToVoid().eraseToAnyPublisher()
        ) { _ in
            shows += 1
            return Just(()).eraseToAnyPublisher()
        }
        .sink { _ in }
        defer { subscription.cancel() }

        // Each read is waited on: lookups are latest-wins, so a quicker one would cancel it.
        func read(_ key: String?, pane: String?) {
            let program = key.map { TerminalProgram(key: $0, pane: pane) }
            applicationVM.sendTerminalLookup(for: .ghostty) { TerminalReading(program: program, pane: pane) }
            waitUntil("\(key ?? "shell") in \(pane ?? "no pane") is read") {
                preferencesVM.terminalPrograms[.ghostty] == program
            }
        }

        waitUntil("the first probe reads pane A") { preferencesVM.terminalPrograms[.ghostty]?.pane == "A" }
        XCTAssertEqual(shows, 1)

        read("vim", pane: "A")
        XCTAssertEqual(shows, 1, "Another program in the same pane is not a new pane")

        read("vim", pane: "B")
        XCTAssertEqual(shows, 2)

        read(nil, pane: nil)
        read("vim", pane: "B")
        XCTAssertEqual(shows, 2, "A read without a pane neither shows nor forgets the pane")
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out: \(what)", file: file, line: line) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private static func inMemoryPreferencesVM() throws -> PreferencesVM {
        let container = NSPersistentContainer(name: "Main", managedObjectModel: PreferencesVM.managedObjectModel)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        let preferencesVM = PreferencesVM(permissionsVM: PermissionsVM(), container: container)
        preferencesVM.mainStorage.refresh()
        return preferencesVM
    }

    /// An app that isn't running: AX on its pid answers nothing.
    private final class FakeApp: NSRunningApplication, @unchecked Sendable {
        private let fakeBundleIdentifier: String
        private let pid: pid_t

        init(bundleIdentifier: String, pid: pid_t) {
            fakeBundleIdentifier = bundleIdentifier
            self.pid = pid
            super.init()
        }

        override var bundleIdentifier: String? { fakeBundleIdentifier }
        override var processIdentifier: pid_t { pid }
        override var isTerminated: Bool { false }
        // NSRunningApplication compares its own process handle, which fakes don't have.
        override func isEqual(_ object: Any?) -> Bool { (object as AnyObject?) === self }
        override var hash: Int { ObjectIdentifier(self).hashValue }
    }

    func testFlippingTheFrontTerminalsSwitchRebuildsItsSubscription() {
        var isEnabled = false
        let evaluations = PassthroughSubject<Void, Never>()
        var subscribed: [String] = []
        var cancelled: [String] = []

        let subscription = ApplicationVM.frontmostSubscriptions(
            evaluations: evaluations.eraseToAnyPublisher(),
            ruledApp: { "ghostty" },
            watchedTerminal: { _ in isEnabled ? Terminal.ghostty : nil },
            subscribe: { app, terminal -> AnyPublisher<Void, Never> in
                let label = "\(app):\(terminal?.rawValue ?? "-")"
                subscribed.append(label)
                return Empty(completeImmediately: false)
                    .handleEvents(receiveCancel: { cancelled.append(label) })
                    .eraseToAnyPublisher()
            }
        )
        .sink { _ in }
        defer { subscription.cancel() }
        let plain = "ghostty:-"
        let watched = "ghostty:\(Terminal.ghostty.rawValue)"
        XCTAssertEqual(subscribed, [plain])

        evaluations.send(())
        XCTAssertEqual(subscribed, [plain], "Same app, same switch: kept")

        isEnabled = true
        evaluations.send(())
        XCTAssertEqual(subscribed, [plain, watched])
        XCTAssertEqual(cancelled, [plain])

        evaluations.send(())
        XCTAssertEqual(subscribed.count, 2)

        isEnabled = false
        evaluations.send(())
        XCTAssertEqual(subscribed, [plain, watched, plain])
        XCTAssertEqual(cancelled, [plain, watched], "Switched off: its watch stops")
    }

    func testRulesFollowISPThenAPanelThenTheFocusedApp() {
        XCTAssertEqual(ApplicationVM.ruledApp(front: "isp", isOwn: true, panel: "ghostty") { "x" }, "isp")
        XCTAssertEqual(ApplicationVM.ruledApp(front: "textedit", isOwn: false, panel: "ghostty") { "x" }, "ghostty")
        XCTAssertEqual(ApplicationVM.ruledApp(front: "textedit", isOwn: false, panel: nil) { "focused" }, "focused")
    }

    func testOnlyAFloatingWindowOfTheFrontmostAppIsAPanel() {
        typealias Attributes = TerminalPanelFocus.Attributes
        XCTAssertTrue(TerminalPanelFocus.isPanelFocused(Self.panel))
        XCTAssertFalse(TerminalPanelFocus.isPanelFocused(Attributes(isFrontmost: false, focusedWindowSubrole: "AXFloatingWindow")))
        XCTAssertFalse(TerminalPanelFocus.isPanelFocused(Attributes(isFrontmost: true, focusedWindowSubrole: "AXStandardWindow")))
        XCTAssertFalse(TerminalPanelFocus.isPanelFocused(Attributes(isFrontmost: true, focusedWindowSubrole: nil)))
    }

    func testAnAppThatIsGoneReadsAsNothing() {
        XCTAssertNil(TerminalPanelFocus.attributes(of: -1))
    }
}
