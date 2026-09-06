import SwiftUI
import AppKit

// Custom window class that can become key even with borderless style
class FloatingWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }

    override var canBecomeMain: Bool {
        return true
    }
}

class VolumeHUDWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let viewModel = VolumeHUDViewModel()
    private var hostingView: NSHostingView<VolumeHUDView>?
    private var hideTimer: Timer?
    private let defaultHideDelay: TimeInterval = 1.0
    private let deviceSelectionDisplayDuration: TimeInterval = 4.0
    private var isFadingOut = false
    private var nextHideDelay: TimeInterval?
    private var isVolumeScrubActive = false
    private var isRestoringPosition = false
    private var holdWhileHoverEnabled = false
    private var isMouseHovering = false
    private var hoverExitTimer: Timer?
    private var lastForegroundApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    var onMinVolumeTap: (() -> Void)?
    var onMaxVolumeTap: (() -> Void)?
    var onDeviceSelected: ((UInt32) -> Void)?
    var onVolumeScrub: ((Float, Bool) -> Void)?
    var onSettingsTap: (() -> Void)?
    var getDeviceInfo: ((UInt32) -> (volume: Float, isMuted: Bool)?)?

    override init() {
        super.init()
        setupWindow()
        observeForegroundApp()
    }

    // The HUD never takes focus by itself, but a click in it activates the app
    // like a click in any window. Knowing who was in front just before that
    // click is what lets hide() hand the focus back to the right application.
    private func observeForegroundApp() {
        // Whoever is in front at launch never activates again while we watch,
        // and after autostart that is exactly the app the user is working in.
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != NSRunningApplication.current.processIdentifier {
            lastForegroundApp = frontmost
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != NSRunningApplication.current.processIdentifier else { return }
            self?.lastForegroundApp = app
        }
    }

    private func setupWindow() {
        // Create a borderless, floating window
        let window = FloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false  // Disable window shadow, use view shadow instead
        window.level = .statusBar + 1  // Above most windows
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovable = true
        window.isMovableByWindowBackground = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true

        // Ensure window is completely transparent
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Position window above dock at bottom center of screen
        if let screen = NSScreen.main {
            positionWindowAtDefault(on: window, screen: screen)
        }

        restorePosition(for: window)

        self.window = window
        let hudView = VolumeHUDView(
            model: viewModel,
            onMinVolumeTap: { [weak self] in
                guard let self = self else { return }
                self.registerUserInteraction()
                self.onMinVolumeTap?()
            },
            onMaxVolumeTap: { [weak self] in
                guard let self = self else { return }
                self.registerUserInteraction()
                self.onMaxVolumeTap?()
            },
            onDeviceSelected: { [weak self] selectedID in
                guard let self = self else { return }

                // Immediately update the device name in the UI before the system callback
                if let selectedDevice = self.viewModel.availableDevices.first(where: { $0.id == selectedID }) {
                    self.viewModel.deviceName = selectedDevice.name

                    // Get the volume and mute state for the newly selected device
                    if let deviceInfo = self.getDeviceInfo?(selectedID) {
                        self.viewModel.volume = deviceInfo.volume
                        self.viewModel.isMuted = deviceInfo.isMuted
                        self.viewModel.scrubbingLevel = nil
                    }

                    // Update the available devices to mark the new one as current
                    self.viewModel.availableDevices = self.viewModel.availableDevices.map { device in
                        HUDDeviceItem(
                            id: device.id,
                            name: device.name,
                            isCurrent: device.id == selectedID
                        )
                    }
                }

                self.registerUserInteraction(keepVisibleFor: self.deviceSelectionDisplayDuration)
                self.onDeviceSelected?(selectedID)
            },
            onVolumeScrub: { [weak self] level, isFinal in
                guard let self = self else { return }
                if !self.isVolumeScrubActive {
                    self.isVolumeScrubActive = true
                    self.registerUserInteraction()
                }
                self.onVolumeScrub?(level, isFinal)
                if isFinal {
                    self.isVolumeScrubActive = false
                    self.registerUserInteraction()
                }
            },
            onDeviceMenuOpened: { [weak self] in
                guard let self = self else { return }
                self.registerUserInteraction(keepVisibleFor: self.deviceSelectionDisplayDuration)
            },
            onSettingsTap: { [weak self] in
                guard let self = self else { return }
                self.registerUserInteraction(keepVisibleFor: self.deviceSelectionDisplayDuration)
                self.onSettingsTap?()
            },
            onHoverChanged: { [weak self] hovering in
                self?.handleHoverState(isHovering: hovering)
            }
        )

        let hostingView = NSHostingView(rootView: hudView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false

        window.contentView = hostingView
        self.hostingView = hostingView

        window.delegate = self
    }

    func show(
        volume: Float,
        deviceName: String,
        isMuted: Bool,
        devices: [AudioMonitor.OutputDevice],
        resetScrubbing: Bool = false
    ) {
        guard let window = window else { return }

        // Reset fade and cancel any pending hide timer
        hideTimer?.invalidate()
        isFadingOut = false
        window.contentView?.layer?.removeAllAnimations()
        isVolumeScrubActive = false

        if resetScrubbing {
            viewModel.scrubbingLevel = nil
        }

        if let screen = window.screen ?? NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowFrame = window.frame
            if !screenFrame.contains(windowFrame) {
                restorePosition(for: window)
            }
        }

        let menuItems = devices.map { device in
            HUDDeviceItem(
                id: UInt32(device.id),
                name: device.name,
                isCurrent: device.isDefault
            )
        }

        viewModel.deviceName = deviceName
        viewModel.isMuted = isMuted
        viewModel.volume = volume
        viewModel.availableDevices = menuItems

        if !isVolumeScrubActive, let scrubLevel = viewModel.scrubbingLevel {
            let stepCount: Float = 16
            let volumeStep = round(volume * stepCount)
            let scrubStep = round(scrubLevel * stepCount)
            if volumeStep == scrubStep {
                viewModel.scrubbingLevel = nil
            }
        }

        let wasVisible = window.isVisible

        if !wasVisible {
            window.alphaValue = 0
            window.orderFrontRegardless()
        } else {
            window.orderFrontRegardless()

            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            window.animator().alphaValue = 1.0
            NSAnimationContext.endGrouping()
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = wasVisible ? 0.18 : 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }, completionHandler: {
            window.alphaValue = 1.0
        })

        // Only schedule auto-hide if not in hold-while-hover mode with mouse hovering
        if holdWhileHoverEnabled && isMouseHovering {
            // Don't schedule timer - mouse is hovering
        } else {
            let delay = nextHideDelay ?? defaultHideDelay
            nextHideDelay = nil
            scheduleHideTimer(after: delay)
        }
    }

    private func registerUserInteraction(keepVisibleFor duration: TimeInterval? = nil) {
        guard let window = window else { return }

        hideTimer?.invalidate()
        isFadingOut = false

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        window.animator().alphaValue = 1.0
        NSAnimationContext.endGrouping()
        window.alphaValue = 1.0

        window.contentView?.layer?.removeAllAnimations()

        // If hold while hover is enabled and mouse is hovering, don't schedule hide timer
        if holdWhileHoverEnabled && isMouseHovering {
            return
        }

        if let duration = duration {
            nextHideDelay = duration
            scheduleHideTimer(after: duration)
        } else {
            nextHideDelay = nil
            scheduleHideTimer(after: defaultHideDelay)
        }
    }

    /// Puts the window back where the stored position asks for, without the
    /// resulting move being mistaken for the user moving it.
    private func restorePosition(for window: NSWindow) {
        isRestoringPosition = true
        HUDPositionManager.restorePosition(for: window)
        isRestoringPosition = false
    }

    private func scheduleHideTimer(after delay: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    private func hide() {
        guard let window = window, window.isVisible else { return }

        isFadingOut = true

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.5  // Longer fade out
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            if self.isFadingOut {
                // Only hand focus back if this window is what holds it. Showing
                // the HUD does not take focus, so activating anything here after
                // a plain volume key press would yank the user out of whatever
                // they switched to while the HUD was fading.
                let hudHoldsFocus = NSApp.isActive && window.isKeyWindow
                window.orderOut(nil)
                if hudHoldsFocus {
                    self.returnFocusToPreviousApp()
                }
            }
            self.isFadingOut = false
        })
    }

    private func returnFocusToPreviousApp() {
        guard let app = lastForegroundApp,
              !app.isTerminated,
              app.processIdentifier != NSRunningApplication.current.processIdentifier else { return }
        app.activate()
    }

    deinit {
        hideTimer?.invalidate()
        hoverExitTimer?.invalidate()
        if let activationObserver = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        window?.close()
    }
}

