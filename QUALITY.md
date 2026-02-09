# Code Quality Scanning

This document describes the code quality scanning system for PingClaude.

## Overview

PingClaude uses automated code quality scanning to detect:
- **Vulnerabilities** (unsafe patterns, force unwraps)
- **Code smells** (long functions, high complexity)
- **Bugs** (force casts, unused code patterns)

Since SwiftLint requires macOS 13+ (we're on Monterey), we use a custom Swift-based scanner built into the project.

## Quick Start

```bash
# Run code quality scan
make lint

# See baseline of known issues
cat .swiftlint-baseline.txt
```

## Rules

### Errors (must fix for CI/CD)
- **force_unwrapping** — Direct force unwraps like `value!` (except property IUOs)
- **force_cast** — Unsafe casts like `as!`
- **weak_delegate** — Missing weak self in Combine closures

### Warnings (should fix)
- **force_cast** — Unsafe type casting patterns

### Info (nice to have)
- **empty_count** — Use `.isEmpty` instead of `.count == 0`

## Implementation

### Scanner Architecture

**`CodeQualityScanner.swift`** — Main scanning logic
- `scanProject()` — Entry point, scans all Swift files
- Pattern detection for each rule
- Severity classification (error/warning/info)
- Report generation with line numbers

**`Scripts/quality-scan.swift`** — CLI runner
- Standalone script for CI/CD integration
- Can be run without full build
- Outputs Xcode-style format for IDE integration

### Adding New Rules

To add a new rule, add a detection function in `CodeQualityScanner.swift`:

```swift
// In scanFile()
if detectMyRule(line) {
    issues.append(Issue(
        file: filePath,
        line: lineNum,
        severity: .warning,
        rule: "my_rule",
        message: "Description of issue"
    ))
}

// New detection function
private static func detectMyRule(_ line: String) -> Bool {
    let codeOnly = stripStringsAndComments(line)
    // Your detection logic
    return false
}
```

## Known Issues

### Implicitly Unwrapped Optionals (IUOs)

Many flagged issues are **intentional IUOs** in property declarations:

```swift
private var statusMenuItem: NSMenuItem!  // IUO - initialized in constructor
```

These are legitimate in Cocoa/AppKit code because:
1. Properties are initialized in `init()` before use
2. Alternatives (optional + force unwrap on use) are more verbose
3. Industry standard for Cocoa frameworks

**Current approach:** Baseline file tracks these. Fix only if logic changes.

### Baseline Strategy

Instead of auto-fixing all pre-existing issues, we:
1. Captured baseline in `.swiftlint-baseline.txt`
2. Use baseline as reference
3. Prevent NEW issues from being added
4. Fix critical issues incrementally

To check current status vs baseline:
```bash
make lint > current.txt
diff .swiftlint-baseline.txt current.txt
```

## Makefile Targets

```bash
make lint              # Run full code quality scan (exit 1 if errors)
make lint-fix          # Note: Would require SwiftLint for auto-fixes
```

## Integration with Workflows

### Pre-commit Hook (Optional)

Create `.git/hooks/pre-commit`:
```bash
#!/bin/sh
make lint || exit 1
```

Make executable: `chmod +x .git/hooks/pre-commit`

### CI/CD Integration

Add to GitHub Actions or similar:
```yaml
- name: Code Quality Scan
  run: make lint
```

## Understanding Reports

Example report output:
```
━━━ Code Quality Report ━━━

📄 Sources/PingClaude/PingService.swift
  ❌ Line 83 [force_unwrapping]: Force unwrap detected - use safe unwrapping instead
  ⚠️  Line 143 [force_cast]: Force cast detected - use safe casting instead
  ℹ️  Line 148 [empty_count]: Use .isEmpty instead of .count == 0

━━━ Summary ━━━
Total issues: 3
  ❌ Errors: 1
  ⚠️  Warnings: 1
  ℹ️  Info: 1

❌ Quality gate failed: 1 error(s) found
```

### Reading the Report

- **File path** — Location of issue
- **Line number** — Where issue starts
- **Rule ID** — Machine-readable rule name
- **Message** — Human-readable description
- **Severity** — Error/Warning/Info (errors fail CI)

## Fixing Issues

### Force Unwraps

❌ **Before:**
```swift
statusItem.button!.action = #selector(toggleWindow)
```

✅ **After (guard let):**
```swift
guard let button = statusItem.button else { return }
button.action = #selector(toggleWindow)
```

✅ **After (fatalError with message):**
```swift
guard let button = statusItem.button else {
    fatalError("Failed to create status item button")
}
button.action = #selector(toggleWindow)
```

### Force Casts

❌ **Before:**
```swift
let dict = data as! [String: Any]
```

✅ **After:**
```swift
guard let dict = data as? [String: Any] else {
    print("Invalid data format")
    return
}
```

### Empty Count

❌ **Before:**
```swift
if array.count == 0 {
    return
}
```

✅ **After:**
```swift
if array.isEmpty {
    return
}
```

## Future Enhancements

### When Upgrading to macOS 13+

If you upgrade to Ventura or later, you can install SwiftLint:

```bash
brew install swiftlint
```

Then use real SwiftLint:
```bash
# Check rules
swiftlint rules

# Run with config
swiftlint lint --config .swiftlint.yml

# Auto-fix issues
swiftlint --fix
```

Update Makefile:
```makefile
lint:
	@swiftlint lint --strict --config .swiftlint.yml

lint-fix:
	@swiftlint --fix --config .swiftlint.yml
```

### Additional Scanners

Once available:
- **Periphery** — Find dead code (requires Xcode project)
- **SwiftFormat** — Auto-format code style
- **SonarQube** — Enterprise-grade analysis (for teams)

## References

- [SwiftLint on GitHub](https://github.com/realm/SwiftLint) — Full rule documentation
- [Swift Safety Documentation](https://developer.apple.com/swift/blog/) — Memory safety patterns
- [Combine Best Practices](https://www.avanderlee.com/combine/) — Weak self patterns
