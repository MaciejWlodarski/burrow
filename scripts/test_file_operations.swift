#!/usr/bin/env swift
import Foundation

// Compile the actual production helpers in isolation. All file operations run in
// a disposable fixture; the injected Trash is another folder inside that fixture.
// Run: swift scripts/test_file_operations.swift
// Full manager/history/ZIP/Git regressions also run in FileOperationSafetyTests
// through scripts/run_tests.sh; do not treat this isolated helper suite as UI coverage.
let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let manager = try String(contentsOf: project.appendingPathComponent("Sources/Burrow/Engine/FileOperationsManager.swift"), encoding: .utf8)
let model = try String(contentsOf: project.appendingPathComponent("Sources/Burrow/Models/FileItem.swift"), encoding: .utf8)
func section(_ text: String, from start: String, to end: String) -> String {
    guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex) else {
        fatalError("Production source markers changed: \(start)")
    }
    return String(text[a.lowerBound..<b.lowerBound])
}
// Include the entry identity dependency introduced by guarded history actions.
let core = section(manager, from: "struct FileEntryIdentity", to: "/// Thread-safe cancellation flag")
let tags = section(model, from: "public enum FinderTagColor", to: "public enum FileKindCategory")
// Restore actions call this production naming helper; extract it rather than
// substituting a test-only implementation of collision handling.
let naming = section(manager, from: "    nonisolated public static func uniqueURL", to: "    /// The creator must fail")
let managerNamespace = "enum FileOperationsManager {\n" + naming + "\n}\n"
let harness = #"""
import Foundation
import Darwin
import SwiftUI

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw FileOperationFailure(message: "FAIL: " + message) }
}

final class Fixture {
    let root: URL
    let source: URL
    let target: URL
    let trash: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("bf-operations-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source/item.txt")
        target = root.appendingPathComponent("destination/item.txt")
        trash = root.appendingPathComponent("test-trash", isDirectory: true)
        for directory in [source.deletingLastPathComponent(), target.deletingLastPathComponent(), trash] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "incoming".write(to: source, atomically: true, encoding: .utf8)
        try "original".write(to: target, atomically: true, encoding: .utf8)
    }

    deinit { try? fm.removeItem(at: root) }

    var io: FileOperationIO {
        var io = FileOperationIO.live
        io.trash = { [self] url in
            try require(url.path.hasPrefix(root.path + "/"), "Trash must remain inside the fixture")
            let destination = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try fm.moveItem(at: url, to: destination)
            return destination
        }
        return io
    }

    func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func isStaged(_ url: URL) -> Bool { url.deletingLastPathComponent().lastPathComponent.hasPrefix(".burrow-transfer-") }
}

func failure(_ body: () throws -> Void) throws -> FileOperationFailure {
    do { try body() } catch let error as FileOperationFailure { return error }
    throw FileOperationFailure(message: "FAIL: expected FileOperationFailure")
}

var checks = 0
func test(_ name: String, _ body: () throws -> Void) throws {
    try body()
    checks += 1
    print("PASS: \(name)")
}

for isMove in [false, true] {
    try test("replacement \(isMove ? "move" : "copy") undo/redo preserves both versions") {
        let f = try Fixture()
        var undo = try SafeFileReplacement.replace(source: f.source, target: f.target, isMove: isMove, io: f.io)
        for _ in 0..<3 {
            try require(f.text(f.target) == "incoming", "replacement must install incoming data")
            let result = FileHistoryExecutor.execute(undo, io: f.io)
            try require(result.error == nil && result.pending.isEmpty, "undo must complete")
            try require(f.text(f.target) == "original", "undo must restore original")
            try require(f.text(f.source) == "incoming", "undo must retain source")
            let redo = FileHistoryExecutor.execute(result.inverse, io: f.io)
            try require(redo.error == nil && redo.pending.isEmpty, "redo must complete")
            try require(f.text(f.target) == "incoming", "redo must restore incoming data")
            try require(f.io.exists(f.source) == !isMove, "source ownership must match operation")
            undo = redo.inverse
        }
    }

    try test("Trash failure does not delete destination or source (\(isMove))") {
        let f = try Fixture()
        var io = f.io
        io.trash = { _ in throw FileOperationFailure(message: "injected Trash failure") }
        let error = try failure { _ = try SafeFileReplacement.replace(source: f.source, target: f.target, isMove: isMove, io: io) }
        try require(error.message.contains("injected Trash failure"), "must report Trash error")
        try require(f.text(f.target) == "original", "Trash failure must preserve destination")
        try require(f.text(f.source) == "incoming", "Trash failure must preserve source")
    }

    try test("installation failure restores destination and source (\(isMove))") {
        let f = try Fixture()
        var io = f.io
        io.move = { from, to in
            if f.isStaged(from) && to == f.target { throw FileOperationFailure(message: "injected installation failure") }
            try f.fm.moveItem(at: from, to: to)
        }
        let error = try failure { _ = try SafeFileReplacement.replace(source: f.source, target: f.target, isMove: isMove, io: io) }
        try require(error.recoveryActions.isEmpty, "successful rollback must not leave pending restoration")
        try require(f.text(f.target) == "original", "installation failure must restore original")
        try require(f.text(f.source) == "incoming", "installation failure must restore source")
    }
}

