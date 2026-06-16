import Foundation
import CoreGraphics
import ApplicationServices
import os

public final class EventSynthesizer: @unchecked Sendable {
    private let eventSource = CGEventSource(stateID: .combinedSessionState)
    private var lastMidiValues = [Int: Int]() // Stores the last MIDI value for absolute encoders, keyed by MIDI number
    private let eventQueue = DispatchQueue(label: "com.loupedeck.eventQueue", qos: .userInteractive)
    
    // Track currently simulated pressed modifiers
    private var activeModifiers = Set<ModifierKey>()
    private var modifierReleaseWorkItem: DispatchWorkItem?
    
    public init() {}
    
    deinit {
        // Release any active modifiers on deinit to prevent stuck keys
        let modifiersToClean = activeModifiers
        if !modifiersToClean.isEmpty {
            if let eventSource = CGEventSource(stateID: .combinedSessionState) {
                for modifier in modifiersToClean {
                    let keyCode: UInt16
                    switch modifier {
                    case .command: keyCode = 55
                    case .shift: keyCode = 56
                    case .option: keyCode = 58
                    case .control: keyCode = 59
                    }
                    if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(keyCode), keyDown: false) {
                        event.post(tap: .cghidEventTap)
                    }
                }
            }
        }
    }
    
    /// Checks if the process has macOS Accessibility Permissions.
    public static func hasAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }
    
    /// Requests macOS Accessibility Permissions by showing a system prompt.
    public static func requestAccessibilityPermissions() {
        let options = ["AXTrustedCheckOptionPrompt" as CFString: kCFBooleanTrue as Any] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    
    private func currentFlags() -> CGEventFlags {
        var flags = CGEventFlags()
        for modifier in activeModifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            }
        }
        return flags
    }
    
    private func postModifier(_ modifier: ModifierKey, keyDown: Bool, flags: CGEventFlags, eventSource: CGEventSource) {
        let keyCode: UInt16
        switch modifier {
        case .command: keyCode = 55
        case .shift: keyCode = 56
        case .option: keyCode = 58
        case .control: keyCode = 59
        }
        if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(keyCode), keyDown: keyDown) {
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
    
    /// Simulates a single keystroke event (down and up) with modifier keys.
    public func simulateKeystroke(keyCode: UInt16, modifiers: [ModifierKey]?) {
        eventQueue.async { [weak self] in
            guard let self = self, let eventSource = self.eventSource else {
                Logger.midi.error("Error: Failed to create event source")
                return
            }
            
            let targetModifiers = Set(modifiers ?? [])
            
            // Cancel any pending release work item because we are active
            self.modifierReleaseWorkItem?.cancel()
            self.modifierReleaseWorkItem = nil
            
            var stateChanged = false
            
            // 1. Release active modifiers that are not in target modifiers
            let modifiersToRelease = self.activeModifiers.subtracting(targetModifiers)
            if !modifiersToRelease.isEmpty {
                for modifier in modifiersToRelease {
                    self.activeModifiers.remove(modifier)
                    let flags = self.currentFlags()
                    self.postModifier(modifier, keyDown: false, flags: flags, eventSource: eventSource)
                    usleep(2000) // 2ms delay between modifiers
                }
                stateChanged = true
            }
            
            // 2. Press target modifiers that are not currently active
            let modifiersToPress = targetModifiers.subtracting(self.activeModifiers)
            if !modifiersToPress.isEmpty {
                for modifier in modifiersToPress {
                    self.activeModifiers.insert(modifier)
                    let flags = self.currentFlags()
                    self.postModifier(modifier, keyDown: true, flags: flags, eventSource: eventSource)
                    usleep(2000) // 2ms delay between modifiers
                }
                stateChanged = true
            }
            
            // Delay to let the OS register the new modifier state if it has changed
            if stateChanged {
                usleep(5000) // 5ms delay
            }
            
            // Create target key down and up events
            guard let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(keyCode), keyDown: true),
                  let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
                Logger.midi.error("Error: Failed to create keyboard events for keycode \(keyCode)")
                return
            }
            
            // Build flags for all target modifiers
            var flags = keyDownEvent.flags
            for modifier in targetModifiers {
                switch modifier {
                case .command:
                    flags.insert(.maskCommand)
                case .shift:
                    flags.insert(.maskShift)
                case .option:
                    flags.insert(.maskAlternate)
                case .control:
                    flags.insert(.maskControl)
                }
            }
            keyDownEvent.flags = flags
            keyUpEvent.flags = flags
            
            // Post target key down
            keyDownEvent.post(tap: .cghidEventTap)
            usleep(5000) // 5ms delay for key hold time
            
            // Post target key up
            keyUpEvent.post(tap: .cghidEventTap)
            usleep(10000) // 10ms quiet period after release to let the OS register the key release
            
            // 3. Schedule releasing all active modifiers after 100ms of inactivity
            if !self.activeModifiers.isEmpty {
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self, let eventSource = self.eventSource else { return }
                    let modifiersToRelease = self.activeModifiers
                    for modifier in modifiersToRelease {
                        self.activeModifiers.remove(modifier)
                        let flags = self.currentFlags()
                        self.postModifier(modifier, keyDown: false, flags: flags, eventSource: eventSource)
                        usleep(2000) // 2ms delay between modifiers
                    }
                }
                self.modifierReleaseWorkItem = workItem
                self.eventQueue.asyncAfter(deadline: .now() + 0.1, execute: workItem)
            }
            
            Logger.midi.info("Simulated Keystroke: KeyCode \(keyCode), Modifiers: \(modifiers?.map { $0.rawValue }.joined(separator: "+") ?? "None")")
        }
    }
    
    /// Simulates "Speed Edit" behavior by holding a key down, performing a scroll wheel tick, and releasing the key.
    public func simulateSpeedEditScroll(keyCode: UInt16, midiNumber: Int, midiValue: Int, relativeMode: RelativeMode) {
        eventQueue.async { [weak self] in
            guard let self = self, let eventSource = self.eventSource else {
                Logger.midi.error("Error: Failed to create event source")
                return
            }
            
            let delta = self.calculateDelta(midiNumber: midiNumber, midiValue: midiValue, mode: relativeMode)
            guard delta != 0 else { return } // No scroll movement needed
            
            // Create key down, scroll, and key up events
            guard let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(keyCode), keyDown: true),
                  let scrollEvent = CGEvent(scrollWheelEvent2Source: eventSource, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0),
                  let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
                Logger.midi.error("Error: Failed to create events for Speed Edit Scroll (keycode \(keyCode))")
                return
            }
            
            // Post events in sequence with a small delay to allow Capture One to capture state
            keyDownEvent.post(tap: .cghidEventTap)
            usleep(5000) // 5ms delay
            scrollEvent.post(tap: .cghidEventTap)
            usleep(5000) // 5ms delay
            keyUpEvent.post(tap: .cghidEventTap)
            
            Logger.midi.info("Simulated Speed Edit Scroll: KeyCode \(keyCode) with scroll delta \(delta) (MIDI value: \(midiValue))")
        }
    }
    
    /// Helper to convert raw MIDI values (0-127) to discrete scroll wheel ticks based on the configured mode.
    private func calculateDelta(midiNumber: Int, midiValue: Int, mode: RelativeMode) -> Int32 {
        switch mode {
        case .twosComplement:
            // Standard two's complement relative mode
            // 1 to 63: clockwise/positive. 127 to 65: counter-clockwise/negative.
            if midiValue >= 1 && midiValue <= 63 {
                return Int32(midiValue)
            } else if midiValue >= 65 && midiValue <= 127 {
                return Int32(midiValue - 128)
            } else {
                return 0 // Neutral / 64
            }
            
        case .binaryOffset:
            // Centered offset mode: 64 is neutral, > 64 is positive, < 64 is negative
            return Int32(midiValue) - 64
            
        case .absolute:
            // Slider/fader absolute mode: calculate delta based on previous value
            let lastValue = lastMidiValues[midiNumber] ?? midiValue
            lastMidiValues[midiNumber] = midiValue
            let rawDelta = midiValue - lastValue
            
            // Limit delta to standard small scroll ticks
            if rawDelta > 0 {
                return 1
            } else if rawDelta < 0 {
                return -1
            } else {
                return 0
            }
            
        case .auto:
            // Auto mode: default to twosComplement behaviour but fallback to binaryOffset if value is exactly 64
            if midiValue == 64 {
                return 0
            } else if midiValue >= 1 && midiValue <= 63 {
                return Int32(midiValue)
            } else if midiValue >= 65 && midiValue <= 127 {
                return Int32(midiValue - 128)
            } else {
                return 0
            }
        }
    }
}
