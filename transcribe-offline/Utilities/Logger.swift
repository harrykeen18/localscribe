import Foundation
import os.log
import Combine
import AppKit
import UniformTypeIdentifiers

enum LogLevel: String, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    case critical = "CRITICAL"

    var emoji: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        case .critical: return "🔥"
        }
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        case .critical: return .fault
        }
    }
}

enum LogCategory: String, CaseIterable {
    case audio = "Audio"
    case transcription = "Transcription"
    case ui = "UI"
    case file = "File"
    case network = "Network"
    case system = "System"

    var emoji: String {
        switch self {
        case .audio: return "🎤"
        case .transcription: return "📝"
        case .ui: return "🖥️"
        case .file: return "📁"
        case .network: return "🌐"
        case .system: return "⚙️"
        }
    }
}

@MainActor
class Logger: ObservableObject {
    static let shared = Logger()

    private let subsystem = "com.transcribe.offline"
    private let maxLogEntries = 1000

    @Published private(set) var logEntries: [LogEntry] = []

    let objectWillChange = PassthroughSubject<Void, Never>()

    private let osLog = OSLog(subsystem: "com.transcribe.offline", category: "General")
    private let fileManager = FileManager.default
    private lazy var logDirectory: URL = {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupportURL = urls.first!.appendingPathComponent("TranscribeOffline")
        try? fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        return appSupportURL.appendingPathComponent("Logs")
    }()

    private init() {
        setupLogDirectory()
        log(.info, category: .system, "Logger initialized")

        // Clean up old logs on startup
        Task {
            await MainActor.run {
                cleanupOldLogs()
            }
        }
    }

    func log(_ level: LogLevel, category: LogCategory, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let timestamp = Date()
        let fileName = URL(fileURLWithPath: file).lastPathComponent

        let entry = LogEntry(
            timestamp: timestamp,
            level: level,
            category: category,
            message: message,
            file: fileName,
            function: function,
            line: line
        )

        // Add to in-memory log
        objectWillChange.send()
        logEntries.append(entry)

        // Keep only recent entries
        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }

        // Log to system log
        let formattedMessage = formatLogEntry(entry)
        os_log("%{public}@", log: osLog, type: level.osLogType, formattedMessage)

        // Log to file
        writeToFile(entry)

