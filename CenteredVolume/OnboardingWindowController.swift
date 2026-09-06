import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator = OnboardingCoordinator()
    private let permissionManager = AccessibilityPermissionManager()
    private var didComplete = false
    private let completionHandler: (Bool) -> Void
    private let autostartHandler: (Bool) -> Void
    private let closedWithoutPermissionHandler: () -> Void

    init(onFinished: @escaping (Bool) -> Void,
         onClosedWithoutPermission: @escaping () -> Void,
         onAutostartPreference: @escaping (Bool) -> Void) {
        self.completionHandler = onFinished
        self.autostartHandler = onAutostartPreference
        self.closedWithoutPermissionHandler = onClosedWithoutPermission

        super.init(window: nil)

        let contentView = OnboardingView(
            coordinator: coordinator,
            permissionManager: permissionManager,
            onAutostartChosen: { [weak self] enabled in
                self?.autostartHandler(enabled)
            },
            onFinish: { [weak self] granted in
                guard let self = self else { return }
                self.didComplete = true
                self.completionHandler(granted)
                self.close()
            }
        )

        let hosting = NSHostingView(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Centered Volume"
        window.center()
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.window = window
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

    func markCompleted() {
        didComplete = true
    }

    func windowWillClose(_ notification: Notification) {
        guard !didComplete else { return }
        closedWithoutPermissionHandler()
    }

    deinit {
        window?.delegate = nil
    }
}

// MARK: - Coordinator

final class OnboardingCoordinator: ObservableObject {
    enum Stage: Equatable {
        case welcome
        case autostart
        case feature(index: Int)
    }

    @Published var stage: Stage = .welcome
    @Published var isRequestingPermission = false
    @Published var hasRequestedPermission = false
    @Published var hasGrantedPermission = false
    @Published var autostartPreference: Bool = false

    func beginFeatures() {
        stage = .feature(index: 0)
    }

    func advanceFeature(total: Int) {
        guard case let .feature(index) = stage else { return }
        if index + 1 < total {
            stage = .feature(index: index + 1)
        }
    }
}

// MARK: - View

struct OnboardingView: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let permissionManager: AccessibilityPermissionManager
    let onAutostartChosen: (Bool) -> Void
    let onFinish: (Bool) -> Void

    private let featureSlides: [FeatureSlide] = [
        FeatureSlide(
            title: "Default position: above the Dock",
            description: "Centered Volume mirrors the classic HUD before Tahoe so volume changes stay anchored in the middle of your display.",
            gifName: "dock"
        ),
        FeatureSlide(
            title: "Quick device switching",
            description: "Tap the device name to hop between your available speakers, headphones and other sound devices.",
            gifName: "speakers"
        ),
        FeatureSlide(
            title: "Click, drag, control",
            description: "Mute, max, or drag the slider bar directly on the HUD for fast adjustments with your mouse or trackpad.",
            gifName: "change"
        ),
        FeatureSlide(
            title: "Place it anywhere",
            description: "Grab the HUD and drop it wherever suits you. Centered Volume remembers the exact spot across sessions.",
            gifName: "move"
        ),
        FeatureSlide(
            title: "Quietly customizable",
            description: "The settings gear reveals extra options, while the app stays out of your Dock and menu bar to keep things tidy.",
            gifName: "settings"
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch coordinator.stage {
            case .welcome:
                welcomeSlide
            case .autostart:
                autostartSlide
            case let .feature(index):
                featureSlide(for: index)
            }
        }
        .padding(32)
        .frame(minWidth: 520, minHeight: 420)
    }

    private var welcomeSlide: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 20) {
                // The app's own icon, so the first screen shows the thing the
                // user just installed rather than a stand-in symbol.
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 100, height: 100)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Welcome to Centered Volume")
                        .font(.system(size: 24, weight: .semibold))
                        .multilineTextAlignment(.leading)
                    Text("If, like me, you’re unhappy that the volume indicator was moved from the center of the screen in the new macOS Tahoe, I’ve got good news for you - the app you just launched brings it back.")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("One quick favor before we start")
                    .font(.headline)
                Text("Centered Volume needs accessibility permissions to detect when you press the volume up or down buttons while the sound is already muted or set to maximum. Without this permission, for example, if your sound is muted and you press the volume down button to check, Centered Volume won’t detect it and the app won’t appear, which might make it seem like it has stopped working. That’s why we kindly ask you to grant the app the necessary permissions.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(action: startPermissionFlow) {
                HStack(spacing: 8) {
                    if coordinator.isRequestingPermission {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    }
                    Text(coordinator.isRequestingPermission ? "Requesting..." : "Grant access")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(coordinator.isRequestingPermission)
        }
    }

    private var autostartSlide: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Launch at login?")
                .font(.system(size: 24, weight: .semibold))

            Text("Let Centered Volume start automatically with macOS so the HUD is always ready when you tap the volume keys. You can change this later in settings.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack(spacing: 16) {
                Button {
                    coordinator.autostartPreference = true
                    onAutostartChosen(true)
                    coordinator.beginFeatures()
                } label: {
                    Text("Start at login")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    coordinator.autostartPreference = false
                    onAutostartChosen(false)
                    coordinator.beginFeatures()
                } label: {
                    Text("Not now")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }

    private func featureSlide(for index: Int) -> some View {
        let slide = featureSlides[index]
        return VStack(alignment: .leading, spacing: 24) {
            Text(slide.title)
                .font(.system(size: 24, weight: .semibold))
                .multilineTextAlignment(.leading)

            HStack(alignment: .center, spacing: 24) {
                Spacer(minLength: 0)
                if let gifName = slide.gifName {
                    AnimatedGIFView(gifName: gifName)
                        .frame(width: 320, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else if let systemImage = slide.systemImage {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.gray.opacity(0.12))
                        .frame(width: 220, height: 220)
                        .overlay(
                            Image(systemName: systemImage)
                                .font(.system(size: 72, weight: .light))
                                .foregroundColor(.accentColor)
                        )
                }
                Spacer(minLength: 0)
            }

            Text(slide.description)
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Spacer()
                Button(action: {
                    if index + 1 == featureSlides.count {
                        onFinish(coordinator.hasGrantedPermission)
                    } else {
                        coordinator.advanceFeature(total: featureSlides.count)
                    }
                }) {
                    Text(index + 1 == featureSlides.count ? "Finish" : "Next")
                        .fontWeight(.semibold)
                        .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func startPermissionFlow() {
        guard !coordinator.isRequestingPermission else { return }

        coordinator.isRequestingPermission = true

        // The manager itself polls until granted or timed out, so its
        // completion is the real answer — no need for a second, shorter
        // guess on top of it.
        permissionManager.requestPermission { granted in
            coordinator.isRequestingPermission = false
            coordinator.hasRequestedPermission = true
            coordinator.hasGrantedPermission = granted
            coordinator.stage = .autostart
        }
    }
}

private struct FeatureSlide: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let systemImage: String?
    let gifName: String?

    init(title: String, description: String, systemImage: String) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.gifName = nil
    }

    init(title: String, description: String, gifName: String) {
        self.title = title
        self.description = description
        self.systemImage = nil
        self.gifName = gifName
    }
}

struct AnimatedGIFView: NSViewRepresentable {
    let gifName: String

    func makeNSView(context: Context) -> GIFPlayerView {
        let view = GIFPlayerView()
        view.loadGif(named: gifName)
        return view
    }

    func updateNSView(_ nsView: GIFPlayerView, context: Context) {
        nsView.loadGif(named: gifName)
    }
}

class GIFPlayerView: NSView {
    private var imageSource: CGImageSource?
    private var animationTimer: Timer?
    private var currentGifName: String?
    private var currentFrameIndex = 0
    private var frameCount = 0
    private var frameDurations: [TimeInterval] = []
    private var lastFrameTime: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func loadGif(named name: String) {
        // SwiftUI calls updateNSView on every re-render of the slide, not only
        // when the GIF actually changes; reloading each time would restart the
        // animation from frame zero and pile up a fresh timer on top.
        guard name != currentGifName else { return }
        guard let data = NSDataAsset(name: name)?.data else { return }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }

        stopAnimation()

        currentGifName = name
        imageSource = source
        frameCount = CGImageSourceGetCount(source)
        frameDurations = (0..<frameCount).map { index in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                  let gifProperties = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any],
                  let duration = gifProperties[kCGImagePropertyGIFDelayTime as String] as? TimeInterval else {
                return 0.1
            }
            return duration > 0 ? duration : 0.1
        }

        currentFrameIndex = 0
        lastFrameTime = CACurrentMediaTime()
        startAnimation()
    }

    private func startAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            self.updateFrame()
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        imageSource = nil
        layer?.contents = nil
    }

    private func updateFrame() {
        guard let source = imageSource, frameCount > 0 else { return }

        let currentTime = CACurrentMediaTime()
        let elapsed = currentTime - lastFrameTime

        if elapsed >= frameDurations[currentFrameIndex] {
            currentFrameIndex = (currentFrameIndex + 1) % frameCount
            lastFrameTime = currentTime

            if let cgImage = CGImageSourceCreateImageAtIndex(source, currentFrameIndex, nil) {
                layer?.contents = cgImage
            }
        }
    }

    deinit {
        stopAnimation()
    }
}