// MARK: - NSWindowDelegate

extension VolumeHUDWindow {
    func windowDidMove(_ notification: Notification) {
        guard let window = window, !isRestoringPosition else { return }
        HUDPositionManager.savePosition(of: window)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = window, !isRestoringPosition else { return }

        // Dragging the HUD across a display boundary changes its screen while
        // the window straddles both, and re-placing it from the stored
        // percentage there would tear it out from under the cursor. The window
        // is where the user put it; only a change that leaves it on no visible
        // pixels at all — a display unplugged, a resolution change — is ours to
        // undo, and then the stored position stands as the user last set it.
        if let screen = window.screen ?? NSScreen.main,
           !screen.visibleFrame.intersects(window.frame) {
            restorePosition(for: window)
            return
        }

        HUDPositionManager.savePosition(of: window)
    }

    func resetToDefaultPosition() {
        guard let window = window else { return }
        HUDPositionManager.clearPosition()

        if let screen = window.screen ?? NSScreen.main {
            positionWindowAtDefault(on: window, screen: screen)
        }

        HUDPositionManager.savePosition(of: window)
    }

    private func positionWindowAtDefault(on window: NSWindow, screen: NSScreen) {
        let screenFrame = screen.visibleFrame
        let windowWidth: CGFloat = 340
        let windowHeight: CGFloat = 120
        let bottomMargin: CGFloat = 70

        let xPosition = screenFrame.midX - (windowWidth / 2)
        let yPosition = screenFrame.minY + bottomMargin

        window.setFrame(
            NSRect(x: xPosition, y: yPosition, width: windowWidth, height: windowHeight),
            display: true
        )
    }

    // MARK: - Hover Handling

    func updateHoldWhileHoverEnabled(_ enabled: Bool) {
        holdWhileHoverEnabled = enabled
        if !enabled {
            if !isMouseHovering {
                scheduleHideTimer(after: defaultHideDelay)
            }
        } else if isMouseHovering {
            registerUserInteraction()
        }
    }

    private func handleHoverState(isHovering: Bool) {
        if holdWhileHoverEnabled {
            if isHovering {
                // Mouse entered - cancel any pending exit and hide timers
                hoverExitTimer?.invalidate()
                hoverExitTimer = nil
                hideTimer?.invalidate()
                isFadingOut = false
                isMouseHovering = true
            } else {
                // Mouse exited - but wait a bit before actually processing it
                // This prevents false exits during drag operations
                hoverExitTimer?.invalidate()
                hoverExitTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.isMouseHovering = false
                    self.scheduleHideTimer(after: self.defaultHideDelay)
                }
            }
        } else {
            isMouseHovering = isHovering
        }
    }
}
