import Foundation
import ApplicationServices
import AppKit

final class AccessibilityPermissionManager {
    // Granting access means finding System Settings, clicking a switch and
    // confirming with a password or Touch ID — routinely more than a couple
    // of seconds. Poll instead of sampling once at a fixed delay, and give
    // the user a full minute before giving up.
    private static let pollInterval: TimeInterval = 0.5
    private static let pollTimeout: TimeInterval = 60.0

    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    func hasPermission() -> Bool {
        AXIsProcessTrusted()
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            completion(true)
            return
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        beginPolling(deadline: Date().addingTimeInterval(Self.pollTimeout), completion: completion)
    }

    private func beginPolling(deadline: Date, completion: @escaping (Bool) -> Void) {
        stopPolling()

        // Coming back from System Settings is the strongest signal that the
        // grant may have just happened, so check right away instead of
        // waiting out the rest of the poll interval.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkAndFinishIfSettled(deadline: deadline, completion: completion)
        }

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.checkAndFinishIfSettled(deadline: deadline, completion: completion)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func checkAndFinishIfSettled(deadline: Date, completion: @escaping (Bool) -> Void) {
        let granted = AXIsProcessTrusted()
        guard granted || Date() >= deadline else { return }
        stopPolling()
        completion(granted)
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    deinit {
        stopPolling()
    }
}
