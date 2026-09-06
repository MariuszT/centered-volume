import SwiftUI
import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: SettingsViewModel

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 445),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Centered Volume settings"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(viewModel: viewModel))
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindow() {
        guard let window = window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.onWindowClosed()
    }
}

final class SettingsViewModel: ObservableObject {
    @Published var hasAccessibilityPermission: Bool
    @Published var isRequestingPermission = false
    @Published var autostartEnabled: Bool
    @Published var holdWhileHoverEnabled: Bool

    private let requestPermissionAction: (@escaping (Bool) -> Void) -> Void
    private let autostartToggleAction: (Bool) -> Void
    private let resetPositionAction: () -> Void
    private let holdWhileHoverAction: (Bool) -> Void

    init(
        hasAccessibilityPermission: Bool,
        autostartEnabled: Bool,
        holdWhileHoverEnabled: Bool,
        requestPermissionAction: @escaping (@escaping (Bool) -> Void) -> Void,
        autostartToggleAction: @escaping (Bool) -> Void,
        resetPositionAction: @escaping () -> Void,
        holdWhileHoverAction: @escaping (Bool) -> Void
    ) {
        self.hasAccessibilityPermission = hasAccessibilityPermission
        self.autostartEnabled = autostartEnabled
        self.holdWhileHoverEnabled = holdWhileHoverEnabled
        self.requestPermissionAction = requestPermissionAction
        self.autostartToggleAction = autostartToggleAction
        self.resetPositionAction = resetPositionAction
        self.holdWhileHoverAction = holdWhileHoverAction
    }

    func requestPermission() {
        guard !hasAccessibilityPermission, !isRequestingPermission else { return }
        isRequestingPermission = true
        requestPermissionAction { [weak self] granted in
            guard let self = self else { return }
            self.hasAccessibilityPermission = granted
            self.isRequestingPermission = false
        }
    }

    func toggleAutostart(_ newValue: Bool) {
        autostartEnabled = newValue
        autostartToggleAction(newValue)
    }

    func toggleHoldWhileHover(_ newValue: Bool) {
        holdWhileHoverEnabled = newValue
        holdWhileHoverAction(newValue)
    }

    func resetHUDPosition() {
        resetPositionAction()
    }

    func onWindowClosed() {
        isRequestingPermission = false
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                accessibilityRow
                Divider()
                Toggle(isOn: Binding(get: { viewModel.autostartEnabled }, set: viewModel.toggleAutostart)) {
                    Text("Launch Centered Volume when macOS starts")
                }
                Divider()
                Toggle(isOn: Binding(get: { viewModel.holdWhileHoverEnabled }, set: viewModel.toggleHoldWhileHover)) {
                    Text("Keep the HUD visible while the cursor hovers over it")
                }
                Divider()
                Button(action: viewModel.resetHUDPosition) {
                    Text("Reset HUD position to default")
                }
                Divider()
                aboutSection
            }
            .padding(24)
        }
        .frame(minWidth: 420, minHeight: 420)
    }

    private var accessibilityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accessibility access lets detect volume-key presses, even when sound is already muted or maxed out.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            if viewModel.hasAccessibilityPermission {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Permission granted, thanks!")
                }
                .font(.system(size: 13, weight: .semibold))
            } else {
                Button(action: viewModel.requestPermission) {
                    HStack(spacing: 8) {
                        if viewModel.isRequestingPermission {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.6)
                                .frame(width: 14, height: 14)
                        }
                        Text("Grant accessibility access")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.isRequestingPermission)
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Built by Mariusz Tarnaski")
            Link("tarnaski.pl", destination: URL(string: "https://tarnaski.pl/en/centered-volume")!)
            Link("github.com", destination: URL(string: "https://github.com/MariuszT/centered-volume")!)
            Text("Open Source, licensed under MIT")
        }
        .font(.system(size: 13))
    }
}
