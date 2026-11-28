#!/usr/bin/env swift
import AppKit
import Foundation

func fail(_ message: String) -> Never {
    fputs("mktown-open: \(message)\n", stderr)
    exit(1)
}

var arguments = CommandLine.arguments.dropFirst()
if arguments == ["--help"] || arguments == ["-h"] {
    print("Usage: mktown-open [--readonly] [--line LINE] FILE_OR_FILE_URL")
    exit(0)
}

var line: Int?
var isReadOnly = false
while let option = arguments.first, option == "--line" || option == "--readonly" {
    arguments.removeFirst()
    if option == "--readonly" {
        guard !isReadOnly else { fail("--readonly can only be specified once") }
        isReadOnly = true
    } else {
        guard line == nil else { fail("--line can only be specified once") }
        guard let argument = arguments.popFirst(), let value = Int(argument), value > 0 else {
            fail("--line requires a positive line number")
        }
        line = value
    }
}
if arguments.first == "--" { arguments.removeFirst() }
guard arguments.count == 1, let argument = arguments.first else { fail("expected one file path or file URL") }
let fileURL: URL
if argument.hasPrefix("file:") {
    guard let parsed = URL(string: argument), parsed.isFileURL else { fail("invalid file URL") }
    fileURL = parsed
} else {
    fileURL = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath,
                  relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
}
let normalized = fileURL.resolvingSymlinksInPath().standardizedFileURL
guard ["md", "markdown", "mdown", "mkd", "txt"].contains(normalized.pathExtension.lowercased()),
      FileManager.default.fileExists(atPath: normalized.path) else {
    fail("choose an existing Markdown or text document")
}
var components = URLComponents()
components.scheme = "mktowneditor"
components.host = "open"
components.queryItems = [URLQueryItem(name: "url", value: normalized.absoluteString)]
if let line { components.queryItems?.append(URLQueryItem(name: "line", value: String(line))) }
if isReadOnly { components.queryItems?.append(URLQueryItem(name: "readonly", value: "1")) }
guard let url = components.url, NSWorkspace.shared.open(url) else {
    fail("could not open MKTownEditor; launch the app once to register its URL scheme")
}
