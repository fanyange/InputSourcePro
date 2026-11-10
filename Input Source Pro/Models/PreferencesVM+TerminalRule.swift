import Foundation

extension PreferencesVM {
    var terminalRules: [TerminalRule] {
        preferences.terminalRules ?? []
    }

    /// Adds `rule`, or replaces the stored rule with the same id.
    func saveTerminalRule(_ rule: TerminalRule) {
        var rules = terminalRules

        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }

        setTerminalRules(rules)
    }

    func deleteTerminalRules(ids: Set<UUID>) {
        setTerminalRules(terminalRules.filter { !ids.contains($0.id) })
    }

    func getTerminalRule(program: TerminalProgram) -> TerminalRule? {
        TerminalRule.firstEnabledRule(matching: program, in: terminalRules)
    }

    private func setTerminalRules(_ rules: [TerminalRule]) {
        update { $0.terminalRules = rules }
        notifyRuntimeRulesChanged()
    }
}

extension PreferencesVM {
    func isTerminalEnabled(_ terminal: Terminal) -> Bool {
        preferences.enabledTerminals.contains(terminal.rawValue)
    }

    /// The tty of an enabled terminal's focused pane, whether it runs a program or a shell.
    func focusedTerminalTTY(_ terminal: Terminal) -> String? {
        isTerminalEnabled(terminal) ? terminalTTYs[terminal] : nil
    }

    func setTerminal(_ terminal: Terminal, enabled: Bool) {
        update { $0.setTerminal(terminal, enabled: enabled) }
        notifyRuntimeRulesChanged()
    }
}

extension Preferences {
    mutating func setTerminal(_ terminal: Terminal, enabled: Bool) {
        // One write: each assignment goes to UserDefaults.
        enabledTerminals = enabledTerminals.filter { $0 != terminal.rawValue } + (enabled ? [terminal.rawValue] : [])
    }
}
