import Foundation

/// A console's own keys, laid out as a panel: keywords, the number pad, and
/// playback and programmer keys.
///
/// Consoles differ in what they take over the network, so a panel works one
/// of two ways (`commandLine`):
///
/// - `.local`: the keys build a command line in the app (`Group 1 Thru 5 At
///   Full`), and Enter sends it as one command. For consoles that take whole
///   command lines but not key presses (grandMA3, the Lighting console).
/// - `.console`: each key is pressed and released on the console itself, as if
///   on its face panel, and the console reports its command line back (Eos).
///
/// `.none`: the keys act straight away; there's no command line (MagicQ).
public struct KeyPanel: Equatable, Sendable {
    public enum CommandLine: Equatable, Sendable {
        case none
        /// Built in the app; Enter sends it to this control as `.text`.
        case local(send: ControlID)
        /// Kept on the console; shown from `Device.info[infoKey]`.
        case console(infoKey: String)
    }

    public let commandLine: CommandLine
    public let sections: [KeySection]

    public init(commandLine: CommandLine, sections: [KeySection]) {
        self.commandLine = commandLine
        self.sections = sections
    }

    /// Every key on the panel.
    public var keys: [PanelKey] { sections.flatMap { $0.rows.flatMap { $0 } } }

    // MARK: Building a local command line

    /// Adds a key's text to a command line: digits and points join the number
    /// before them ("1" then "2" is "12"); everything else is its own word.
    public static func append(_ token: String, to line: String) -> String {
        guard !line.isEmpty else { return token }
        if isNumeric(token), let last = line.last, last.isNumber || last == "." {
            return line + token
        }
        return line + " " + token
    }

    /// Takes back the last key: one digit of a number, or one whole word.
    public static func deleteLast(_ line: String) -> String {
        guard let last = line.last else { return line }
        var result = line
        if last.isNumber || last == "." {
            result.removeLast()
        } else if let space = line.lastIndex(of: " ") {
            result = String(line[..<space])
        } else {
            result = ""
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func isNumeric(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isNumber || $0 == "." }
    }
}

/// Keys that belong together, like "Numbers" or "Playback", in rows.
public struct KeySection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let rows: [[PanelKey]]

    public init(id: String, title: String, rows: [[PanelKey]]) {
        self.id = id
        self.title = title
        self.rows = rows
    }

    /// The widest row, in key widths.
    public var columns: Int { rows.map { $0.reduce(0) { $0 + $1.span } }.max() ?? 1 }
}

public struct PanelKey: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Adds this text to the app's command line.
        case type(String)
        /// Sends the app's command line.
        case enter
        /// Clears the app's command line; when it's already empty, fires this
        /// control instead (the console's own Clear), if there is one.
        case clear(ControlID?)
        /// Takes back the last key on the app's command line.
        case backspace
        /// Fires a control once: `.trigger`.
        case trigger(ControlID)
        /// Holds a key down while the finger is on it: `.press(true)`, then `.press(false)`.
        case press(ControlID)
        /// Not a key: a label at the start of a row.
        case label
    }

    /// What the key is for, which sets its colour.
    public enum Role: String, Sendable {
        case normal
        /// Objects and functions: Group, Cue, Store, At.
        case keyword
        case number
        /// Go, Go+.
        case go
        /// Pause, Stop, Off, Release.
        case stop
        /// Enter, Please.
        case enter
        /// Clear, Oops, Delete.
        case clear
    }

    public let id: String
    public let label: String
    public let action: Action
    public let role: Role
    /// How many key widths it takes.
    public let span: Int
    /// Ask before firing (trigger keys only).
    public let needsConfirmation: Bool

    public init(_ id: String, _ label: String, _ action: Action, role: Role = .normal, span: Int = 1,
                needsConfirmation: Bool = false) {
        self.id = id
        self.label = label
        self.action = action
        self.role = role
        self.span = max(1, span)
        self.needsConfirmation = needsConfirmation
    }

    // MARK: Shorthand for drivers

    /// A key that types a word into the app's command line.
    public static func word(_ text: String, role: Role = .keyword, span: Int = 1) -> PanelKey {
        PanelKey("type.\(text)", text, .type(text), role: role, span: span)
    }

    /// 7 8 9 / 4 5 6 / 1 2 3 / 0 . — typing into the app's command line.
    public static func numberPad(extra: [PanelKey] = []) -> [[PanelKey]] {
        let digits = [["7", "8", "9"], ["4", "5", "6"], ["1", "2", "3"]].map { row in
            row.map { PanelKey("type.\($0)", $0, .type($0), role: .number) }
        }
        let last = [PanelKey("type.0", "0", .type("0"), role: .number, span: 2), PanelKey("type..", ".", .type("."), role: .number)]
        return digits + [last] + (extra.isEmpty ? [] : [extra])
    }
}
