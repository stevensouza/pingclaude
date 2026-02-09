import Foundation

/// Code Quality Scanner - detects vulnerabilities, code smells, and bugs
struct CodeQualityScanner {
    struct Issue {
        enum Severity: String {
            case error, warning, info
        }

        let file: String
        let line: Int
        let severity: Severity
        let rule: String
        let message: String
    }

    static func scanProject(sourceDir: String = "Sources/PingClaude") -> [Issue] {
        var issues: [Issue] = []

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: sourceDir) else {
            return issues
        }

        for case let file as String in enumerator {
            guard file.hasSuffix(".swift") else { continue }
            let filePath = "\(sourceDir)/\(file)"

            if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                issues.append(contentsOf: scanFile(filePath, content: content))
            }
        }

        return issues.sorted {
            if $0.severity.rawValue != $1.severity.rawValue {
                return $0.severity.rawValue < $1.severity.rawValue
            }
            if $0.file != $1.file {
                return $0.file < $1.file
            }
            return $0.line < $1.line
        }
    }

    private static func scanFile(_ filePath: String, content: String) -> [Issue] {
        var issues: [Issue] = []
        let lines = content.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let lineNum = index + 1

            // Rule: Force unwraps
            if detectForceUnwrap(line) {
                issues.append(Issue(
                    file: filePath,
                    line: lineNum,
                    severity: .error,
                    rule: "force_unwrapping",
                    message: "Force unwrap detected (!) - use safe unwrapping instead"
                ))
            }

            // Rule: Force casts
            if detectForceCast(line) {
                issues.append(Issue(
                    file: filePath,
                    line: lineNum,
                    severity: .warning,
                    rule: "force_cast",
                    message: "Force cast detected (as!) - use safe casting instead"
                ))
            }

            // Rule: Empty collections check
            if detectEmptyCountCheck(line) {
                issues.append(Issue(
                    file: filePath,
                    line: lineNum,
                    severity: .info,
                    rule: "empty_count",
                    message: "Use .isEmpty instead of .count == 0"
                ))
            }

            // Rule: Unused imports
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("import ") {
                let importName = line.components(separatedBy: " ")[1]
                if !isImportUsed(importName, in: content) {
                    issues.append(Issue(
                        file: filePath,
                        line: lineNum,
                        severity: .warning,
                        rule: "unused_import",
                        message: "Unused import: \(importName)"
                    ))
                }
            }
        }

        // Check function complexity
        issues.append(contentsOf: detectComplexFunctions(filePath, lines: lines))

        // Check weak self issues
        issues.append(contentsOf: detectWeakSelfIssues(filePath, lines: lines))

        return issues
    }

    private static func detectForceUnwrap(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Ignore comments
        guard !trimmed.hasPrefix("//") else { return false }

        // Strip string literals and inline comments
        let codeOnly = stripStringsAndComments(trimmed)

        // Skip IUO property/parameter declarations (e.g., "var foo: Type!", "param: Type!")
        // These are implicitly unwrapped optionals, not force unwraps
        let withoutIUO = codeOnly.replacingOccurrences(
            of: ":\\s*[A-Z][\\w.<>,\\[\\]? ]*!",
            with: ": _IUO_",
            options: .regularExpression
        )

        // Skip lines that only contain != operators or boolean negation
        if withoutIUO.contains("!=") || withoutIUO.contains("! ") {
            return false
        }

        // Look for force unwrap patterns: identifier!, }!, ]!, )!
        let patterns = [
            "\\w!",          // identifier!
            "\\}!",          // }!
            "\\]!",          // ]!
            "\\)!",          // )!
        ]

        for pattern in patterns {
            if withoutIUO.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }

        return false
    }

    private static func detectForceCast(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//") else { return false }

        let codeOnly = stripStringsAndComments(trimmed)
        return codeOnly.contains(" as! ")
    }

    private static func detectEmptyCountCheck(_ line: String) -> Bool {
        let codeOnly = stripStringsAndComments(line)
        return codeOnly.contains(".count == 0") || codeOnly.contains(".count==0")
    }

    private static func isImportUsed(_ importName: String, in content: String) -> Bool {
        // Simple heuristic: check if the import name appears in the code
        // This is a simplified check - a full implementation would parse AST
        let contentWithoutImports = content.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("import") }
            .joined(separator: "\n")

        return contentWithoutImports.contains(importName)
    }

    private static func stripStringsAndComments(_ line: String) -> String {
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

    private static func detectComplexFunctions(_ filePath: String, lines: [String]) -> [Issue] {
        var issues: [Issue] = []
        var currentFunction: (startLine: Int, name: String)?
        var functionBraceDepth = 0

        for (index, line) in lines.enumerated() {
            let lineNum = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Detect function start
            if trimmed.contains("func ") && trimmed.contains("{") {
                if let funcName = extractFunctionName(trimmed) {
                    currentFunction = (lineNum, funcName)
                    functionBraceDepth = 0
                }
            }

            if let funcStart = currentFunction {
                // Count braces within function
                for char in line {
                    if char == "{" {
                        functionBraceDepth += 1
                    } else if char == "}" {
                        functionBraceDepth -= 1

                        if functionBraceDepth == 0 {
                            let functionLength = lineNum - funcStart.startLine

                            // Flag if function > 60 lines (warning) or > 100 (error)
                            if functionLength > 100 {
                                issues.append(Issue(
                                    file: filePath,
                                    line: funcStart.startLine,
                                    severity: .error,
                                    rule: "function_body_length",
                                    message: "Function '\(funcStart.name)' is \(functionLength) lines (max: 100)"
                                ))
                            } else if functionLength > 60 {
                                issues.append(Issue(
                                    file: filePath,
                                    line: funcStart.startLine,
                                    severity: .warning,
                                    rule: "function_body_length",
                                    message: "Function '\(funcStart.name)' is \(functionLength) lines (warning: 60)"
                                ))
                            }

                            currentFunction = nil
                        }
                    }
                }
            }
        }

        return issues
    }

    private static func extractFunctionName(_ line: String) -> String? {
        guard let funcRange = line.range(of: "func ") else { return nil }
        let afterFunc = line[funcRange.upperBound...]

        if let parenRange = afterFunc.range(of: "(") {
            return String(afterFunc[..<parenRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        return nil
    }

    private static func detectWeakSelfIssues(_ filePath: String, lines: [String]) -> [Issue] {
        var issues: [Issue] = []

        for (index, line) in lines.enumerated() {
            let lineNum = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Check for .sink without weak self capture when self is used
            if trimmed.contains(".sink") && !trimmed.contains("[weak self]") &&
               !trimmed.contains("[unowned self]") && trimmed.contains("self") {
                issues.append(Issue(
                    file: filePath,
                    line: lineNum,
                    severity: .warning,
                    rule: "weak_delegate",
                    message: "Potential retain cycle: .sink closure without weak self capture"
                ))
            }
        }

        return issues
    }
}

// MARK: - Scanner Runner

extension CodeQualityScanner {
    static func printReport(_ issues: [Issue]) {
        let grouped = Dictionary(grouping: issues, by: { $0.file })
        var totalIssues = 0

        print("\n━━━ Code Quality Report ━━━\n")

        for (file, fileIssues) in grouped.sorted(by: { $0.key < $1.key }) {
            print("📄 \(file)")

            for issue in fileIssues.sorted(by: { $0.line < $1.line }) {
                let icon = issue.severity == .error ? "❌" : issue.severity == .warning ? "⚠️ " : "ℹ️ "
                print("  \(icon) Line \(issue.line) [\(issue.rule)]: \(issue.message)")
                totalIssues += 1
            }

            print()
        }

        let errorCount = issues.filter { $0.severity == .error }.count
        let warningCount = issues.filter { $0.severity == .warning }.count
        let infoCount = issues.filter { $0.severity == .info }.count

        print("━━━ Summary ━━━")
        print("Total issues: \(totalIssues)")
        print("  ❌ Errors: \(errorCount)")
        print("  ⚠️  Warnings: \(warningCount)")
        print("  ℹ️  Info: \(infoCount)")
        print()

        if errorCount > 0 {
            print("❌ Quality gate failed: \(errorCount) error(s) found")
            exit(1)
        } else if warningCount > 0 {
            print("⚠️  Review \(warningCount) warning(s)")
        } else {
            print("✅ Code quality check passed!")
        }
    }
}
