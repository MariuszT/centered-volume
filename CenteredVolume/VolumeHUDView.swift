import SwiftUI
import AppKit

struct HUDDeviceItem: Identifiable, Equatable {
    let id: UInt32
    let name: String
    let isCurrent: Bool
}

final class VolumeHUDViewModel: ObservableObject {
    @Published var volume: Float = 0
    @Published var deviceName: String = ""
    @Published var isMuted: Bool = false
    @Published var availableDevices: [HUDDeviceItem] = []
    @Published var scrubbingLevel: Float?
}

struct VolumeHUDView: View {
    @ObservedObject var model: VolumeHUDViewModel

    let onMinVolumeTap: (() -> Void)?
    let onMaxVolumeTap: (() -> Void)?
    let onDeviceSelected: ((UInt32) -> Void)?
    let onVolumeScrub: ((Float, Bool) -> Void)?
    let onDeviceMenuOpened: (() -> Void)?
    let onSettingsTap: (() -> Void)?
    let onHoverChanged: ((Bool) -> Void)?

    private var effectiveVolume: Float {
        model.isMuted ? 0 : model.volume
    }

    @State private var isDragHandleVisible = false

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            // Drag handle at the top
            DragHandle(isVisible: isDragHandleVisible)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    deviceSelectionView
                    Spacer(minLength: 0)
                    settingsButton
                }

                HStack(spacing: 12) {
                    Button(action: {
                        onMinVolumeTap?()
                    }) {
                        Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 18)
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 4) {
                        VolumeBar(
                            level: effectiveVolume,
                            scrubbingLevel: model.scrubbingLevel,
                            onScrub: { newLevel, isFinal in
                                model.scrubbingLevel = newLevel
                                onVolumeScrub?(newLevel, isFinal)
                            }
                        )
                        .frame(height: 4)

                        ScaleDots()
                            .frame(height: 3)
                    }

                    Button(action: {
                        onMaxVolumeTap?()
                    }) {
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .frame(width: 22, height: 18)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 320)
        .background(LiquidGlassBackground(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(
            HoverDetectionView(onHoverChange: { hovering in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isDragHandleVisible = hovering
                }
                onHoverChanged?(hovering)
            })
        )
    }

    private var deviceSelectionView: some View {
        Menu {
            ForEach(model.availableDevices) { device in
                Button(action: {
                    guard !device.isCurrent else { return }
                    onDeviceSelected?(device.id)
                }) {
                    if device.isCurrent {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
                .disabled(device.isCurrent)
            }
        } label: {
            Text(model.deviceName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                onDeviceMenuOpened?()
            }
        )
    }

    private var settingsButton: some View {
        Button(action: { onSettingsTap?() }) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

struct VolumeBar: NSViewRepresentable {
    let level: Float
    let scrubbingLevel: Float?
    let onScrub: (Float, Bool) -> Void

    func makeNSView(context: Context) -> VolumeBarNSView {
        let view = VolumeBarNSView()
        view.onScrub = onScrub
        return view
    }

    func updateNSView(_ nsView: VolumeBarNSView, context: Context) {
        nsView.level = level
        nsView.scrubbingLevel = scrubbingLevel
        nsView.onScrub = onScrub
        nsView.needsDisplay = true
    }
}

class VolumeBarNSView: NSView {
    var level: Float = 0
    var scrubbingLevel: Float?
    var onScrub: ((Float, Bool) -> Void)?

    private let edgePadding: CGFloat = 9
    private let knobDiameter: CGFloat = 14
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Expand hit area vertically for easier clicking
        let expandedBounds = bounds.insetBy(dx: 0, dy: -6)
        return expandedBounds.contains(point) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let effective = CGFloat(max(0, min(1, scrubbingLevel ?? level)))
        let availableWidth = max(0, bounds.width - edgePadding * 2)
        let trackHeight = bounds.height
        let fillWidth = effective * availableWidth

        // Draw background track
        let trackRect = NSRect(
            x: edgePadding,
            y: (bounds.height - trackHeight) / 2,
            width: availableWidth,
            height: trackHeight
        )
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: 2, yRadius: 2)
        NSColor.white.withAlphaComponent(0.25).setFill()
        trackPath.fill()

        // Draw fill track
        if fillWidth > 0 {
            let fillRect = NSRect(
                x: edgePadding,
                y: (bounds.height - trackHeight) / 2,
                width: fillWidth,
                height: trackHeight
            )
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            fillPath.fill()
        }

        // Draw knob
        let knobX = min(edgePadding + availableWidth, max(edgePadding, edgePadding + fillWidth))
        let knobY = bounds.height / 2
        let knobRect = NSRect(
            x: knobX - knobDiameter / 2,
            y: knobY - knobDiameter / 2,
            width: knobDiameter,
            height: knobDiameter
        )

        // Shadow
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: 0)
        shadow.set()

        let knobPath = NSBezierPath(ovalIn: knobRect)
        NSColor.white.setFill()
        knobPath.fill()
    }

    private func computeLevel(from point: NSPoint) -> Float {
        let availableWidth = max(0, bounds.width - edgePadding * 2)
        guard availableWidth > 0 else { return 0 }

        let clampedX = min(max(point.x, edgePadding), edgePadding + availableWidth)
        let normalized = (clampedX - edgePadding) / availableWidth
        return Float(min(max(normalized, 0), 1))
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        let point = convert(event.locationInWindow, from: nil)
        var currentLevel = computeLevel(from: point)
        onScrub?(currentLevel, false)
        needsDisplay = true

        // Track mouse globally until mouse up
        var mouseUpEvent: NSEvent?
        while mouseUpEvent == nil {
            guard let event = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else {
                // No window, so no further mouse events will ever arrive. Ending
                // the drag on the last level we saw beats spinning the main
                // thread on a loop that has nothing left to wait for.
                isDragging = false
                onScrub?(currentLevel, true)
                needsDisplay = true
                break
            }

            switch event.type {
            case .leftMouseDragged:
                let dragPoint = convert(event.locationInWindow, from: nil)
                currentLevel = computeLevel(from: dragPoint)
                onScrub?(currentLevel, false)
                needsDisplay = true

            case .leftMouseUp:
                mouseUpEvent = event
                let upPoint = convert(event.locationInWindow, from: nil)
                currentLevel = computeLevel(from: upPoint)
                onScrub?(currentLevel, true)
                isDragging = false
                needsDisplay = true

            default:
                break
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        // Handled in mouseDown event loop
    }

    override func mouseUp(with event: NSEvent) {
        // Handled in mouseDown event loop
    }
}

struct ScaleDots: View {
    let dotCount = 17
    private let dotDiameter: CGFloat = 1.4
    private let edgePadding: CGFloat = 9

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(0, geometry.size.width - edgePadding * 2)
            let step = dotCount > 1 ? availableWidth / CGFloat(dotCount - 1) : 0
            let centerY = geometry.size.height / 2

            Path { path in
                for index in 1..<(dotCount - 1) {
                    let x = edgePadding + CGFloat(index) * step
                    path.addEllipse(in: CGRect(
                        x: x - dotDiameter / 2,
                        y: centerY - dotDiameter / 2,
                        width: dotDiameter,
                        height: dotDiameter
                    ))
                }
            }
            .fill(Color.white.opacity(0.35))
        }
        .allowsHitTesting(false)
    }
}

