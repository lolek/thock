import Cocoa
import KeyboardShortcuts

class KeyboardEventTracker {
    private var pressedKeys: Set<Int64> = []
    private var eventMonitor: CFMachPort?
    private var lastEventTime: Double = 0
    private var watchdogTimer: Timer?
    
    deinit {
        stopTracking()
    }
    
    /// Starts tracking key events.
    /// - Parameter delegate: The delegate to handle key events.
    func startTracking() {
        stopTracking()
        
        let eventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) |
        (1 << CGEventType.keyUp.rawValue) |
        (1 << CGEventType.flagsChanged.rawValue) |
        CGEventMask(1 << 14) // NSSystemDefined
        
        let observer = Unmanaged.passRetained(self).toOpaque()
        lastEventTime = currentTime()
        
        eventMonitor = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                let tracker = Unmanaged<KeyboardEventTracker>.fromOpaque(userInfo!).takeUnretainedValue()
                
                // macOS disables the tap when the callback is too slow (tapDisabledByTimeout)
                // or on certain user input (tapDisabledByUserInput). Previously the tracker
                // stopped tracking here and keyboard sounds were lost until app restart.
                // Re-enable the tap instead and reset key state, since key-up events may
                // have been missed while the tap was disabled.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    tracker.reenableTap()
                    return Unmanaged.passUnretained(event)
                }
                
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                
                if SettingsEngine.shared.isCleaningModeEnabled() {
                    if type == .keyDown,
                       let shortcut = KeyboardShortcuts.getShortcut(for: .toggleCleaningMode),
                       let shortcutKey = shortcut.key {
                        let relevantFlags: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
                        let eventModifiers = event.flags.intersection(relevantFlags)
                        let shortcutModifiers = CGEventFlags(rawValue: UInt64(shortcut.modifiers.rawValue)).intersection(relevantFlags)
                        if keyCode == Int64(shortcutKey.rawValue), eventModifiers == shortcutModifiers {
                            SettingsEngine.shared.toggleCleaningMode()
                        }
                    }
                    return nil
                }
                
                // Start latency measurement
                let latencyId = startLatencyMeasurement()
                recordLatencyCheckpoint(latencyId, point: .keyEventReceived)
                
                if SettingsEngine.shared.isIgnoreRapidKeyEventsEnabled() {
                    // Ignore events that are too close to each other.
                    defer { tracker.lastEventTime = tracker.currentTime() }
                    let currentTimestamp = tracker.currentTime()
                    let elapsedTime = currentTimestamp - tracker.lastEventTime
                    if elapsedTime <= 10 { return Unmanaged.passUnretained(event) }
                }
                
                // Mute sound if music is playing and custom setting is enabled
                if AudioMonitor.shared.isMusicAppPlaying && SettingsEngine.shared.isAutoMuteOnMusicPlaybackEnabled() {
                    return Unmanaged.passUnretained(event)
                }
                
                let soundAction: (keyCode: Int64, isKeyDown: Bool)?
                switch type {
                case .keyDown where !tracker.pressedKeys.contains(keyCode):
                    tracker.pressedKeys.insert(keyCode)
                    soundAction = (keyCode, true)
                    
                case .keyUp:
                    tracker.pressedKeys.remove(keyCode)
                    soundAction = (keyCode, false)
                    
                case .flagsChanged:
                    // Respect the user setting to ignore modifier key sounds
                    if !SettingsEngine.shared.isModifierKeySoundDisabled() {
                        if tracker.pressedKeys.remove(keyCode) == nil {
                            tracker.pressedKeys.insert(keyCode)
                            soundAction = (keyCode, true)
                        } else {
                            soundAction = (keyCode, false)
                        }
                    } else {
                        soundAction = nil
                    }
                    
                default:
                    soundAction = nil
                }
                
                if let action = soundAction {
                    DispatchQueue.global(qos: .userInteractive).async {
                        SoundEngine.shared.play(for: action.keyCode, isKeyDown: action.isKeyDown, latencyId: latencyId)
                    }
                }
                
                return Unmanaged.passUnretained(event)
            },
            userInfo: observer
        )
        if let eventMonitor = eventMonitor {
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventMonitor, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventMonitor, enable: true)
            startWatchdog()
        } else {
            print("Failed to create event tap.")
        }
    }
    
    /// Re-enables the event tap after macOS disabled it and clears stale key state.
    private func reenableTap() {
        guard let eventMonitor = eventMonitor else { return }
        pressedKeys.removeAll()
        CGEvent.tapEnable(tap: eventMonitor, enable: true)
    }
    
    /// Periodically verifies the tap is still enabled, as a safety net for cases
    /// where the disable notification is never delivered.
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self, let eventMonitor = self.eventMonitor else { return }
            if !CGEvent.tapIsEnabled(tap: eventMonitor) {
                self.reenableTap()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }
    
    /// Stops tracking key events and removes the event tap.
    func stopTracking() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if let eventMonitor = eventMonitor {
            CFMachPortInvalidate(eventMonitor)
            self.eventMonitor = nil
        }
    }
    
    // MARK: Private methods
    
    private func currentTime() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }
}
