import AppKit
import SwiftUI

/// Manages the menu bar status item with different states
class StatusBarManager {
    private var statusItem: NSStatusItem?
    private let logger = Logger.shared
    private var currentState: StatusBarState = .idle

    enum StatusBarState {
        case idle           // Blue with play icon
        case recording      // Red with stop icon
        case processing     // Gray with processing indicator
    }

    // MARK: - Public Interface

    /// Shows or updates the status bar button
    func show() {
        if statusItem == nil {
            logger.info("Creating status bar item", category: .audio)
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }

        guard let statusItem = statusItem else {
            logger.error("Failed to create status bar item", category: .audio)
            return
        }

        // Configure button if not already done
        if let button = statusItem.button {
            button.action = #selector(buttonClicked)
            button.target = self
            button.sendAction(on: [.leftMouseDown])
        }
    }

    /// Updates the button state
    func updateState(_ state: StatusBarState) {
        currentState = state

        guard let button = statusItem?.button else { return }

        switch state {
        case .idle:
            button.image = createIdleButtonImage()
            button.toolTip = "Start Recording"
        case .recording:
            button.image = createRecordingButtonImage()
            button.toolTip = "Stop Recording"
        case .processing:
            button.image = createProcessingButtonImage()
            button.toolTip = "Processing..."
        }
    }

    /// Removes the status bar item
    func hide() {
        guard let statusItem = statusItem else { return }

        logger.info("Removing status bar item", category: .audio)
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    // MARK: - Private Methods

    @objc private func buttonClicked() {
        logger.info("Status bar button clicked in state: \(currentState)", category: .audio)

        switch currentState {
        case .idle:
            // Post notification to start recording
            NotificationCenter.default.post(name: NSNotification.Name("StartRecordingFromStatusBar"), object: nil)
        case .recording:
            // Post notification to stop recording
            NotificationCenter.default.post(name: NSNotification.Name("StopRecordingFromStatusBar"), object: nil)
        case .processing:
            // No action during processing
            break
        }
    }

    /// Creates a blue circular button with white play icon
    private func createIdleButtonImage() -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)

        image.lockFocus()

        // Draw blue circle background
        let circlePath = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 20, height: 20))
        NSColor.systemBlue.setFill()
        circlePath.fill()

        // Draw white play triangle
        let playPath = NSBezierPath()
        playPath.move(to: NSPoint(x: 9, y: 6))
        playPath.line(to: NSPoint(x: 15, y: 11))
        playPath.line(to: NSPoint(x: 9, y: 16))
        playPath.close()
        NSColor.white.setFill()
        playPath.fill()

        image.unlockFocus()
        image.isTemplate = false

        return image
    }

    /// Creates a red circular button with white stop icon
    private func createRecordingButtonImage() -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)

        image.lockFocus()

        // Draw red circle background
        let circlePath = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 20, height: 20))
        NSColor.systemRed.setFill()
        circlePath.fill()

        // Draw white stop square (rounded rect for nicer look)
        let stopRect = NSRect(x: 7, y: 7, width: 8, height: 8)
        let stopPath = NSBezierPath(roundedRect: stopRect, xRadius: 1, yRadius: 1)
        NSColor.white.setFill()
        stopPath.fill()

        image.unlockFocus()
        image.isTemplate = false

        return image
    }

    /// Creates a gray circular button with processing indicator
    private func createProcessingButtonImage() -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)

        image.lockFocus()

        // Draw gray circle background
        let circlePath = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 20, height: 20))
        NSColor.systemGray.setFill()
        circlePath.fill()

        // Draw white circular progress indicator (simplified)
        let innerCircle = NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: 8, height: 8))
        NSColor.white.setStroke()
        innerCircle.lineWidth = 2
        innerCircle.stroke()

        image.unlockFocus()
        image.isTemplate = false

        return image
    }
}