struct LiquidGlassBackground: View {
    var cornerRadius: CGFloat = 24

    var body: some View {
        VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow, cornerRadius: cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
            )
            .allowsHitTesting(false)
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true

        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true

        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.layer?.cornerRadius = cornerRadius
        nsView.layer?.cornerCurve = .continuous
    }
}

struct DraggableHeaderView: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableNSView {
        return DraggableNSView()
    }

    func updateNSView(_ nsView: DraggableNSView, context: Context) {}
}

class DraggableNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct DragHandle: View {
    let isVisible: Bool
    @State private var isHovering = false

    var body: some View {
        HStack {
            Spacer()
            ZStack(alignment: .center) {
                // Visual indicator with hover effect
                Capsule()
                    .fill(Color.white.opacity(isVisible ? (isHovering ? 0.6 : 0.4) : 0))
                    .frame(width: isHovering ? 55 : 50, height: 4)
                    .animation(.easeInOut(duration: 0.15), value: isHovering)
                    .allowsHitTesting(false)

                // Draggable + hover layer
                DraggableHandleView(onHoverChange: { hovering in
                    isHovering = hovering
                })
                .frame(width: 50, height: 10)
            }
            .frame(width: 60, height: 10)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 5)
        .padding(.bottom, -22)
    }
}

