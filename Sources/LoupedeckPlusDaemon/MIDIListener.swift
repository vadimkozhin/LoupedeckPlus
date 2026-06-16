import Foundation
import CoreMIDI
import os.lock
import os

public final class MIDIListener: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    
    private let workspaceMonitor: WorkspaceMonitor
    private let eventSynthesizer: EventSynthesizer
    private var config: Config
    private let scriptManager: ScriptManager
    private let scriptQueue = DispatchQueue(label: "com.loupedeck.scriptQueue", qos: .userInitiated)
    var isCustomModeActive = false
    private var activeColorMode = "HUE"
    private var pendingReinitWorkItem: DispatchWorkItem?
    var isFnPressed = false
    var fnPressAction: KeyAction?
    var fnReleaseAction: KeyAction?
    
    private var normalCache = [UInt16: [MatchedMapping]]()
    private var normalFnCache = [UInt16: [MatchedMapping]]()
    private var customCache = [UInt16: [MatchedMapping]]()
    private var customFnCache = [UInt16: [MatchedMapping]]()
    
    private var _globalOverride = false
    public var globalOverride: Bool {
        get {
            os_unfair_lock_lock(&lock)
            let val = _globalOverride
            os_unfair_lock_unlock(&lock)
            return val
        }
        set {
            os_unfair_lock_lock(&lock)
            _globalOverride = newValue
            os_unfair_lock_unlock(&lock)
        }
    }
    
    private var _isKeyboardConnected = false
    private var _keyboardSerialNumber: String? = nil
    
    public var isKeyboardConnected: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _isKeyboardConnected
    }
    
    public var keyboardSerialNumber: String? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _keyboardSerialNumber
    }
    
    private var lock = os_unfair_lock()
    private var sourceNames: [MIDIEndpointRef: String] = [:]
    private var lastStatus: UInt8 = 0
    private var lastData1: UInt8 = 0
    private var lastData2: UInt8 = 0
    private var lastEventTime: Double = 0.0
    private var lastSource: MIDIEndpointRef = 0
    
    public init(config: Config, workspaceMonitor: WorkspaceMonitor, eventSynthesizer: EventSynthesizer, scriptManager: ScriptManager) {
        self.config = config
        self.workspaceMonitor = workspaceMonitor
        self.eventSynthesizer = eventSynthesizer
        self.scriptManager = scriptManager
        
        // Scan for Fn button press and release actions
        var foundPress: KeyAction?
        var foundRelease: KeyAction?
        if let buttons = config.buttons {
            for button in buttons {
                for action in [button.press, button.release, button.cmPress, button.cmRelease] {
                    if let act = action {
                        if act.action == "fn_press" {
                            foundPress = act
                        } else if act.action == "fn_release" {
                            foundRelease = act
                        }
                    }
                }
            }
        }
        if foundPress == nil {
            foundPress = KeyAction(
                midiMatch: "90 6E *",
                keyCode: nil,
                modifiers: nil,
                action: "fn_press",
                relativeMode: nil,
                socketCommand: nil
            )
        }
        if foundRelease == nil {
            foundRelease = KeyAction(
                midiMatch: "80 6E *",
                keyCode: nil,
                modifiers: nil,
                action: "fn_release",
                relativeMode: nil,
                socketCommand: nil
            )
        }
        self.fnPressAction = foundPress
        self.fnReleaseAction = foundRelease
        
        setupMIDI()
        compileLookupCaches(with: config)
    }
    
    private func setupMIDI() {
        // Create the MIDI Client.
        // We observe system MIDI changes (like device connections/disconnections) in the notification block.
        var status = MIDIClientCreateWithBlock("LoupedeckMIDIClient" as CFString, &client) { [weak self] notificationPtr in
            guard let self = self else { return }
            let msg = notificationPtr.pointee
            if msg.messageID == .msgObjectAdded || msg.messageID == .msgObjectRemoved {
                self.queueReinitialization()
            }
        }
        
        guard status == noErr else {
            Logger.midi.error("Error creating MIDI client: \(status)")
            return
        }
        
        // Create the MIDI Input Port.
        // Inside the callback, we process incoming MIDI packets in a high-priority system thread.
        status = MIDIInputPortCreateWithBlock(client, "LoupedeckMIDIInputPort" as CFString, &inputPort) { [weak self] packetListPtr, srcConnRefCon in
            guard let self = self else { return }
            
            // Wrap in autoreleasepool to prevent memory buildup in the high-frequency MIDI thread
            autoreleasepool {
                self.processPacketList(packetListPtr, srcConnRefCon: srcConnRefCon)
            }
        }
        
        guard status == noErr else {
            Logger.midi.error("Error creating MIDI input port: \(status)")
            return
        }
        
        // Create the MIDI Output Port.
        status = MIDIOutputPortCreate(client, "LoupedeckMIDIOutputPort" as CFString, &outputPort)
        guard status == noErr else {
            Logger.midi.error("Error creating MIDI output port: \(status)")
            return
        }
        
        // Initial connection to all available MIDI sources
        connectAllSources()
        
        // Send initialization sequence to Loupedeck destinations
        initializeLoupedeckDevices()
    }
    
    /// Scans all system MIDI sources and connects them to our input port.
    private func connectAllSources() {
        let sourceCount = MIDIGetNumberOfSources()
        Logger.midi.info("Found \(sourceCount) MIDI source(s)")
        
        os_unfair_lock_lock(&lock)
        sourceNames.removeAll()
        os_unfair_lock_unlock(&lock)
        
        var hasLoupedeck = false
        for i in 0..<sourceCount {
            let source = MIDIGetSource(i)
            
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(source, kMIDIPropertyName, &name)
            let cfName = name?.takeRetainedValue()
            let sourceName = (cfName as String?) ?? "Unknown Device"
            if sourceName.lowercased().contains("loupedeck") {
                hasLoupedeck = true
            }
            
            os_unfair_lock_lock(&lock)
            sourceNames[source] = sourceName
            os_unfair_lock_unlock(&lock)
            
            // Connect this source to our input port. Pass the source Ref as the connection refCon.
            let connectStatus = MIDIPortConnectSource(
                inputPort,
                source,
                UnsafeMutableRawPointer(bitPattern: Int(source))
            )
            if connectStatus == noErr {
                Logger.midi.info("Successfully connected to source: \(sourceName, privacy: .public) (ID: \(source))")
            } else {
                Logger.midi.error("Failed to connect to source \(sourceName, privacy: .public) at index \(i), status: \(connectStatus)")
            }
        }
        
        let currentSerial = self.keyboardSerialNumber
        updateConnectionState(isConnected: hasLoupedeck, serial: hasLoupedeck ? currentSerial : nil)
    }
    
    private func updateConnectionState(isConnected: Bool, serial: String?) {
        var changed = false
        os_unfair_lock_lock(&lock)
        if _isKeyboardConnected != isConnected || _keyboardSerialNumber != serial {
            _isKeyboardConnected = isConnected
            _keyboardSerialNumber = isConnected ? serial : nil
            changed = true
        }
        os_unfair_lock_unlock(&lock)
        
        if changed {
            let serialCopy = isConnected ? serial : nil
            Logger.midi.info("Connection state changed: isConnected=\(isConnected), serial=\(serialCopy ?? "nil", privacy: .public)")
            DispatchQueue.main.async {
                ConfigurationWindowController.shared.updateDeviceStatus(isConnected: isConnected, serialNumber: serialCopy)
            }
        }
    }
    
    /// Parses the CoreMIDI packet list and processes individual MIDI events.
    private func processPacketList(_ packetListPtr: UnsafePointer<MIDIPacketList>, srcConnRefCon: UnsafeMutableRawPointer?) {
        let source = MIDIEndpointRef(Int(bitPattern: srcConnRefCon))
        // Retrieve the offset of the first packet in the packet list.
        guard let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet) else {
            Logger.midi.error("Internal error: Could not determine packet offset")
            return
        }
        
        var packetPtr = UnsafeRawPointer(packetListPtr).advanced(by: packetOffset).assumingMemoryBound(to: MIDIPacket.self)
        let numPackets = packetListPtr.pointee.numPackets
        
        for _ in 0..<numPackets {
            let packet = packetPtr.pointee
            let length = Int(packet.length)
            
            if length > 0 {
                withUnsafePointer(to: packet.data) { dataTuplePtr in
                    let rawPtr = UnsafeRawPointer(dataTuplePtr)
                    let bytes = rawPtr.assumingMemoryBound(to: UInt8.self)
                    
                    var i = 0
                    while i < length {
                        let status = bytes[i]
                        
                        // We check if this is a valid status byte (MSB is 1)
                        if status >= 0x80 {
                            let messageType = status & 0xF0
                            
                            // 3-Byte Messages: Note On (0x90), Note Off (0x80), Control Change (0xB0), Polyphonic Pressure (0xA0), Pitch Bend (0xE0)
                            if messageType == 0x90 || messageType == 0x80 || messageType == 0xB0 || messageType == 0xA0 || messageType == 0xE0 {
                                if i + 2 < length {
                                    let data1 = bytes[i + 1]
                                    let data2 = bytes[i + 2]
                                    
                                    handleRawMIDIMessage(status: status, data1: data1, data2: data2, source: source)
                                    i += 3
                                } else {
                                    // Incomplete packet data, abort parsing this packet
                                    break
                                }
                            } else if messageType == 0xC0 || messageType == 0xD0 {
                                // 2-Byte Messages (e.g. Program Change, Channel Pressure)
                                i += 2
                            } else if messageType == 0xF0 {
                                // System Exclusive / Realtime message handling
                                if status == 0xF0 {
                                    var sysexBytes = [UInt8]()
                                    while i < length {
                                        let b = bytes[i]
                                        sysexBytes.append(b)
                                        i += 1
                                        if b == 0xF7 {
                                            break
                                        }
                                    }
                                    handleSysExMessage(sysexBytes)
                                } else {
                                    // System Realtime is 1 byte
                                    i += 1
                                }
                            } else {
                                i += 1
                            }
                        } else {
                            // Skip invalid bytes
                            i += 1
                        }
                    }
                }
            }
            
            // Advance to the next packet using CoreMIDI's helper
            packetPtr = UnsafePointer(MIDIPacketNext(packetPtr))
        }
    }
    
    struct MatchedMapping {
        let action: KeyAction
        let comment: String
        let defaultValue: Double?
    }
    
    private func compileLookupCaches(with newConfig: Config) {
        var normal = [UInt16: [MatchedMapping]]()
        var normalFn = [UInt16: [MatchedMapping]]()
        var custom = [UInt16: [MatchedMapping]]()
        var customFn = [UInt16: [MatchedMapping]]()
        
        func addToCache(_ action: KeyAction?, comment: String, defaultValue: Double?, cache: inout [UInt16: [MatchedMapping]]) {
            guard let action = action, let matchers = action.parsedMatchers, matchers.count >= 2 else { return }
            
            let statusByte: UInt8
            switch matchers[0] {
            case .exact(let val): statusByte = val
            default: return
            }
            
            let data1Byte: UInt8
            switch matchers[1] {
            case .exact(let val): data1Byte = val
            default: return
            }
            
            let key = (UInt16(statusByte) << 8) | UInt16(data1Byte)
            let mapping = MatchedMapping(action: action, comment: comment, defaultValue: defaultValue)
            cache[key, default: []].append(mapping)
        }
        
        if let knobs = newConfig.knobs {
            for knob in knobs {
                let defaultComment = knob.comment ?? "Knob"
                addToCache(knob.plus, comment: "\(defaultComment) Plus", defaultValue: knob.defaultValue, cache: &normal)
                addToCache(knob.minus, comment: "\(defaultComment) Minus", defaultValue: knob.defaultValue, cache: &normal)
                addToCache(knob.press, comment: "\(defaultComment) Press", defaultValue: knob.defaultValue, cache: &normal)
                addToCache(knob.release, comment: "\(defaultComment) Release", defaultValue: knob.defaultValue, cache: &normal)
                
                addToCache(knob.fnPlus, comment: "\(defaultComment) Fn Plus", defaultValue: knob.defaultValue, cache: &normalFn)
                addToCache(knob.fnMinus, comment: "\(defaultComment) Fn Minus", defaultValue: knob.defaultValue, cache: &normalFn)
                addToCache(knob.fnPress, comment: "\(defaultComment) Fn Press", defaultValue: knob.defaultValue, cache: &normalFn)
                addToCache(knob.fnRelease, comment: "\(defaultComment) Fn Release", defaultValue: knob.defaultValue, cache: &normalFn)
                
                addToCache(knob.cmPlus, comment: "\(defaultComment) CM Plus", defaultValue: knob.defaultValue, cache: &custom)
                addToCache(knob.cmMinus, comment: "\(defaultComment) CM Minus", defaultValue: knob.defaultValue, cache: &custom)
                addToCache(knob.cmPress, comment: "\(defaultComment) CM Press", defaultValue: knob.defaultValue, cache: &custom)
                addToCache(knob.cmRelease, comment: "\(defaultComment) CM Release", defaultValue: knob.defaultValue, cache: &custom)
                
                addToCache(knob.cmFnPlus, comment: "\(defaultComment) CM Fn Plus", defaultValue: knob.defaultValue, cache: &customFn)
                addToCache(knob.cmFnMinus, comment: "\(defaultComment) CM Fn Minus", defaultValue: knob.defaultValue, cache: &customFn)
                addToCache(knob.cmFnPress, comment: "\(defaultComment) CM Fn Press", defaultValue: knob.defaultValue, cache: &customFn)
                addToCache(knob.cmFnRelease, comment: "\(defaultComment) CM Fn Release", defaultValue: knob.defaultValue, cache: &customFn)
            }
        }
        
        if let buttons = newConfig.buttons {
            for button in buttons {
                let defaultComment = button.comment ?? "Button"
                addToCache(button.press, comment: "\(defaultComment) Press", defaultValue: nil, cache: &normal)
                addToCache(button.release, comment: "\(defaultComment) Release", defaultValue: nil, cache: &normal)
                
                addToCache(button.fnPress, comment: "\(defaultComment) Fn Press", defaultValue: nil, cache: &normalFn)
                addToCache(button.fnRelease, comment: "\(defaultComment) Fn Release", defaultValue: nil, cache: &normalFn)
                
                addToCache(button.cmPress, comment: "\(defaultComment) CM Press", defaultValue: nil, cache: &custom)
                addToCache(button.cmRelease, comment: "\(defaultComment) CM Release", defaultValue: nil, cache: &custom)
                
                addToCache(button.cmFnPress, comment: "\(defaultComment) CM Fn Press", defaultValue: nil, cache: &customFn)
                addToCache(button.cmFnRelease, comment: "\(defaultComment) CM Fn Release", defaultValue: nil, cache: &customFn)
            }
        }
        
        os_unfair_lock_lock(&lock)
        self.normalCache = normal
        self.normalFnCache = normalFn
        self.customCache = custom
        self.customFnCache = customFn
        os_unfair_lock_unlock(&lock)
    }

    /// Finds a matching configuration mapping for the incoming MIDI event.
    func findMatchingAction(status: UInt8, data1: UInt8, data2: UInt8) -> MatchedMapping? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        // 1. Check Fn button press/release directly to ensure we toggle the modifier state properly
        if let fnPress = fnPressAction, fnPress.matches(status: status, data1: data1, data2: data2) {
            return MatchedMapping(action: fnPress, comment: "Fn Button Press", defaultValue: nil)
        }
        if let fnRelease = fnReleaseAction, fnRelease.matches(status: status, data1: data1, data2: data2) {
            return MatchedMapping(action: fnRelease, comment: "Fn Button Release", defaultValue: nil)
        }

        // 2. Check Custom Mode button
        if let customModeBtn = config.customModeButton {
            if let press = customModeBtn.press, press.matches(status: status, data1: data1, data2: data2) {
                return MatchedMapping(action: press, comment: customModeBtn.comment ?? "Custom Mode Button", defaultValue: nil)
            }
            if let release = customModeBtn.release, release.matches(status: status, data1: data1, data2: data2) {
                return MatchedMapping(action: release, comment: customModeBtn.comment ?? "Custom Mode Button", defaultValue: nil)
            }
        }
        
        let key = (UInt16(status) << 8) | UInt16(data1)
        let candidates: [MatchedMapping]
        
        if isCustomModeActive {
            candidates = isFnPressed ? (customFnCache[key] ?? []) : (customCache[key] ?? [])
        } else {
            candidates = isFnPressed ? (normalFnCache[key] ?? []) : (normalCache[key] ?? [])
        }
        
        for candidate in candidates {
            if candidate.action.matches(status: status, data1: data1, data2: data2) {
                return candidate
            }
        }
        
        return nil
    }
    
    /// Matches raw MIDI status and data bytes against configuration rules and generates events.
    private func handleRawMIDIMessage(status: UInt8, data1: UInt8, data2: UInt8, source: MIDIEndpointRef) {
        // Drop standard MIDI control messages instantly if the target application is not active
        guard globalOverride || workspaceMonitor.isTargetActive else { return }
        
        // Intercept mode buttons to ensure activeColorMode matches
        // Hue button: note number 0x62 (98)
        // Sat button: note number 0x63 (99)
        // Lum button: note number 0x64 (100)
        let msgType = status & 0xF0
        if msgType == 0x90 { // Note On (press)
            os_unfair_lock_lock(&lock)
            if data1 == 0x62 {
                activeColorMode = "HUE"
                Logger.midi.info("Mode Button pressed: HUE")
            } else if data1 == 0x63 {
                activeColorMode = "SAT"
                Logger.midi.info("Mode Button pressed: SAT")
            } else if data1 == 0x64 {
                activeColorMode = "LUM"
                Logger.midi.info("Mode Button pressed: LUM")
            }
            os_unfair_lock_unlock(&lock)
        }
        
        // Find matching mapping first
        guard let matched = findMatchingAction(status: status, data1: data1, data2: data2) else {
            // Log that nothing is mapped for this MIDI control, but debounce it to avoid console flooding during rotations
            let isDuplicate: Bool
            let currentTime = ProcessInfo.processInfo.systemUptime
            
            os_unfair_lock_lock(&lock)
            if status == lastStatus && data1 == lastData1 && data2 == lastData2 {
                let timeDiff = currentTime - lastEventTime
                if source != lastSource {
                    isDuplicate = (timeDiff < 0.5)
                } else {
                    isDuplicate = (timeDiff < 0.02)
                }
            } else {
                isDuplicate = false
            }
            
            if !isDuplicate {
                lastStatus = status
                lastData1 = data1
                lastData2 = data2
                lastSource = source
                lastEventTime = currentTime
            }
            os_unfair_lock_unlock(&lock)
            
            if !isDuplicate {
                let modeStr: String
                os_unfair_lock_lock(&lock)
                let custom = isCustomModeActive
                let fn = isFnPressed
                os_unfair_lock_unlock(&lock)
                if custom {
                    modeStr = fn ? "Custom Mode (Fn active)" : "Custom Mode"
                } else {
                    modeStr = fn ? "Normal Mode (Fn active)" : "Normal Mode"
                }
                Logger.midi.info("No action mapped for MIDI control in \(modeStr, privacy: .public) (\(String(format: "%02X %02X %02X", status, data1, data2), privacy: .public))")
            }
            return
        }
        
        // Prevent duplicate execution from mirrored virtual ports (e.g. MidiView and Loupedeck+)
        let currentTime = ProcessInfo.processInfo.systemUptime
        
        os_unfair_lock_lock(&lock)
        let isDuplicate: Bool
        if status == lastStatus && data1 == lastData1 && data2 == lastData2 {
            let timeDiff = currentTime - lastEventTime
            if source != lastSource {
                // Duplicate from a different source (e.g. mirrored virtual port).
                // Use a wider window (0.5 seconds) to filter out mirrored echoes.
                isDuplicate = (timeDiff < 0.5)
            } else {
                // Same source. Standard debounce of 20ms.
                isDuplicate = (timeDiff < 0.02)
            }
        } else {
            isDuplicate = false
        }
        
        if !isDuplicate {
            lastStatus = status
            lastData1 = data1
            lastData2 = data2
            lastSource = source
            lastEventTime = currentTime
        }
        
        let sourceName = sourceNames[source] ?? "Unknown Source"
        os_unfair_lock_unlock(&lock)
        
        if isDuplicate {
            Logger.midi.debug("Suppressed duplicate event (\(String(format: "%02X %02X %02X", status, data1, data2), privacy: .public)) from source: \(sourceName, privacy: .public)")
            return
        }

        // Special case: Custom Mode button toggling logic
        os_unfair_lock_lock(&lock)
        let customModeBtn = config.customModeButton
        os_unfair_lock_unlock(&lock)
        if let btn = customModeBtn {
            if let press = btn.press, press.matches(status: status, data1: data1, data2: data2) {
                // Latching toggle behavior: toggle the state on press
                os_unfair_lock_lock(&lock)
                isCustomModeActive = !isCustomModeActive
                let active = isCustomModeActive
                os_unfair_lock_unlock(&lock)
                Logger.midi.info("Custom Mode toggled to: \(active ? "ENABLED" : "DISABLED")")
                
                // Mimic captured MIDI feedback: B1 01 7F when ON, B1 01 00 when OFF
                let feedbackVal: UInt8 = active ? 0x7F : 0x00
                sendMIDIToAllLoupedecks([0xB1, 0x01, feedbackVal])
            }
        }
        
        // Special case: Fn Button press/release state tracking
        if let actionName = matched.action.action {
            if actionName == "fn_press" {
                os_unfair_lock_lock(&lock)
                isFnPressed = true
                os_unfair_lock_unlock(&lock)
                Logger.midi.info("Fn modifier ACTIVE")
            } else if actionName == "fn_release" {
                os_unfair_lock_lock(&lock)
                isFnPressed = false
                os_unfair_lock_unlock(&lock)
                Logger.midi.info("Fn modifier INACTIVE")
            }
        }
        
        // Execute the matched action
        executeAction(matched.action, status: status, data1: data1, data2: data2, defaultValue: matched.defaultValue, comment: matched.comment)
    }
    
    /// Executes a matched KeyAction event (simulating scroll, keystroke, or triggering an AppleScript)
    private func executeAction(_ action: KeyAction, status: UInt8, data1: UInt8, data2: UInt8, defaultValue: Double? = nil, comment: String? = nil) {
        // 0. For wildcard mappings (e.g. "90 3C *"), ignore release events (velocity == 0) to prevent double triggers
        if let matchers = action.parsedMatchers, matchers.count >= 3 {
            if case .wildcard = matchers[2], data2 == 0 {
                // Skip release events (velocity == 0) for wildcard mapping
                return
            }
        }
        
        if let comment = comment {
            let valHex = String(format: "%02X %02X %02X", status, data1, data2)
            let typeStr: String
            let msgType = status & 0xF0
            if msgType == 0x80 {
                typeStr = "Release"
            } else if msgType == 0x90 {
                typeStr = "Press"
            } else if msgType == 0xB0 {
                typeStr = "Rotate"
            } else {
                typeStr = "Event"
            }
            Logger.midi.info("Action Triggered (\(typeStr, privacy: .public)): \(comment, privacy: .public) (MIDI: \(valHex, privacy: .public))")
        }
        
        if let actionName = action.action,
           actionName != "keystroke",
           !actionName.hasSuffix("_press"),
           !actionName.hasSuffix("_release"),
           !actionName.hasSuffix("_action") {
            let manager = self.scriptManager
            let appPath = self.workspaceMonitor.activeAppPath
            
            // Check if this is a color wheel reset action
            let isColorReset = actionName.hasPrefix("reset_") && 
                ["red", "orange", "yellow", "green", "cyan", "blue", "violet", "magenta"].contains(actionName.replacingOccurrences(of: "reset_", with: ""))
            
            if isColorReset {
                let colorName = actionName.replacingOccurrences(of: "reset_", with: "")
                let c1Color: String
                switch colorName {
                case "violet": c1Color = "purple"
                case "magenta": c1Color = "pink"
                default: c1Color = colorName
                }
                
                os_unfair_lock_lock(&lock)
                let currentMode = self.activeColorMode
                os_unfair_lock_unlock(&lock)
                
                let c1Property: String
                switch currentMode {
                case "SAT": c1Property = "saturation change"
                case "LUM": c1Property = "lightness change"
                default: c1Property = "hue change"
                }
                
                let scriptSource = """
                tell application "Capture One"
                	repeat with v in (get selected variants)
                		tell color editor settings of adjustments of v
                			set \(c1Property) of basic color correction "\(c1Color)" to 0.0
                		end tell
                	end repeat
                end tell
                """
                
                Logger.midi.info("Dynamically resetting \(colorName, privacy: .public) (\(c1Color, privacy: .public)) \(currentMode, privacy: .public) (\(c1Property, privacy: .public)) to 0.0")
                scriptQueue.async {
                    manager.executeCustomScript(source: scriptSource, actionName: actionName, activeAppPath: appPath)
                }
            } else {
                scriptQueue.async {
                    manager.execute(actionName: actionName, defaultValue: defaultValue, activeAppPath: appPath)
                }
            }
        }
        
        // 2. Run virtual keystroke/scroll events if mapped
        if let keyCode = action.keyCode {
            eventSynthesizer.simulateKeystroke(
                keyCode: keyCode,
                modifiers: action.modifiers
            )
        }
        
        // 3. Send socket command if mapped
        if var socketCommand = action.socketCommand {
            let defVal = defaultValue ?? 0.0
            socketCommand = socketCommand.replacingOccurrences(of: "$DEFAULT", with: String(format: "%.1f", defVal))
            LightroomSocketManager.shared.sendScript(socketCommand)
        }
    }
    
    /// Processes incoming SysEx packets and decodes state/handshake responses.
    private func handleSysExMessage(_ bytes: [UInt8]) {
        guard bytes.count >= 3, bytes.first == 0xF0, bytes.last == 0xF7 else { return }
        
        // Extract the payload bytes (excluding F0 and F7)
        let payload = bytes[1..<(bytes.count - 1)]
        
        // Convert the ASCII hex bytes into a string
        let asciiString = String(decoding: payload, as: UTF8.self)
        
        if asciiString.hasPrefix("0446") {
            let suffix = String(asciiString.dropFirst(4))
            if suffix == "0000" {
                os_unfair_lock_lock(&lock)
                activeColorMode = "HUE"
                os_unfair_lock_unlock(&lock)
                Logger.midi.info("Active Mode: HUE (Standard Mode)")
            } else if suffix == "0001" {
                os_unfair_lock_lock(&lock)
                activeColorMode = "SAT"
                os_unfair_lock_unlock(&lock)
                Logger.midi.info("Active Mode: SAT (Saturation Mode)")
            } else if suffix == "0002" {
                os_unfair_lock_lock(&lock)
                activeColorMode = "LUM"
                os_unfair_lock_unlock(&lock)
                Logger.midi.info("Active Mode: LUM (Luminance Mode)")
            } else if let buildVal = Int(suffix, radix: 16) {
                let version: String
                if buildVal == 80 {
                    version = "1.8"
                } else {
                    version = String(format: "%.1f", Double(buildVal) / 10.0)
                }
                Logger.midi.info("Hardware Detected: Loupedeck+ (Firmware Version: \(version, privacy: .public), Build: \(buildVal))")
            }
        } else if asciiString.hasPrefix("135000") {
            // Handshake response containing the serial number:
            // e.g. "135000190300162E01010B0029000000000000"
            if let decodedSerial = decodeLoupedeckSerial(asciiString) {
                Logger.midi.info("Serial Number: \(decodedSerial, privacy: .public)")
                updateConnectionState(isConnected: true, serial: decodedSerial)
            }
        }
    }
    
    /// Decodes the Loupedeck+ serial number from its ASCII handshake payload.
    func decodeLoupedeckSerial(_ hexStr: String) -> String? {
        var bytes = [UInt8]()
        let cleanStr = hexStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanStr.count % 2 == 0 else { return nil }
        
        var tempIndex = cleanStr.startIndex
        for _ in 0..<cleanStr.count/2 {
            let nextIndex = cleanStr.index(tempIndex, offsetBy: 2)
            if let byte = UInt8(cleanStr[tempIndex..<nextIndex], radix: 16) {
                bytes.append(byte)
            } else {
                return nil
            }
            tempIndex = nextIndex
        }
        
        guard bytes.count >= 13 else { return nil }
        
        guard let uL = UnicodeScalar(Int(bytes[0]) * 4),
              let uD = UnicodeScalar(Int(bytes[3]) * 4),
              let uP = UnicodeScalar(Int(bytes[1])) else { return nil }
              
        let charL = Character(uL)
        let charD = Character(uD).uppercased()
        let charP = Character(uP)
        let prefix = "\(charL)\(charD)\(charP)"
        
        let part1 = String(format: "%02d", bytes[4])
        let part2 = String(format: "%02d", bytes[5])
        let part3 = String(format: "%02d", bytes[6])
        let part4 = String(format: "%02d", bytes[7])
        let part5 = String(format: "%02d", bytes[8])
        
        let middleVal = Int(bytes[9]) * 256 + Int(bytes[10])
        let part6Padded = String(format: "%05d", middleVal)
        let hexChar = String(format: "%X", bytes[10])
        
        let part7 = String(format: "%02d", bytes[11])
        let part8 = String(format: "%02d", bytes[12])
        
        return "\(prefix)\(part1)\(part2)\(part3)\(part4)\(part5)\(part6Padded)\(hexChar)\(part7)\(part8)"
    }
    
    /// Scans for Loupedeck destination endpoints and sends the initialization sequence.
    private func initializeLoupedeckDevices() {
        let destCount = MIDIGetNumberOfDestinations()
        for i in 0..<destCount {
            let dest = MIDIGetDestination(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(dest, kMIDIPropertyName, &name)
            if let cfName = name?.takeRetainedValue() {
                let destName = cfName as String
                if destName.contains("Loupedeck") {
                    Logger.midi.info("Found Loupedeck destination: \(destName, privacy: .public) (ID: \(dest)). Sending initialization sequence...")
                    LoupedeckDeviceInitializer.run(destination: dest, sendRawBytes: { [weak self] bytes, endpoint in
                        self?.sendRawBytes(bytes, to: endpoint)
                    })
                }
            }
        }
    }
    
    /// Sends raw MIDI bytes to all active Loupedeck destinations.
    private func sendMIDIToAllLoupedecks(_ bytes: [UInt8]) {
        let destCount = MIDIGetNumberOfDestinations()
        for i in 0..<destCount {
            let dest = MIDIGetDestination(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(dest, kMIDIPropertyName, &name)
            if let cfName = name?.takeRetainedValue() {
                let destName = cfName as String
                if destName.contains("Loupedeck") {
                    sendRawBytes(bytes, to: dest)
                }
            }
        }
    }
    
    /// Queues a debounced re-initialization of MIDI sources and destinations.
    /// This prevents duplicate initialization calls when multiple notifications fire rapidly at startup.
    private func queueReinitialization() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Cancel any pending re-initialization
            self.pendingReinitWorkItem?.cancel()
            
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                Logger.midi.info("MIDI setup change stabilized. Re-scanning sources & re-initializing...")
                self.connectAllSources()
                self.initializeLoupedeckDevices()
            }
            
            self.pendingReinitWorkItem = workItem
            // Schedule the execution after 500ms on the main queue
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
    }
    
    /// Sends a raw byte list as a MIDI packet to a specific destination endpoint.
    private func sendRawBytes(_ bytes: [UInt8], to destination: MIDIEndpointRef) {
        let packetSize = bytes.count
        let bufferSize = MemoryLayout<MIDIPacketList>.size + packetSize + 100
        
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: bufferSize) { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let packetList = baseAddress.withMemoryRebound(to: MIDIPacketList.self, capacity: 1) { $0 }
            var packetPtr = MIDIPacketListInit(packetList)
            
            packetPtr = MIDIPacketListAdd(
                packetList,
                bufferSize,
                packetPtr,
                0,
                packetSize,
                bytes
            )
            
            let status = MIDISend(outputPort, destination, packetList)
            if status != noErr {
                Logger.midi.error("Error sending raw bytes to destination: \(status)")
            }
        }
    }
    
    public func updateConfig(_ newConfig: Config, globalOverride: Bool) {
        // Scan for Fn button press and release actions in the new config
        var foundPress: KeyAction?
        var foundRelease: KeyAction?
        if let buttons = newConfig.buttons {
            for button in buttons {
                for action in [button.press, button.release, button.cmPress, button.cmRelease] {
                    if let act = action {
                        if act.action == "fn_press" {
                            foundPress = act
                        } else if act.action == "fn_release" {
                            foundRelease = act
                        }
                    }
                }
            }
        }
        if foundPress == nil {
            foundPress = KeyAction(
                midiMatch: "90 6E *",
                keyCode: nil,
                modifiers: nil,
                action: "fn_press",
                relativeMode: nil,
                socketCommand: nil
            )
        }
        if foundRelease == nil {
            foundRelease = KeyAction(
                midiMatch: "80 6E *",
                keyCode: nil,
                modifiers: nil,
                action: "fn_release",
                relativeMode: nil,
                socketCommand: nil
            )
        }
        
        os_unfair_lock_lock(&lock)
        self.config = newConfig
        self._globalOverride = globalOverride
        self.fnPressAction = foundPress
        self.fnReleaseAction = foundRelease
        self.isCustomModeActive = false
        self.isFnPressed = false
        os_unfair_lock_unlock(&lock)
        
        compileLookupCaches(with: newConfig)
        Logger.midi.info("Dynamically updated configuration (Global override: \(globalOverride))")
    }
    
    deinit {
        // Clean up connections
        MIDIPortDispose(outputPort)
        MIDIPortDispose(inputPort)
        MIDIClientDispose(client)
    }
}
