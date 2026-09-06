import Foundation
import ServiceManagement

class AutostartManager {
    func isAutostartEnabled() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        switch SMAppService.mainApp.status { case .enabled: return true; default: return false }
    }

    func setAutostartEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }

        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            print("Autostart toggle failed: \(error.localizedDescription)")
        }
    }
}
