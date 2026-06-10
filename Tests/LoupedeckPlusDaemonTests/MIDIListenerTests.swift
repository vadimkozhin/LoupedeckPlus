import XCTest
import Foundation
@testable import LoupedeckPlusDaemon

final class MIDIListenerTests: XCTestCase {
    var config: Config!
    var scriptManager: ScriptManager!
    var midiListener: MIDIListener!
    
    override func setUp() {
        super.setUp()
        // Setup mock Config
        let jsonString = """
        {
            "targetBundleIdentifier": "com.test.app",
            "hotkeys": true,
            "apple_script": true,
            "lightroom_socket": false,
            "customModeButton": {
                "press": { "midiMatch": "90 75 40", "action": "custom_mode_press" },
                "release": { "midiMatch": "80 75 40", "action": "custom_mode_release" }
            },
            "knobs": [
                {
                    "comment": "Exposure",
                    "plus": { "midiMatch": "B0 21 01", "keyCode": 1 },
                    "minus": { "midiMatch": "B0 21 7F", "keyCode": 2 },
                    "fn_plus": { "midiMatch": "B0 21 01", "keyCode": 3 },
                    "fn_minus": { "midiMatch": "B0 21 7F", "keyCode": 4 },
                    "cm_plus": { "midiMatch": "B0 21 01", "keyCode": 5 },
                    "cm_minus": { "midiMatch": "B0 21 7F", "keyCode": 6 },
                    "cm_fn_plus": { "midiMatch": "B0 21 01", "keyCode": 7 },
                    "cm_fn_minus": { "midiMatch": "B0 21 7F", "keyCode": 8 }
                }
            ],
            "buttons": [
                {
                    "comment": "Undo",
                    "press": { "midiMatch": "90 5F 40", "keyCode": 10 },
                    "fn_press": { "midiMatch": "90 5F 40", "keyCode": 11 },
                    "cm_press": { "midiMatch": "90 5F 40", "keyCode": 12 },
                    "cm_fn_press": { "midiMatch": "90 5F 40", "keyCode": 13 }
                }
            ]
        }
        """
        
        let data = jsonString.data(using: .utf8)!
        let decoder = JSONDecoder()
        config = try! decoder.decode(Config.self, from: data)
        
        // Setup ScriptManager with dummy scripts directory
        scriptManager = ScriptManager(targetBundleIdentifier: "com.test.app", scriptsDirectory: "/tmp/nonexistent_scripts")
        
        // Setup MIDIListener
        midiListener = MIDIListener(config: config, scriptManager: scriptManager, socketManager: nil)
    }
    
    func testLoupedeckSerialDecoding() {
        // Hex string representing array:
        // [0x1B, 0x6B, 0x00, 0x19, 0x01, 0x02, 0x03, 0x04, 0x05, 0x00, 0x0A, 0x0B, 0x0C]
        // 0x1B * 4 = 108 ('l')
        // 0x19 * 4 = 100 ('d' -> 'D')
        // 0x6B = 107 ('k')
        // prefix -> "lDk"
        let hexPayload = "1B6B00190102030405000A0B0C"
        
        let decoded = midiListener.decodeLoupedeckSerial(hexPayload)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded, "lDk010203040500010A1112")
    }
    
    func testLoupedeckSerialDecodingInvalid() {
        // Invalid length
        XCTAssertNil(midiListener.decodeLoupedeckSerial("1B6B0019"))
        // Non-hex characters
        XCTAssertNil(midiListener.decodeLoupedeckSerial("1B6B00190102030405000A0B0G"))
    }
    
    func testMIDIActionMatchingStandardMode() {
        // Standard mode: isFnPressed = false, isCustomModeActive = false
        midiListener.isFnPressed = false
        midiListener.isCustomModeActive = false
        
        // Match Exposure Knob rotation right
        let matchedPlus = midiListener.findMatchingAction(status: 0xB0, data1: 0x21, data2: 0x01)
        XCTAssertNotNil(matchedPlus)
        XCTAssertEqual(matchedPlus?.action.keyCode, 1)
        
        // Match Undo Button press
        let matchedButton = midiListener.findMatchingAction(status: 0x90, data1: 0x5F, data2: 0x40)
        XCTAssertNotNil(matchedButton)
        XCTAssertEqual(matchedButton?.action.keyCode, 10)
    }
    
    func testMIDIActionMatchingFnActive() {
        // Fn Pressed: isFnPressed = true, isCustomModeActive = false
        midiListener.isFnPressed = true
        midiListener.isCustomModeActive = false
        
        // Match Exposure Knob rotation right with Fn
        let matchedPlus = midiListener.findMatchingAction(status: 0xB0, data1: 0x21, data2: 0x01)
        XCTAssertNotNil(matchedPlus)
        XCTAssertEqual(matchedPlus?.action.keyCode, 3)
        
        // Match Undo Button press with Fn
        let matchedButton = midiListener.findMatchingAction(status: 0x90, data1: 0x5F, data2: 0x40)
        XCTAssertNotNil(matchedButton)
        XCTAssertEqual(matchedButton?.action.keyCode, 11)
    }
    
    func testMIDIActionMatchingCustomModeActive() {
        // Custom Mode: isFnPressed = false, isCustomModeActive = true
        midiListener.isFnPressed = false
        midiListener.isCustomModeActive = true
        
        // Match Exposure Knob rotation right in Custom Mode
        let matchedPlus = midiListener.findMatchingAction(status: 0xB0, data1: 0x21, data2: 0x01)
        XCTAssertNotNil(matchedPlus)
        XCTAssertEqual(matchedPlus?.action.keyCode, 5)
        
        // Match Undo Button press in Custom Mode
        let matchedButton = midiListener.findMatchingAction(status: 0x90, data1: 0x5F, data2: 0x40)
        XCTAssertNotNil(matchedButton)
        XCTAssertEqual(matchedButton?.action.keyCode, 12)
    }
    
    func testMIDIActionMatchingCustomModeAndFnActive() {
        // Custom Mode + Fn: isFnPressed = true, isCustomModeActive = true
        midiListener.isFnPressed = true
        midiListener.isCustomModeActive = true
        
        // Match Exposure Knob rotation right in Custom Mode with Fn
        let matchedPlus = midiListener.findMatchingAction(status: 0xB0, data1: 0x21, data2: 0x01)
        XCTAssertNotNil(matchedPlus)
        XCTAssertEqual(matchedPlus?.action.keyCode, 7)
        
        // Match Undo Button press in Custom Mode with Fn
        let matchedButton = midiListener.findMatchingAction(status: 0x90, data1: 0x5F, data2: 0x40)
        XCTAssertNotNil(matchedButton)
        XCTAssertEqual(matchedButton?.action.keyCode, 13)
    }
}
