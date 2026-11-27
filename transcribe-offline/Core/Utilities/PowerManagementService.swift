//
//  PowerManagementService.swift
//  transcribe-offline
//
//  Manages system power assertions to prevent sleep during recording
//  Uses NSProcessInfo API for App Sandbox compatibility
//

import Foundation

/// Service to prevent system sleep during critical operations like recording
class PowerManagementService {

    // MARK: - Properties

    private var activity: NSObjectProtocol?
    private let logger = Logger.shared

    // MARK: - Singleton

    static let shared = PowerManagementService()

    private init() {}

    // MARK: - Public Methods

    /// Prevents both system sleep and display sleep during recording
    /// - Returns: True if assertion was successfully created
    @discardableResult
    func preventSleepDuringRecording() -> Bool {
        guard activity == nil else {
            logger.info("Sleep prevention already active", category: .system)
            return true
        }

        activity = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated,                  // User-initiated activity (higher priority)
                .idleSystemSleepDisabled,        // Prevent system sleep
                .idleDisplaySleepDisabled        // Prevent display sleep
            ],
            reason: "LocalScribe: Recording audio session"
        )

        logger.info("Sleep prevention activated", category: .system)
        return true
    }

    /// Allows system and display to sleep normally
    func allowSleepAfterRecording() {
        guard let activity = activity else {
            logger.info("No active sleep prevention to release", category: .system)
            return
        }

        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        logger.info("Sleep prevention deactivated", category: .system)
    }

    /// Check if power assertions are currently active
    var hasActiveAssertion: Bool {
        return activity != nil
    }

    // MARK: - Cleanup

    deinit {
        // Ensure we release any active assertions on cleanup
        if let activity = activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}