try test("failed preparation never touches original; partial data remains discoverable") {
    let f = try Fixture()
    var io = f.io
    var partial: URL?
    io.copy = { _, to in
        partial = to
        try "partial".write(to: to, atomically: true, encoding: .utf8)
        throw FileOperationFailure(message: "injected preparation failure")
    }
    io.trash = { _ in throw FileOperationFailure(message: "FAIL: Trash must not be called") }
    let error = try failure { _ = try SafeFileReplacement.replace(source: f.source, target: f.target, isMove: false, io: io) }
    try require(f.text(f.target) == "original" && f.text(f.source) == "incoming", "preparation must preserve both originals")
    try require(partial != nil && error.message.contains(partial!.path), "failure must report preserved partial file")
    try require(f.text(partial!) == "partial", "must not recursively delete partial data")
}

try test("failed destination rollback retains original and retryable history") {
    let f = try Fixture()
    var io = f.io
    io.move = { from, to in
        if to == f.target { throw FileOperationFailure(message: "injected destination failure") }
        try f.fm.moveItem(at: from, to: to)
    }
    let error = try failure { _ = try SafeFileReplacement.replace(source: f.source, target: f.target, isMove: true, io: io) }
    try require(error.recoveryActions.count == 1, "failed restoration must retain recovery action")
    try require(f.text(f.source) == "incoming", "incoming source must be restored")
    let recovery = FileHistoryExecutor.execute(error.recoveryActions, io: f.io)
    try require(recovery.error == nil && f.text(f.target) == "original", "retry must restore original")
}

try test("failed source rollback retains incoming data and retryable history") {
    let f = try Fixture()
    var io = f.io
    io.trash = { _ in throw FileOperationFailure(message: "injected Trash failure") }
    io.move = { from, to in
        if to == f.source { throw FileOperationFailure(message: "injected source restoration failure") }
        try f.fm.moveItem(at: from, to: to)
    }
    let error = try failure { _ = try SafeFileReplacement.replace(source: f.source, target: f.target, isMove: true, io: io) }
    try require(error.recoveryActions.count == 1, "failed source rollback must retain recovery action")
    let recovery = FileHistoryExecutor.execute(error.recoveryActions, io: f.io)
    try require(recovery.error == nil && f.text(f.source) == "incoming", "retry must restore incoming source")
    try require(f.text(f.target) == "original", "original destination must be untouched")
}

try test("undo collision preserves newer source and leaves actions retryable") {
    let f = try Fixture()
    let actions = try SafeFileReplacement.replace(source: f.source, target: f.target, isMove: true, io: f.io)
    try "newer".write(to: f.source, atomically: true, encoding: .utf8)
    let result = FileHistoryExecutor.execute(actions, io: f.io)
    try require(result.error != nil && result.completedCount == 0 && result.pending.count == 2, "collision must stop with pending actions")
    try require(f.text(f.source) == "newer" && f.text(f.target) == "incoming", "collision must preserve current files")
}

