#!/usr/bin/env swift

import Foundation

// This script performs code quality scanning on the project
// Usage: swift Scripts/quality-scan.swift [path]

// MARK: - String Helpers

func stripStringsAndComments(_ line: String) -> String {
    var result = ""
    var inString = false
    var i = line.startIndex

    while i < line.endIndex {
        let char = line[i]

        if !inString {
            if char == "\"" {
                inString = true
            } else if char == "/" && line.index(after: i) < line.endIndex && line[line.index(after: i)] == "/" {
                break // Rest is comment
            } else {
                result.append(char)
            }
        } else if char == "\"" {
            inString = false
        }

        i = line.index(after: i)
    }

    return result
}

// MARK: - Detectors

func detectForceUnwrap(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.hasPrefix("//") else { return false }

    let codeOnly = stripStringsAndComments(trimmed)

    // Strip IUO declarations (e.g., "var foo: Type!", "param: Type!")
    let withoutIUO = codeOnly.replacingOccurrences(
        of: ":\\s*[A-Z][\\w.<>,\\[\\]? ]*!",
        with: ": _IUO_",
        options: .regularExpression
    )

    // Skip lines with != or boolean negation (! followed by space)
    if withoutIUO.contains("!=") || withoutIUO.contains("! ") {
        return false
    }

    // Match force unwrap patterns: identifier!, }!, ]!, )!
    let patterns = ["\\w!", "\\}!", "\\]!", "\\)!"]
    for pattern in patterns {
        if withoutIUO.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
    }

    return false
}

func detectForceCast(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.hasPrefix("//") else { return false }
    let codeOnly = stripStringsAndComments(trimmed)
    return codeOnly.contains(" as! ")
}

func detectEmptyCountCheck(_ line: String) -> Bool {
    let codeOnly = stripStringsAndComments(line)
    return codeOnly.contains(".count == 0") || codeOnly.contains(".count==0")
}

// MARK: - Scanner

func scanDirectory(_ path: String) {
    let fileManager = FileManager.default

    guard let enumerator = fileManager.enumerator(atPath: path) else {
        print("Error: Cannot access \(path)")
        return
    }

    var issues: [(file: String, line: Int, severity: String, rule: String, message: String)] = []

    for case let file as String in enumerator {
        guard file.hasSuffix(".swift") else { continue }

        let filePath = "\(path)/\(file)"
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            continue
        }

        let lines = content.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let lineNum = index + 1

            if detectForceUnwrap(line) {
                issues.append((filePath, lineNum, "error", "force_unwrapping",
                    "Force unwrap detected (!) - use safe unwrapping instead"))
            }

            if detectForceCast(line) {
                issues.append((filePath, lineNum, "warning", "force_cast",
                    "Force cast detected (as!) - use safe casting instead"))
            }

            if detectEmptyCountCheck(line) {
                issues.append((filePath, lineNum, "info", "empty_count",
                    "Use .isEmpty instead of .count == 0"))
            }
        }
    }

    printReport(issues)
}

// MARK: - Report

func printReport(_ issues: [(file: String, line: Int, severity: String, rule: String, message: String)]) {
    if issues.isEmpty {
        print("\n✅ No issues found! Code quality check passed.")
        return
    }

    print("\n━━━ Code Quality Report ━━━\n")

    let grouped = Dictionary(grouping: issues, by: { $0.file })
    for (file, fileIssues) in grouped.sorted(by: { $0.key < $1.key }) {
        print("📄 \(file)")
        for issue in fileIssues.sorted(by: { $0.line < $1.line }) {
            let icon = issue.severity == "error" ? "❌" : issue.severity == "warning" ? "⚠️ " : "ℹ️ "
            print("  \(icon) Line \(issue.line) [\(issue.rule)]: \(issue.message)")
        }
        print()
    }

    let errorCount = issues.filter { $0.severity == "error" }.count
    let warningCount = issues.filter { $0.severity == "warning" }.count
    let infoCount = issues.filter { $0.severity == "info" }.count

    print("━━━ Summary ━━━")
    print("Total issues: \(issues.count)")
    print("  ❌ Errors: \(errorCount)")
    print("  ⚠️  Warnings: \(warningCount)")
    print("  ℹ️  Info: \(infoCount)")
    print()

    if errorCount > 0 {
        print("❌ Quality gate failed")
        exit(1)
    } else if warningCount > 0 {
        print("⚠️  Review \(warningCount) warning(s)")
    } else {
        print("✅ Code quality check passed!")
    }
}

// Main
let sourceDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/PingClaude"
scanDirectory(sourceDir)
