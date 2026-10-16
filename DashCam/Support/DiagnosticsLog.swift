import Darwin
import Foundation
import UIKit

/// On-device diagnostics: errors and crashes are written to Documents/Logs
/// so they survive app restarts and are browsable in the Files app
/// (Files ▸ On My iPhone ▸ Dash Cam ▸ Logs).
///
/// - Daily log files: `dashcam-YYYY-MM-DD.log` (info/error lines).
/// - Crashes: a `pending-crash.log` is kept open while running; uncaught
///   exceptions and fatal signals (including Swift runtime traps, SIGTRAP)
///   write into it, and the next launch promotes it to `crash-<timestamp>.log`.
final class DiagLog {
    static let shared = DiagLog()

    let directory: URL

    private let queue = DispatchQueue(label: "com.cjcombs.dashcam.diaglog", qos: .utility)
    private let timestampFormatter: ISO8601DateFormatter
    private let dayFormatter: DateFormatter

    private static var pendingCrashFD: Int32 = -1

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    }

    // MARK: - App log

    func info(_ message: String) {
        write(level: "INFO", message)
    }

    func error(_ message: String) {
        write(level: "ERROR", message)
    }

    private func write(level: String, _ message: String) {
        let line = "\(timestampFormatter.string(from: Date())) [\(level)] \(message)\n"
        let url = directory.appendingPathComponent("dashcam-\(dayFormatter.string(from: Date())).log")
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Log files currently on disk (for the Settings readout).
    func logFileSummary() -> (count: Int, bytes: Int64, crashes: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        var bytes: Int64 = 0
        var crashes = 0
        for file in files {
            bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if file.lastPathComponent.hasPrefix("crash-") { crashes += 1 }
        }
        return (files.count, bytes, crashes)
    }

    // MARK: - Crash capture

    /// Install once at launch, before anything else can fail.
    func installCrashReporting() {
        promotePendingCrash()
        openPendingCrashFile()

        NSSetUncaughtExceptionHandler { exception in
            let report = """
            Uncaught exception: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "unknown")
            Stack:
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            DiagLog.writeToPendingCrash(report)
        }

        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig) { code in
                DiagLog.writeToPendingCrash("Fatal signal \(code)\n")
                if DiagLog.pendingCrashFD >= 0 {
                    var callstack = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
                    let frames = backtrace(&callstack, 128)
                    backtrace_symbols_fd(&callstack, frames, DiagLog.pendingCrashFD)
                }
                signal(code, SIG_DFL)
                raise(code)
            }
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        info("App launched — v\(version) (\(build)), iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)")
    }

    private var pendingCrashURL: URL {
        directory.appendingPathComponent("pending-crash.log")
    }

    /// If the last run died with a crash record, promote it to a named file.
    private func promotePendingCrash() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: pendingCrashURL.path),
              let size = try? pendingCrashURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let destination = directory.appendingPathComponent("crash-\(formatter.string(from: Date())).log")
        try? fm.moveItem(at: pendingCrashURL, to: destination)
        info("Previous session crashed — report saved as \(destination.lastPathComponent)")
    }

    private func openPendingCrashFile() {
        pendingCrashURL.path.withCString { path in
            DiagLog.pendingCrashFD = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
    }

    private static func writeToPendingCrash(_ text: String) {
        guard pendingCrashFD >= 0 else { return }
        text.withCString { cString in
            _ = Darwin.write(pendingCrashFD, cString, strlen(cString))
        }
    }
}
