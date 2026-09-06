import SwiftUI
import AppKit
import CoreAudio
@main
struct CenteredVolumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var audioMonitor: AudioMonitor?
    private var volumeHUDWindow: VolumeHUDWindow?
    private let autostartManager = AutostartManager()
    private let permissionManager = AccessibilityPermissionManager()
    private let hardwareVolumeSteps = 16
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var lastVolumeScrubTime: Date?
    private var rawVolumeLevel: Float?
    private var isProcessingKeyPress = false

    private enum DefaultsKeys {
        static let hasShownOnboarding = "com.centeredvolume.onboarding.shown"
        static let hasCompletedOnboarding = "com.centeredvolume.onboarding.completed"
        static let autostartEnabled = "com.centeredvolume.autostart.enabled"
        static let holdWhileHover = "com.centeredvolume.hud.holdWhileHover"
    }

    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent multiple instances
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }

        // Check macOS version - require 26.0 (Tahoe) or later
        if !isCompatibleMacOSVersion() {
            showIncompatibilityAlert()
            NSApp.terminate(nil)
            return
        }

        // Initialize HUD window
        volumeHUDWindow = VolumeHUDWindow()

        // Set default for hold while hover if not set
        if defaults.object(forKey: DefaultsKeys.holdWhileHover) == nil {
            defaults.set(true, forKey: DefaultsKeys.holdWhileHover)
        }
        volumeHUDWindow?.updateHoldWhileHoverEnabled(defaults.bool(forKey: DefaultsKeys.holdWhileHover))

        // Start monitoring audio
        audioMonitor = AudioMonitor { [weak self] volume, deviceName, isMuted in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if self.isProcessingKeyPress {
                    return
                }

                if let rawLevel = self.rawVolumeLevel {
                    // Any notification that reaches us is a change we did not
                    // make ourselves, so the level we were holding on to for the
                    // next key press is stale either way.
                    self.rawVolumeLevel = nil

                    // Within tolerance it is our own write echoed back late; the
                    // HUD for it is already on screen.
                    let tolerance: Float = 0.005
                    if abs(volume - rawLevel) < tolerance {
                        return
                    }
                }

                let devices = self.audioMonitor?.listOutputDevices() ?? []
                self.volumeHUDWindow?.show(
                    volume: volume,
                    deviceName: deviceName,
                    isMuted: isMuted,
                    devices: devices
                )
            }
        }

        volumeHUDWindow?.onMinVolumeTap = { [weak self] in
            self?.audioMonitor?.setVolume(to: 0)
        }

        volumeHUDWindow?.onMaxVolumeTap = { [weak self] in
            self?.audioMonitor?.setVolume(to: 1)
        }

        volumeHUDWindow?.onDeviceSelected = { [weak self] deviceID in
            self?.audioMonitor?.setDefaultOutputDevice(to: AudioDeviceID(deviceID))
        }

        volumeHUDWindow?.getDeviceInfo = { [weak self] deviceID in
            guard let monitor = self?.audioMonitor else { return nil }
            let volume = monitor.getVolume(for: AudioDeviceID(deviceID))
            let isMuted = monitor.isMuted(for: AudioDeviceID(deviceID))
            return (volume: volume, isMuted: isMuted)
        }

        volumeHUDWindow?.onSettingsTap = { [weak self] in
            self?.showSettingsWindow()
        }

        volumeHUDWindow?.updateHoldWhileHoverEnabled(defaults.bool(forKey: DefaultsKeys.holdWhileHover))

        volumeHUDWindow?.onVolumeScrub = { [weak self] level, isFinal in
            guard let self = self else { return }

            let clamped = max(0, min(1, level))

            if isFinal {
                self.lastVolumeScrubTime = nil
                self.rawVolumeLevel = clamped
                self.audioMonitor?.setVolume(to: clamped, notify: true)
            } else {
                let now = Date()
                let shouldUpdate: Bool

                if let lastTime = self.lastVolumeScrubTime {
                    shouldUpdate = now.timeIntervalSince(lastTime) >= 0.15
                } else {
                    shouldUpdate = true
                }

                if shouldUpdate {
                    self.lastVolumeScrubTime = now
                    self.audioMonitor?.setVolume(to: clamped, notify: false)
                }
            }
        }

        audioMonitor?.onVolumeKey = { [weak self] keyType in
            guard let self = self else { return }
            guard let monitor = self.audioMonitor else { return }

            let deviceID = monitor.defaultOutputDeviceID
            guard deviceID != 0 else { return }

            self.isProcessingKeyPress = true

            let currentVolume = self.rawVolumeLevel ?? monitor.getVolume(for: deviceID)
            let stepCount = Float(self.hardwareVolumeSteps)
            let stepSize = 1.0 / stepCount

            switch keyType {
            case .up:
                let currentStep = currentVolume / stepSize
                let roundedStep = round(currentStep)

                let targetStep: Float
                if abs(currentStep - roundedStep) < 0.01 {
                    targetStep = roundedStep + 1
                } else {
                    targetStep = ceil(currentStep)
                }

                let newVolume = min(1.0, targetStep * stepSize)
                self.rawVolumeLevel = newVolume
                monitor.setVolume(to: newVolume, notify: false)

                let devices = monitor.listOutputDevices()
                let deviceName = monitor.getDeviceName(for: deviceID)
                // The write above unmutes on its own queue, so reading the
                // device here would still report the mute we are undoing.
                let isMuted = newVolume > 0 ? false : monitor.isMuted(for: deviceID)
                self.volumeHUDWindow?.show(
                    volume: newVolume,
                    deviceName: deviceName,
                    isMuted: isMuted,
                    devices: devices,
                    resetScrubbing: true
                )

            case .down:
                let currentStep = currentVolume / stepSize
                let roundedStep = round(currentStep)

                let targetStep: Float
                if abs(currentStep - roundedStep) < 0.01 {
                    targetStep = roundedStep - 1
                } else {
                    targetStep = floor(currentStep)
                }

                let newVolume = max(0.0, targetStep * stepSize)
                self.rawVolumeLevel = newVolume
                monitor.setVolume(to: newVolume, notify: false)

                let devices = monitor.listOutputDevices()
                let deviceName = monitor.getDeviceName(for: deviceID)
                // The write above unmutes on its own queue, so reading the
                // device here would still report the mute we are undoing.
                let isMuted = newVolume > 0 ? false : monitor.isMuted(for: deviceID)
                self.volumeHUDWindow?.show(
                    volume: newVolume,
                    deviceName: deviceName,
                    isMuted: isMuted,
                    devices: devices,
                    resetScrubbing: true
                )

            case .mute:
                // Toggle the device's mute the way the system key does, rather
                // than driving the volume to zero: the level has to survive so
                // that unmuting brings it back.
                let isMuted = monitor.toggleMute(for: deviceID)

                let devices = monitor.listOutputDevices()
                let deviceName = monitor.getDeviceName(for: deviceID)
                self.volumeHUDWindow?.show(
                    volume: monitor.getVolume(for: deviceID),
                    deviceName: deviceName,
                    isMuted: isMuted,
                    devices: devices,
                    resetScrubbing: true
                )
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.isProcessingKeyPress = false
            }
        }

        audioMonitor?.startMonitoring()

        let initialAutostart: Bool
        if defaults.object(forKey: DefaultsKeys.autostartEnabled) != nil {
            initialAutostart = defaults.bool(forKey: DefaultsKeys.autostartEnabled)
        } else {
            initialAutostart = autostartManager.isAutostartEnabled()
            defaults.set(initialAutostart, forKey: DefaultsKeys.autostartEnabled)
        }

        applyAutostartPreference(initialAutostart)

        presentOnboardingIfNeeded()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Accessibility is granted in System Settings, with this app in the
        // background, so coming back to the front is our first chance to create
        // the tap that could not exist at launch.
        if permissionManager.hasPermission() {
            audioMonitor?.startKeyEventMonitoring()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioMonitor?.stopMonitoring()
    }

    private func isCompatibleMacOSVersion() -> Bool {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        // Tahoe reports itself as 26.0. There was never a macOS 16.
        return osVersion.majorVersion >= 26
    }

    private func isAnotherInstanceRunning() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""

        let instances = runningApps.filter { $0.bundleIdentifier == bundleIdentifier }
        return instances.count > 1
    }

    private func showIncompatibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Incompatible macOS Version"
        alert.informativeText = "You don't need this app on your system version. Centered Volume requires macOS 26 (Tahoe) or later, as the native volume HUD redesign only applies to this version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showSettingsWindow() {
        settingsWindowController?.close()

        let controller = SettingsWindowController(
            viewModel: makeSettingsViewModel()
        )
        settingsWindowController = controller
        controller.showWindow()
    }

    private func presentOnboardingIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: DefaultsKeys.hasShownOnboarding) else { return }

        defaults.set(true, forKey: DefaultsKeys.hasShownOnboarding)

        onboardingWindowController = OnboardingWindowController(
            onFinished: { [weak self] _ in
                UserDefaults.standard.set(true, forKey: DefaultsKeys.hasCompletedOnboarding)
                // Not gated on the flag the onboarding reports: it is sampled at
                // a fixed deadline and misses a slower grant. The call checks
                // AXIsProcessTrusted() itself.
                self?.audioMonitor?.startKeyEventMonitoring()
                self?.onboardingWindowController = nil
                self?.showHUDDemo()
            },
            onClosedWithoutPermission: { [weak self] in
                self?.onboardingWindowController = nil
                self?.showHUDDemo()
            },
            onAutostartPreference: { [weak self] enabled in
                self?.applyAutostartPreference(enabled)
            }
        )

        onboardingWindowController?.showWindow()
    }

    private func applyAutostartPreference(_ enabled: Bool) {
        defaults.set(enabled, forKey: DefaultsKeys.autostartEnabled)
        autostartManager.setAutostartEnabled(enabled)
    }

    private func applyHoldWhileHoverPreference(_ enabled: Bool) {
        defaults.set(enabled, forKey: DefaultsKeys.holdWhileHover)
        volumeHUDWindow?.updateHoldWhileHoverEnabled(enabled)
    }

    private func showHUDDemo() {
        guard let monitor = audioMonitor else { return }

        let deviceID = monitor.defaultOutputDeviceID
        guard deviceID != 0 else { return }

        let volume = monitor.getVolume(for: deviceID)
        let deviceName = monitor.getDeviceName(for: deviceID)
        let isMuted = monitor.isMuted(for: deviceID)
        let devices = monitor.listOutputDevices()

        volumeHUDWindow?.show(
            volume: volume,
            deviceName: deviceName,
            isMuted: isMuted,
            devices: devices
        )
    }

    private func makeSettingsViewModel() -> SettingsViewModel {
        let hasPermission = permissionManager.hasPermission()
        let autostartEnabled = defaults.bool(forKey: DefaultsKeys.autostartEnabled)
        let holdEnabled = defaults.bool(forKey: DefaultsKeys.holdWhileHover)

        return SettingsViewModel(
            hasAccessibilityPermission: hasPermission,
            autostartEnabled: autostartEnabled,
            holdWhileHoverEnabled: holdEnabled,
            requestPermissionAction: { [weak self] completion in
                guard let self else { return }
                // requestPermission already polls until granted or timed out;
                // its completion is the real answer, not a second fixed wait
                // stacked on top of it.
                self.permissionManager.requestPermission { granted in
                    if granted {
                        self.audioMonitor?.startKeyEventMonitoring()
                    }
                    completion(granted)
                }
            },
            autostartToggleAction: { [weak self] newValue in
                self?.applyAutostartPreference(newValue)
            },
            resetPositionAction: { [weak self] in
                self?.volumeHUDWindow?.resetToDefaultPosition()
            },
            holdWhileHoverAction: { [weak self] newValue in
                self?.applyHoldWhileHoverPreference(newValue)
            }
        )
    }
}
