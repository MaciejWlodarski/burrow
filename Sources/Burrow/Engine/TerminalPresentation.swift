import Foundation

/// Deliberately not a shell interpreter. Only a small, literal standalone cd
/// grammar may change the terminal tab directory. Everything else runs unchanged in the per-run
/// zsh, whose cwd changes do not persist into the terminal tab or the next command.
enum TerminalDirectoryCommand {
    static func target(for command: String, directory: URL, home: String = NSHomeDirectory()) -> URL? {
        // Classification must not copy/scan an arbitrarily large executable input.
        guard command.utf8.prefix(16_385).count <= 16_384 else { return nil }
        let input = Array(command.unicodeScalars)
        var index = 0
        var words: [(text: String, home: Bool)] = []
        func separator(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }
        while index < input.count {
            while index < input.count && separator(input[index]) { index += 1 }
            if index == input.count { break }
            guard words.count < 3 else { return nil }
            var text = ""
            var quote: Unicode.Scalar?
            var expandsHome = false
            let start = index
            while index < input.count {
                let c = input[index]
                // Newlines (even quoted) and NUL are outside this navigation grammar.
                if c == "\n" || c == "\r" || c.value == 0 { return nil }
                if quote == "'" {
                    if c == "'" { quote = nil } else { text.unicodeScalars.append(c) }
                    index += 1
                    continue
                }
                if c == "\\" {
                    guard index + 1 < input.count else { return nil }
                    let next = input[index + 1]
                    if next == "\n" || next == "\r" || next.value == 0 { return nil }
                    // Inside double quotes, backslash only quotes $, `, ", \\.
                    if quote == "\"" && !"$`\"\\".unicodeScalars.contains(next) {
                        text.unicodeScalars.append(c)
                        index += 1
                    } else {
                        text.unicodeScalars.append(next)
                        index += 2
                    }
                    continue
                }
                if quote == "\"" {
                    if c == "\"" { quote = nil }
                    else if c == "$" || c == "`" { return nil }
                    else { text.unicodeScalars.append(c) }
                    index += 1
                    continue
                }
                if separator(c) { break }
                if c == "'" || c == "\"" { quote = c; index += 1; continue }
                if ";&|<>()$`*?[]{}!#=".unicodeScalars.contains(c) { return nil }
                if c == "~" {
                    guard index == start, words.count > 0,
                          index + 1 == input.count || input[index + 1] == "/" || separator(input[index + 1]) else { return nil }
                    expandsHome = true
                }
                text.unicodeScalars.append(c)
                index += 1
            }
            guard quote == nil else { return nil }
            words.append((text, expandsHome))
        }
        guard words.first?.text == "cd" else { return nil }
        var operands = Array(words.dropFirst())
        let endOfOptions = operands.first?.text == "--"
        if endOfOptions { operands.removeFirst() }
        guard operands.count <= 1 else { return nil }
        guard let operand = operands.first else { return URL(fileURLWithPath: home, isDirectory: true) }
        // cd - / +N depend on shell directory-stack state, not terminal-tab state.
        guard !operand.text.isEmpty, operand.text != "-", !operand.text.hasPrefix("+"),
              endOfOptions || !operand.text.hasPrefix("-") else { return nil }
        let path = operand.home ? home + String(operand.text.dropFirst()) : operand.text
        if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        return directory.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }
}

public struct TerminalOutputLine: Identifiable {
    public let id = UUID()
    public let text: String
    public let isCommand: Bool
    public let isError: Bool
}

/// All limits include display markers. Strings are built into new, bounded
/// storage, never retained as slices of the original command/session output.
struct TerminalTranscript {
    static let evictionMarker = "[Starsze wpisy usunięto z bufora.]"
    static let truncationMarker = " [Wpis skrócony.]"
    static let appendMarker = "[Dalsze wyjście pominięto w widoku.]"
    let byteLimit: Int
    let rowLimit: Int
    let entryByteLimit: Int
    private(set) var lines: [TerminalOutputLine] = []
    private(set) var retainedUTF8Bytes = 0
    private(set) var hasEvicted = false

    init(byteLimit: Int = 256 * 1024, rowLimit: Int = 2_000, entryByteLimit: Int = 16 * 1024) {
        // Reserve space for an eviction marker and at least one complete entry.
        self.byteLimit = max(256, byteLimit)
        self.rowLimit = max(2, rowLimit)
        self.entryByteLimit = min(max(128, entryByteLimit), max(256, byteLimit) / 2)
    }

    mutating func removeAll() {
        lines.removeAll()
        retainedUTF8Bytes = 0
        hasEvicted = false
    }

    mutating func append(text: String, isCommand: Bool = false, isError: Bool = false) {
        append(parts: [text], isCommand: isCommand, isError: isError)
    }

    mutating func append(parts: [String], isCommand: Bool = false, isError: Bool = false) {
        var text = ""
        var bytes = 0
        let contentLimit = entryByteLimit - Self.truncationMarker.utf8.count
        var truncated = false
        outer: for part in parts {
            for scalar in part.unicodeScalars {
                let count = scalar.utf8.count
                guard bytes + count <= contentLimit else { truncated = true; break outer }
                text.unicodeScalars.append(scalar)
                bytes += count
            }
        }
        if truncated { text += Self.truncationMarker }
        store(text, isCommand: isCommand, isError: isError)
    }

    /// Scan at most byteLimit bytes per completion, with no split array or huge
    /// temporary line. Beyond that prefix the display explicitly reports omission.
    mutating func appendOutput(_ output: String) {
        var line = ""
        var lineBytes = 0
        var scannedBytes = 0
        var emittedRows = 0
        var truncatedLine = false
        let contentLimit = entryByteLimit - Self.truncationMarker.utf8.count
        for scalar in output.unicodeScalars {
            let count = scalar.utf8.count
            if scannedBytes + count > byteLimit || emittedRows >= rowLimit {
                if truncatedLine { line += Self.truncationMarker }
                store(line)
                store(Self.appendMarker)
                return
            }
            scannedBytes += count
            if scalar == "\n" {
                if truncatedLine { line += Self.truncationMarker }
                store(line)
                emittedRows += 1
                line = ""; lineBytes = 0; truncatedLine = false
            } else if lineBytes + count <= contentLimit && !truncatedLine {
                line.unicodeScalars.append(scalar)
                lineBytes += count
            } else {
                truncatedLine = true
            }
        }
        if truncatedLine { line += Self.truncationMarker }
        store(line)
    }

    private mutating func store(_ text: String, isCommand: Bool = false, isError: Bool = false) {
        let bytes = text.utf8.count // text is already entry-bounded
        let markerBytes = Self.evictionMarker.utf8.count
        if hasEvicted {
            retainedUTF8Bytes -= lines.removeFirst().text.utf8.count
        }
        while lines.count + 1 + (hasEvicted ? 1 : 0) > rowLimit ||
                retainedUTF8Bytes + bytes + (hasEvicted ? markerBytes : 0) > byteLimit {
            retainedUTF8Bytes -= lines.removeFirst().text.utf8.count
            hasEvicted = true
        }
        if hasEvicted {
            lines.insert(TerminalOutputLine(text: Self.evictionMarker, isCommand: false, isError: false), at: 0)
            retainedUTF8Bytes += markerBytes
        }
        lines.append(TerminalOutputLine(text: text, isCommand: isCommand, isError: isError))
        retainedUTF8Bytes += bytes
    }
}
