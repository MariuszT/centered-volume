import AppKit

enum HUDPositionManager {
    private static let xKey = "com.centeredvolume.hud.position.x"
    private static let yKey = "com.centeredvolume.hud.position.y"

    private static let defaults = UserDefaults.standard

    /// The stored position is the window origin as a fraction of the visible
    /// frame of the screen it sits on. It is recorded exactly as the user left
    /// it and clamped only when it is put back, so a spell on a narrower screen
    /// cannot rewrite the position the user chose on a wider one.
    static func savePosition(of window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let windowFrame = window.frame
        let screenFrame = screen.visibleFrame

        guard screenFrame.width > 0, screenFrame.height > 0 else { return }

        let xPercent = (windowFrame.origin.x - screenFrame.minX) / screenFrame.width
        let yPercent = (windowFrame.origin.y - screenFrame.minY) / screenFrame.height

        defaults.set(xPercent, forKey: xKey)
        defaults.set(yPercent, forKey: yKey)
    }

    static func restorePosition(for window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        guard let storedX = defaults.object(forKey: xKey) as? Double,
              let storedY = defaults.object(forKey: yKey) as? Double else { return }

        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size

        guard screenFrame.width > 0, screenFrame.height > 0 else { return }

        let proposedX = screenFrame.minX + storedX * screenFrame.width
        let proposedY = screenFrame.minY + storedY * screenFrame.height

        let clampedX = max(screenFrame.minX, min(proposedX, screenFrame.maxX - windowSize.width))
        let clampedY = max(screenFrame.minY, min(proposedY, screenFrame.maxY - windowSize.height))

        window.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
    }

    static func clearPosition() {
        defaults.removeObject(forKey: xKey)
        defaults.removeObject(forKey: yKey)
    }
}