try test("partial undo reports failure, keeps retry, and supports reversing completed steps") {
    let f = try Fixture()
    let actions = try SafeFileReplacement.replace(source: f.source, target: f.target, isMove: false, io: f.io)
    var io = f.io
    io.move = { _, _ in throw FileOperationFailure(message: "injected restore failure") }
    let result = FileHistoryExecutor.execute(actions, io: io)
    try require(result.error != nil && result.completedCount == 1 && result.pending.count == 1, "partial undo must preserve pending step")
    let reverse = FileHistoryExecutor.execute(result.inverse, io: f.io)
    try require(reverse.error == nil && f.text(f.target) == "incoming", "completed step must be reversible")
    let undoAgain = FileHistoryExecutor.execute(reverse.inverse + result.pending, io: f.io)
    try require(undoAgain.error == nil && f.text(f.target) == "original", "retry must restore original")
}

try test("replacement of source ancestor is rejected before mutation") {
    let f = try Fixture()
    let ancestor = f.source.deletingLastPathComponent()
    _ = try failure { _ = try SafeFileReplacement.replace(source: f.source, target: ancestor, isMove: true, io: f.io) }
    try require(f.text(f.source) == "incoming", "ancestor rejection must preserve source")
}

try test("color changes preserve custom tags and localized color names") {
    let original = ["Client A", "Czerwony", "Review\n6", "Blue", "Another Tag"]
    let updated = FinderTagColor.tagNames(replacingColorsWith: [.red, .green], in: original)
    try require(updated == ["Client A", "Czerwony", "Review\n6", "Another Tag", "Green"], "custom names and localized color names must survive")
    let clearedColors = FinderTagColor.tagNames(replacingColorsWith: [], in: original)
    try require(clearedColors == ["Client A", "Review\n6", "Another Tag"], "color update must not remove custom tags")
}

try test("cut clipboard completion removes only successfully moved entries") {
    let urls = ["/test/moved", "/test/skipped", "/test/failed", "/test/cancelled"].map { URL(fileURLWithPath: $0) }
    let snapshot = CutClipboardSnapshot(changeCount: 42)
    let remaining = snapshot.remainingURLs(urls, internalChangeCount: 42, systemChangeCount: 42, movedSources: [urls[0]])
    try require(remaining == Array(urls.dropFirst()), "unmoved entries must remain cut")
}

try test("cut clipboard completion preserves a newer in-app clipboard") {
    let urls = [URL(fileURLWithPath: "/test/newer-cut")]
    let remaining = CutClipboardSnapshot(changeCount: 42).remainingURLs(urls, internalChangeCount: 43, systemChangeCount: 43, movedSources: urls)
    try require(remaining == nil, "a newer copy/cut must not be modified")
}

try test("cut clipboard completion preserves a newer external clipboard") {
    let urls = [URL(fileURLWithPath: "/test/old-cut")]
    let remaining = CutClipboardSnapshot(changeCount: 42).remainingURLs(urls, internalChangeCount: 42, systemChangeCount: 43, movedSources: urls)
    try require(remaining == nil, "external clipboard writes must not be modified")
}

try test("native tag read/write preserves custom metadata on temporary file") {
    let f = try Fixture()
    try (f.source as NSURL).setResourceValue(["Client A", "Red"], forKey: .tagNamesKey)
    try FinderTagColor.writeTags([.red, .green], to: f.source)
    try require(Set(FinderTagColor.readTagNames(for: f.source)) == Set(["Client A", "Red", "Green"]), "live write must preserve custom tags")
    try FinderTagColor.clearAllTags(for: f.source)
    try require(FinderTagColor.readTagNames(for: f.source).isEmpty, "explicit clear all must clear all names")
}

print("\(checks) focused file-operation checks passed; system Trash and clipboard were not used.")
"""#

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bf-operations-build-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let source = scratch.appendingPathComponent("main.swift")
let executable = scratch.appendingPathComponent("file-operation-checks")
try ("import Foundation\nimport Darwin\nimport SwiftUI\n" + core + managerNamespace + tags + harness).write(to: source, atomically: true, encoding: .utf8)
func run(_ command: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 { exit(process.terminationStatus) }
}
try run("/usr/bin/xcrun", ["swiftc", "-module-cache-path", scratch.appendingPathComponent("module-cache").path, source.path, "-o", executable.path])
try run(executable.path, [])
