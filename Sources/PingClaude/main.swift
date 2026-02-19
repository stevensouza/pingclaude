import Cocoa
import Foundation

// MARK: - Crash Logging

private let crashLogPath: String = {
    let home = NSHomeDirectory()
    return "\(home)/Library/Logs/PingClaude/crash.log"
}()

/// Write crash info using POSIX file I/O (async-signal-safe)
private func writeCrashEntry(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let entry = "[\(timestamp)] \(message)\n"
    let logDir = (crashLogPath as NSString).deletingLastPathComponent
    mkdir(logDir, 0o755)
    guard let cString = entry.cString(using: .utf8) else { return }
    let fd = open(crashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    _ = write(fd, cString, strlen(cString))
    close(fd)
}

/// Signal handler — must only use async-signal-safe functions
private func crashSignalHandler(_ signal: Int32) {
    // Use raw write() since we're in a signal handler
    let sigName: String
    switch signal {
    case SIGSEGV: sigName = "SIGSEGV"
    case SIGABRT: sigName = "SIGABRT"
    case SIGBUS:  sigName = "SIGBUS"
    case SIGFPE:  sigName = "SIGFPE"
    case SIGILL:  sigName = "SIGILL"
    default:      sigName = "SIGNAL(\(signal))"
    }

    let timestamp = ISO8601DateFormatter().string(from: Date())
    let entry = "[\(timestamp)] CRASH: \(sigName) received\n"
    let logDir = (crashLogPath as NSString).deletingLastPathComponent
    mkdir(logDir, 0o755)
    if let cString = entry.cString(using: .utf8) {
        let fd = open(crashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            _ = write(fd, cString, strlen(cString))
            close(fd)
        }
    }

    // Re-raise with default handler to get normal crash behavior
    Darwin.signal(signal, SIG_DFL)
    Darwin.raise(signal)
}

// Install ObjC exception handler
NSSetUncaughtExceptionHandler { exception in
    let reason = exception.reason ?? "Unknown reason"
    let name = exception.name.rawValue
    writeCrashEntry("CRASH: Uncaught ObjC exception: \(name) - \(reason)")
}

// Install POSIX signal handlers
for sig: Int32 in [SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL] {
    Darwin.signal(sig, crashSignalHandler)
}

// MARK: - App Launch

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
