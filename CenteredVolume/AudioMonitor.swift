import Foundation
import CoreAudio
import AudioToolbox
import AppKit
import ApplicationServices
import Carbon.HIToolbox.Events
import os

class AudioMonitor {
    typealias VolumeChangeCallback = (Float, String, Bool) -> Void
    typealias VolumeKeyCallback = (VolumeKeyType) -> Void

    enum VolumeKeyType {
        case up
        case down
        case mute
    }

    struct OutputDevice: Identifiable, Equatable {
        let identifier: AudioDeviceID
        let name: String
        let isDefault: Bool

        var id: AudioDeviceID { identifier }
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "pl.tarnaski.centeredvolume",
        category: "audio"
    )

    private var callback: VolumeChangeCallback
    var onVolumeKey: VolumeKeyCallback?
    private var storedDefaultOutputDeviceID: AudioDeviceID = 0
    private var cachedMuteState: Bool?
    private var lastOwnWrite: (level: Float, muted: Bool?, at: CFAbsoluteTime)?
    // The volume to restore on a device with no mute property, set while the
    // fallback in `toggleVolumeZeroMute` has driven the level to 0. Only
    // touched from `propertyQueue`, so — unlike the state above — it needs no
    // lock of its own.
    private var savedPreMuteVolume: Float?
    private let propertyQueue = DispatchQueue(label: "com.centeredvolume.audio.property")
    private let stateLock = NSLock()
    // How long a value we wrote ourselves stays recognisable as our own echo,
    // and how far the device may round it while still counting as the same write.
    private let ownWriteWindow: CFTimeInterval = 0.3
    private let ownWriteTolerance: Float = 0.01
    private var isMonitoring = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// The device every volume read, write and listener registration goes to.
    /// It changes on the main thread (the device picker in the HUD) and on the
    /// HAL thread (headphones plugged in), so the value is behind the state lock
    /// and the transitions themselves run on `propertyQueue`.
    var defaultOutputDeviceID: AudioDeviceID {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedDefaultOutputDeviceID
    }

    init(callback: @escaping VolumeChangeCallback) {
        self.callback = callback
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Every listener registration goes through this queue, so that the HAL
        // thread and the main thread can never interleave a remove/add pair.
        propertyQueue.sync {
            addDefaultDeviceListener()

            if let deviceID = fetchDefaultOutputDeviceID() {
                switchDefaultOutputDevice(to: deviceID)
            }
        }

        startKeyEventMonitoring()
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        propertyQueue.sync {
            removeDefaultDeviceListener()
            switchDefaultOutputDevice(to: 0)
        }

        stopKeyEventMonitoring()
    }

    /// Creates the volume-key tap if it does not exist yet. Accessibility can be
    /// granted long after launch, so this has to be callable again from every
    /// place that learns the permission arrived.
    func startKeyEventMonitoring() {
        guard eventTap == nil else { return }

        guard ensureAccessibilityPermission() else { return }

        guard let systemDefinedEvent = CGEventType(rawValue: UInt32(NX_SYSDEFINED)) else {
            return
        }

        let mask = CGEventMask(1) << CGEventMask(systemDefinedEvent.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: volumeKeyEventTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let eventTap = eventTap else { return }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)

        if let runLoopSource = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            if !CGEvent.tapIsEnabled(tap: eventTap) {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
        }
    }