struct DraggableHandleView: NSViewRepresentable {
    var onHoverChange: ((Bool) -> Void)?

    func makeNSView(context: Context) -> DraggableHandleNSView {
        let view = DraggableHandleNSView()
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: DraggableHandleNSView, context: Context) {
        nsView.onHoverChange = onHoverChange
    }
}

struct HoverDetectionView: NSViewRepresentable {
    var onHoverChange: ((Bool) -> Void)?

    func makeNSView(context: Context) -> HoverDetectionNSView {
        let view = HoverDetectionNSView()
        view.onHoverChange = onHoverChange
        return view
    }

    func updateNSView(_ nsView: HoverDetectionNSView, context: Context) {
        nsView.onHoverChange = onHoverChange
    }
}

class HoverDetectionNSView: NSView {
    private var trackingArea: NSTrackingArea?
    var onHoverChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        setupTrackingArea()
    }

    private func setupTrackingArea() {
        if let existingTrackingArea = trackingArea {
            removeTrackingArea(existingTrackingArea)
        }

        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeAlways,
            .inVisibleRect
        ]

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )

        if let trackingArea = trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}

class DraggableHandleNSView: NSView {
    private var trackingArea: NSTrackingArea?
    private var isMouseInside = false
    private var cursorUpdateTimer: Timer?
    var onHoverChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        setupTrackingArea()
    }

    private func setupTrackingArea() {
        // Remove old tracking area
        if let existingTrackingArea = trackingArea {
            removeTrackingArea(existingTrackingArea)
        }

        // Create new tracking area with options that work even without focus
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .cursorUpdate,
            .activeAlways,  // Track even when app is not active
            .inVisibleRect  // Automatically update when view bounds change
        ]

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )

        if let trackingArea = trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    // Dragging a window needs neither an active application nor a key window:
    // performDrag(with:) works on an inactive one, and the tracking area is
    // .activeAlways. Activating here would swallow whatever the user is typing
    // in the app they are actually working in, and this app has no dock icon
    // or menu bar item to show them where their keystrokes went.
    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        onHoverChange?(true)

        startCursorUpdateTimer()
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        onHoverChange?(false)

        stopCursorUpdateTimer()

        NSCursor.arrow.set()
    }

    // .cursorUpdate is delivered to an inactive application too, so the open
    // hand appears without the app having to take focus first.
    override func cursorUpdate(with event: NSEvent) {
        if isMouseInside {
            NSCursor.openHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    private func startCursorUpdateTimer() {
        stopCursorUpdateTimer()

        // Set cursor immediately multiple times to combat system resets
        NSCursor.openHand.set()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            NSCursor.openHand.set()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            NSCursor.openHand.set()
        }

        // Then keep refreshing with timer at faster rate
        cursorUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, self.isMouseInside else { return }
            NSCursor.openHand.set()
        }
    }

    private func stopCursorUpdateTimer() {
        cursorUpdateTimer?.invalidate()
        cursorUpdateTimer = nil
    }

    override func mouseDown(with event: NSEvent) {
        // Stop timer during drag to avoid cursor flickering
        stopCursorUpdateTimer()

        NSCursor.closedHand.set()
        window?.performDrag(with: event)

        // Check if mouse is still over the view after drag
        let mouseLocation = NSEvent.mouseLocation
        if let window = self.window {
            let windowFrame = window.frame
            let viewFrameInWindow = self.convert(self.bounds, to: nil)
            let viewFrameInScreen = NSRect(
                x: windowFrame.origin.x + viewFrameInWindow.origin.x,
                y: windowFrame.origin.y + viewFrameInWindow.origin.y,
                width: viewFrameInWindow.width,
                height: viewFrameInWindow.height
            )

            let stillInside = viewFrameInScreen.contains(mouseLocation)
            self.isMouseInside = stillInside
            self.onHoverChange?(stillInside)

            if stillInside {
                // Still inside - restart timer and set cursor
                NSCursor.openHand.set()
                startCursorUpdateTimer()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}