        // Print to Xcode console for debugging
        print(formatConsoleLogEntry(entry))
    }

    // MARK: - Convenience methods

    func debug(_ message: String, category: LogCategory = .system, file: String = #file, function: String = #function, line: Int = #line) {
        log(.debug, category: category, message, file: file, function: function, line: line)
    }

    func info(_ message: String, category: LogCategory = .system, file: String = #file, function: String = #function, line: Int = #line) {
        log(.info, category: category, message, file: file, function: function, line: line)
    }

    func warning(_ message: String, category: LogCategory = .system, file: String = #file, function: String = #function, line: Int = #line) {
        log(.warning, category: category, message, file: file, function: function, line: line)
    }

    func error(_ message: String, category: LogCategory = .system, file: String = #file, function: String = #function, line: Int = #line) {
        log(.error, category: category, message, file: file, function: function, line: line)
    }

    func critical(_ message: String, category: LogCategory = .system, file: String = #file, function: String = #function, line: Int = #line) {
        log(.critical, category: category, message, file: file, function: function, line: line)
    }

    // MARK: - Log management

    func clearLogs() {
        objectWillChange.send()
        logEntries.removeAll()
        info("Logs cleared", category: .system)
    }

    func exportLogsToClipboard() {
        let logsText = logEntries.map { formatLogEntry($0) }.joined(separator: "\n")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logsText, forType: NSPasteboard.PasteboardType.string)

        info("Logs exported to clipboard (\(logEntries.count) entries)", category: .system)
    }

    func getLogsForCategory(_ category: LogCategory) -> [LogEntry] {
        return logEntries.filter { $0.category == category }
    }

    func getLogsForLevel(_ level: LogLevel) -> [LogEntry] {
        return logEntries.filter { $0.level == level }
    }

    // MARK: - Diagnostics Export

    /// Export comprehensive diagnostics including system info and all log files
    func exportDiagnostics() {
        let diagnostics = generateDiagnosticsReport()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnostics, forType: .string)

        info("Diagnostics exported to clipboard", category: .system)
    }

    /// Save diagnostics to a file with save dialog
    func exportDiagnosticsToFile() {
        let diagnostics = generateDiagnosticsReport()

        // Create save panel
        let savePanel = NSSavePanel()
        savePanel.title = "Save Diagnostics"
        savePanel.message = "Choose where to save the diagnostics report"
        savePanel.nameFieldStringValue = "transcribe-diagnostics-\(getCurrentDateString()).txt"
        savePanel.allowedContentTypes = [.plainText]

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            do {
                try diagnostics.write(to: url, atomically: true, encoding: .utf8)
                Task { @MainActor in
                    self.info("Diagnostics saved to \(url.path)", category: .system)
                }
            } catch {
                Task { @MainActor in
                    self.error("Failed to save diagnostics: \(error.localizedDescription)", category: .system)
                }
            }
        }
    }

    /// Clean up log files older than 7 days
    func cleanupOldLogs() {
        let calendar = Calendar.current
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()

        do {
            let logFiles = try fileManager.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: [.creationDateKey])

            for fileURL in logFiles where fileURL.pathExtension == "log" {
                if let creationDate = try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate,
                   creationDate < sevenDaysAgo {
                    try fileManager.removeItem(at: fileURL)
                    debug("Deleted old log file: \(fileURL.lastPathComponent)", category: .system)
                }
            }
        } catch {
            self.error("Failed to cleanup old logs: \(error.localizedDescription)", category: .system)
        }
    }

    // MARK: - Private Diagnostics Methods

    private func generateDiagnosticsReport() -> String {
        var report = ""

        // Header
        report += "=== TRANSCRIBE DIAGNOSTICS REPORT ===\n"
        report += "Generated: \(getCurrentDateTimeString())\n"
        report += "\n"

        // System Diagnostics
        report += getSystemDiagnostics()
        report += "\n"

        // Recent Errors/Warnings
        report += "=== RECENT ERRORS & WARNINGS ===\n"
        let errorsAndWarnings = logEntries.filter { $0.level == .error || $0.level == .warning || $0.level == .critical }.suffix(20)
        if errorsAndWarnings.isEmpty {
            report += "No recent errors or warnings\n"
        } else {
            for entry in errorsAndWarnings {
                report += formatLogEntry(entry) + "\n"
            }
        }
        report += "\n"

        // All Log Files Content
        report += "=== LOG FILES (LAST 7 DAYS) ===\n"
        report += getAllLogFilesContent()
        report += "\n"

        // Privacy Note
        report += "=== PRIVACY NOTE ===\n"
        report += "This report contains technical logs only. No transcript content or audio files are included.\n"

        return report
    }

    private func getSystemDiagnostics() -> String {
        var diagnostics = "=== SYSTEM INFORMATION ===\n"

        // App Version
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            diagnostics += "App Version: \(version)\n"
        } else {
            diagnostics += "App Version: 0.1.0-alpha\n"
        }

        // macOS Version
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        diagnostics += "macOS Version: \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)\n"

        // Chip Type
        var sysctlSize = 0
        sysctlbyname("hw.optional.arm64", nil, &sysctlSize, nil, 0)
        var isAppleSilicon = false
        if sysctlSize > 0 {
            var value: Int32 = 0
            sysctlbyname("hw.optional.arm64", &value, &sysctlSize, nil, 0)
            isAppleSilicon = value == 1
        }
        diagnostics += "Chip: \(isAppleSilicon ? "Apple Silicon" : "Intel")\n"

        // Memory
        let memory = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        diagnostics += "Memory: \(memory) GB\n"

        // Log Statistics
        diagnostics += "\n=== LOG STATISTICS ===\n"
        diagnostics += "Total Log Entries (in memory): \(logEntries.count)\n"
        diagnostics += "Errors: \(logEntries.filter { $0.level == .error }.count)\n"
        diagnostics += "Warnings: \(logEntries.filter { $0.level == .warning }.count)\n"
        diagnostics += "Critical: \(logEntries.filter { $0.level == .critical }.count)\n"

        // Transcription History
        let historyManager = TranscriptionHistoryManager.shared
        diagnostics += "\n=== TRANSCRIPTION STATISTICS ===\n"
        diagnostics += "Total Transcriptions: \(historyManager.transcriptions.count)\n"

        return diagnostics
    }

    private func getAllLogFilesContent() -> String {
        var content = ""
        let calendar = Calendar.current
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()

        do {
            let logFiles = try fileManager.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: [.creationDateKey])
                .filter { $0.pathExtension == "log" }
                .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) } // Most recent first

            for fileURL in logFiles {
                // Only include logs from last 7 days
                if let creationDate = try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate,
                   creationDate >= sevenDaysAgo {
                    content += "--- \(fileURL.lastPathComponent) ---\n"
                    if let fileContent = try? String(contentsOf: fileURL, encoding: .utf8) {
                        content += fileContent
                        content += "\n"
                    }
                }
            }

            if content.isEmpty {
                content = "No log files found\n"
            }
        } catch {
            content = "Error reading log files: \(error.localizedDescription)\n"
        }

        return content
    }

    private func getCurrentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func getCurrentDateTimeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.string(from: Date())
    }

    // MARK: - Private methods

    private func setupLogDirectory() {
        do {
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create log directory: \(error)")
        }
    }

    private func writeToFile(_ entry: LogEntry) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: entry.timestamp)

        let logFile = logDirectory.appendingPathComponent("app_\(dateString).log")
        let logLine = formatLogEntry(entry) + "\n"

        if let data = logLine.data(using: .utf8) {
            if fileManager.fileExists(atPath: logFile.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFile) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    private func formatLogEntry(_ entry: LogEntry) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let timestamp = dateFormatter.string(from: entry.timestamp)

        return "[\(timestamp)] [\(entry.level.rawValue)] [\(entry.category.rawValue)] \(entry.message) (\(entry.file):\(entry.line))"
    }

    private func formatConsoleLogEntry(_ entry: LogEntry) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = dateFormatter.string(from: entry.timestamp)

        return "\(entry.level.emoji)\(entry.category.emoji) [\(timestamp)] \(entry.message)"
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
    let file: String
    let function: String
    let line: Int
}

// MARK: - Global logging functions for convenience

func logDebug(_ message: String, category: LogCategory = .system, file: String = #file, function: String = #function, line: Int = #line) {
    Task { @MainActor in
        Logger.shared.debug(message, category: category, file: file, function: function, line: line)
    }
}

func logInfo(_ message: String, category: LogCategory = .system, file: String = #file, function: String = #function, line: Int = #line) {
    Task { @MainActor in
        Logger.shared.info(message, category: category, file: file, function: function, line: line)
    }
}

func logWarning(_ message: String, category: LogCategory = .system, file: String = #file, function: String = #function, line: Int = #line) {
    Task { @MainActor in
        Logger.shared.warning(message, category: category, file: file, function: function, line: line)
    }
}

func logError(_ message: String, category: LogCategory = .system, file: String = #file, function: String = #function, line: Int = #line) {
    Task { @MainActor in
        Logger.shared.error(message, category: category, file: file, function: function, line: line)
    }
}

func logCritical(_ message: String, category: LogCategory = .system, file: String = #file, function: String = #function, line: Int = #line) {
    Task { @MainActor in
        Logger.shared.critical(message, category: category, file: file, function: function, line: line)
    }
}