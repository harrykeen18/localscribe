import SwiftUI
import Combine

@main
struct transcribe_offlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var statusBarController = StatusBarController()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(statusBarController)
                .onAppear {
                    appDelegate.mainWindow = NSApplication.shared.windows.first
                }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appDelegate.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var mainWindow: NSWindow?

    func openSettings() {
        // Post notification to open settings
        NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
    }
}

// Separate ObservableObject to manage status bar
@MainActor
class StatusBarController: ObservableObject {
    private let statusBarManager = StatusBarManager()

    init() {
        // Show the status bar on app launch
        statusBarManager.show()
        statusBarManager.updateState(.idle)
    }

    func updateState(_ state: StatusBarManager.StatusBarState) {
        statusBarManager.updateState(state)
    }

    func hide() {
        statusBarManager.hide()
    }
}