    private func stopKeyEventMonitoring() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
    }

    private func ensureAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    private func reenableEventTap() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    fileprivate func handleVolumeKeyEvent(type: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableEventTap()
            return Unmanaged.passUnretained(cgEvent)
        }

        guard let systemDefinedEvent = CGEventType(rawValue: UInt32(NX_SYSDEFINED)),
              type == systemDefinedEvent,
              let event = NSEvent(cgEvent: cgEvent),
              event.subtype.rawValue == NX_SUBTYPE_AUX_CONTROL_BUTTONS else {
            return Unmanaged.passUnretained(cgEvent)
        }

        let data = UInt32(bitPattern: Int32(event.data1))
        let keyCode = Int32((data & 0xFFFF_0000) >> 16)
        let keyFlags = data & 0x0000_FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isKeyDown = keyState == UInt32(NX_KEYDOWN)

        let isVolumeKey = (
            keyCode == NX_KEYTYPE_SOUND_DOWN ||
            keyCode == NX_KEYTYPE_SOUND_UP ||
            keyCode == NX_KEYTYPE_MUTE
        )

        if isVolumeKey && isKeyDown {
            if let onVolumeKey = self.onVolumeKey {
                DispatchQueue.main.async { [weak self] in
                    guard self != nil else { return }
                    if keyCode == NX_KEYTYPE_SOUND_UP {
                        onVolumeKey(.up)
                    } else if keyCode == NX_KEYTYPE_SOUND_DOWN {
                        onVolumeKey(.down)
                    } else if keyCode == NX_KEYTYPE_MUTE {
                        onVolumeKey(.mute)
                    }
                }
                return nil
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.notifyVolumeChange()
                }
            }
        }

        return Unmanaged.passUnretained(cgEvent)
    }

    private func fetchDefaultOutputDeviceID() -> AudioDeviceID? {
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var deviceID: AudioDeviceID = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr else {
            AudioMonitor.log.error("reading the default output device failed: OSStatus \(status, privacy: .public)")
            return nil
        }

        return deviceID
    }

    /// Moves the volume and mute listeners from the previous default device to
    /// `deviceID`, or drops them for 0. Must run on `propertyQueue`: the main
    /// thread and the HAL thread both ask for switches, and interleaving the
    /// remove/add pair leaves one device listened to twice and another not at
    /// all — which is a permanent leak, since `stopMonitoring` unregisters once.
    private func switchDefaultOutputDevice(to deviceID: AudioDeviceID) {
        dispatchPrecondition(condition: .onQueue(propertyQueue))

        let previous = defaultOutputDeviceID
        guard previous != deviceID else { return }

        if previous != 0 {
            removeVolumeListener(for: previous)
        }

        stateLock.lock()
        storedDefaultOutputDeviceID = deviceID
        // Both belong to the device we just left.
        lastOwnWrite = nil
        cachedMuteState = nil
        stateLock.unlock()

        // Also belongs to the device we just left — a level saved for it must
        // never be replayed onto whatever we switch to.
        savedPreMuteVolume = nil

        if deviceID != 0 {
            addVolumeListener(for: deviceID)
        }
    }

    /// The HAL announces the switch on its own thread; the work itself is handed
    /// to `propertyQueue` so it lines up behind anything the main thread started.
    fileprivate func handleDefaultDeviceChange() {
        propertyQueue.async { [weak self] in
            guard let self = self else { return }
            guard let deviceID = self.fetchDefaultOutputDeviceID() else { return }

            self.switchDefaultOutputDevice(to: deviceID)
            self.notifyVolumeChange()
        }
    }

    private func log(_ status: OSStatus, _ operation: String, forDevice deviceID: AudioDeviceID) {
        guard status != noErr else { return }
        AudioMonitor.log.error("\(operation, privacy: .public) failed for device \(deviceID, privacy: .public): OSStatus \(status, privacy: .public)")
    }

    func getDeviceName(for deviceID: AudioDeviceID) -> String {
        var propertySize = UInt32(MemoryLayout<CFString>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceName: CFString = "" as CFString
        let status: OSStatus = withUnsafeMutablePointer(to: &deviceName) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &propertySize,
                pointer
            )
        }

        if status == noErr {
            return deviceName as String
        }
        return "Unknown Device"
    }

    func getVolume(for deviceID: AudioDeviceID) -> Float {
        var volume: Float32 = 0.0
        var propertySize = UInt32(MemoryLayout<Float32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &volume
        )

        return status == noErr ? volume : 0.0
    }

    func isMuted(for deviceID: AudioDeviceID) -> Bool {
        var muted: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &muted
        )

        return status == noErr ? muted != 0 : false
    }

    private func addDefaultDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            defaultDeviceChangeListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        log(status, "adding the default device listener", forDevice: 0)
    }

    private func removeDefaultDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            defaultDeviceChangeListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        log(status, "removing the default device listener", forDevice: 0)
    }

    private func addVolumeListener(for deviceID: AudioDeviceID) {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let volumeStatus = AudioObjectAddPropertyListener(
            deviceID,
            &propertyAddress,
            volumeChangeListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        log(volumeStatus, "adding the volume listener", forDevice: deviceID)

        // Also listen for mute changes
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let muteStatus = AudioObjectAddPropertyListener(
            deviceID,
            &muteAddress,
            volumeChangeListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        log(muteStatus, "adding the mute listener", forDevice: deviceID)
    }

    private func removeVolumeListener(for deviceID: AudioDeviceID) {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let volumeStatus = AudioObjectRemovePropertyListener(
            deviceID,
            &propertyAddress,
            volumeChangeListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        log(volumeStatus, "removing the volume listener", forDevice: deviceID)

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let muteStatus = AudioObjectRemovePropertyListener(
            deviceID,
            &muteAddress,
            volumeChangeListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
        log(muteStatus, "removing the mute listener", forDevice: deviceID)
    }

    /// Entry point for every HAL notification on the current device.
    fileprivate func handleDeviceNotification() {
        let deviceID = defaultOutputDeviceID
        guard deviceID != 0 else { return }

        let volume = getVolume(for: deviceID)
        let muted = isMuted(for: deviceID)
        guard !isEchoOfOwnWrite(volume: volume, muted: muted) else { return }

        notifyVolumeChange(volume: volume, muted: muted, deviceID: deviceID)
    }

    fileprivate func notifyVolumeChange() {
        let deviceID = defaultOutputDeviceID
        guard deviceID != 0 else { return }

        notifyVolumeChange(
            volume: getVolume(for: deviceID),
            muted: isMuted(for: deviceID),
            deviceID: deviceID
        )
    }

    private func notifyVolumeChange(volume: Float, muted: Bool, deviceID: AudioDeviceID) {
        let deviceName = getDeviceName(for: deviceID)

        callback(volume, deviceName, muted)
        setCachedMuteState(muted)
    }

    /// A write we make ourselves still reaches the listener as a HAL
    /// notification we do not want to turn into a HUD. Recognising it by the
    /// state we last wrote — instead of counting notifications we expect —
    /// survives both a write that produces none (setting the value the device
    /// already had) and one that produces two (a write that also unmutes).
    /// The record is left in place on a match and expires on time, because a
    /// single write can legitimately be echoed more than once.
    ///
    /// `muted` is nil for a volume write, which does not claim a mute state: the
    /// auto-unmute that may follow it is then still recognised by the volume.
    private func isEchoOfOwnWrite(volume: Float, muted: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let lastWrite = lastOwnWrite else { return false }

        guard CFAbsoluteTimeGetCurrent() - lastWrite.at < ownWriteWindow else {
            lastOwnWrite = nil
            return false
        }

        guard abs(volume - lastWrite.level) < ownWriteTolerance else { return false }

        if let expectedMute = lastWrite.muted, expectedMute != muted { return false }

        return true
    }

    private func rememberOwnWrite(level: Float, muted: Bool? = nil) {
        stateLock.lock()
        lastOwnWrite = (level: level, muted: muted, at: CFAbsoluteTimeGetCurrent())
        stateLock.unlock()
    }

    private func forgetOwnWrite() {
        stateLock.lock()
        lastOwnWrite = nil
        stateLock.unlock()
    }

    private func cachedMute() -> Bool? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cachedMuteState
    }

    private func setCachedMuteState(_ muted: Bool?) {
        stateLock.lock()
        cachedMuteState = muted
        stateLock.unlock()
    }

    func setVolume(to level: Float, notify: Bool = true) {
        guard defaultOutputDeviceID != 0 else { return }

        let clampedLevel = max(0, min(1, level))
        let deviceID = defaultOutputDeviceID

        propertyQueue.async { [weak self] in
            guard let self = self else { return }

            var volume: Float32 = Float32(clampedLevel)
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )

            // Recorded before the write, because the HAL can deliver the
            // notification on another thread before the setter returns.
            if !notify {
                self.rememberOwnWrite(level: clampedLevel)
            }

            let status = AudioObjectSetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &volume
            )

            guard status == noErr else {
                if !notify {
                    self.forgetOwnWrite()
                }
                return
            }

            let shouldUnmute = clampedLevel > 0 && (self.cachedMute() ?? true)

            if shouldUnmute {
                self.setMute(for: deviceID, to: false)
            }

            if notify {
                DispatchQueue.main.async {
                    self.notifyVolumeChange()
                }
            }
        }
    }

    func listOutputDevices() -> [OutputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID -> OutputDevice? in
            guard deviceHasOutput(deviceID) else { return nil }
            let name = getDeviceName(for: deviceID)
            let isDefault = deviceID == defaultOutputDeviceID
            return OutputDevice(identifier: deviceID, name: name, isDefault: isDefault)
        }
    }

    @discardableResult
    func setDefaultOutputDevice(to deviceID: AudioDeviceID) -> Bool {
        guard deviceID != 0 else { return false }

        var mutableDeviceID = deviceID
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )

        guard status == noErr else { return false }

        propertyQueue.async { [weak self] in
            guard let self = self else { return }

            self.switchDefaultOutputDevice(to: deviceID)

            DispatchQueue.main.async {
                self.notifyVolumeChange()
            }
        }

        return true
    }

    private func deviceHasOutput(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementWildcard
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return false }

        let streamCount = Int(dataSize) / MemoryLayout<AudioStreamID>.size
        return streamCount > 0
    }

    /// Flips the device's mute the way the system mute key does and returns the
    /// state read back from the device. The read-modify-write runs on the
    /// property queue so it cannot interleave with a volume write of our own.
    ///
    /// Many HDMI/DisplayPort displays, USB audio interfaces and Bluetooth
    /// outputs expose `VirtualMainVolume` but no main-element mute at all, so
    /// this probes for the property before committing to the toggle. Without
    /// the probe, `setMute` below simply fails on those devices, the read-back
    /// still reports unmuted, and the key does nothing — worse than the old
    /// zero-the-volume behaviour it replaced. `toggleVolumeZeroMute` restores
    /// that old behaviour as the fallback so the key always does something.
    @discardableResult
    func toggleMute(for deviceID: AudioDeviceID) -> Bool {
        propertyQueue.sync {
            guard hasMuteProperty(for: deviceID) else {
                return toggleVolumeZeroMute(for: deviceID)
            }

            let target = !isMuted(for: deviceID)

            // Recorded before the write, and with the volume the mute leaves
            // untouched, so the echo is recognised on a device whose
            // notification takes longer to arrive than the key press lasts.
            rememberOwnWrite(level: getVolume(for: deviceID), muted: target)

            if !setMute(for: deviceID, to: target) {
                forgetOwnWrite()
            }

            // Read back rather than trust the write: a device that refused it
            // must not leave the HUD claiming otherwise.
            return isMuted(for: deviceID)
        }
    }

    private func hasMuteProperty(for deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectHasProperty(deviceID, &propertyAddress)
    }

    /// Emulates mute on a device with no mute property by saving the current
    /// level and zeroing it, then restoring that level on the next press —
    /// this key's behaviour before hardware mute-toggle support replaced it.
    /// `savedPreMuteVolume` being set is what "muted" means here; there is no
    /// hardware flag to read back, unlike the branch above. Must run on
    /// `propertyQueue`, same as the rest of `toggleMute`.
    private func toggleVolumeZeroMute(for deviceID: AudioDeviceID) -> Bool {
        dispatchPrecondition(condition: .onQueue(propertyQueue))

        if let savedVolume = savedPreMuteVolume {
            savedPreMuteVolume = nil
            setVolumeRaw(for: deviceID, to: savedVolume)
            return false
        }

        savedPreMuteVolume = getVolume(for: deviceID)
        setVolumeRaw(for: deviceID, to: 0)
        return true
    }

    /// The raw HAL write `setVolume(to:)` performs, minus its higher-level
    /// policy (auto-unmute, main-thread dispatch, `notify` branching). Used
    /// only by `toggleVolumeZeroMute`, which already runs on `propertyQueue`.
    @discardableResult
    private func setVolumeRaw(for deviceID: AudioDeviceID, to level: Float) -> Bool {
        let clampedLevel = max(0, min(1, level))
        var volume = Float32(clampedLevel)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Recorded before the write, same reasoning as `setVolume(to:)`: the
        // HAL can deliver the change notification before the setter returns.
        rememberOwnWrite(level: clampedLevel)

        let status = AudioObjectSetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &volume
        )

        if status != noErr {
            forgetOwnWrite()
        }

        log(status, "setting volume (mute-property-less fallback)", forDevice: deviceID)

        return status == noErr
    }

    @discardableResult
    private func setMute(for deviceID: AudioDeviceID, to muted: Bool) -> Bool {
        var muteValue: UInt32 = muted ? 1 : 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &muteValue
        )

        log(status, "setting mute", forDevice: deviceID)

        if status == noErr {
            setCachedMuteState(muted)
        }

        return status == noErr
    }
}

// C callbacks
private func volumeChangeListener(
    inObjectID: AudioObjectID,
    inNumberAddresses: UInt32,
    inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData = inClientData else { return noErr }

    let monitor = Unmanaged<AudioMonitor>.fromOpaque(inClientData).takeUnretainedValue()

    monitor.handleDeviceNotification()

    return noErr
}

private func volumeKeyEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else {
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<AudioMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handleVolumeKeyEvent(type: type, cgEvent: event)
}

private func defaultDeviceChangeListener(
    inObjectID: AudioObjectID,
    inNumberAddresses: UInt32,
    inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData = inClientData else { return noErr }

    let monitor = Unmanaged<AudioMonitor>.fromOpaque(inClientData).takeUnretainedValue()

    monitor.handleDefaultDeviceChange()

    return noErr
}
