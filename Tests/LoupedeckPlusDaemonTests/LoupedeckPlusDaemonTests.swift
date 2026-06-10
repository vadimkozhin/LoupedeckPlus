import XCTest
import CoreGraphics
import Foundation
@testable import LoupedeckPlusDaemon

final class LoupedeckPlusDaemonTests: XCTestCase {
    func testModifierKeyParsing() throws {
        let jsonString = """
        {
            "midiMatch": "B0 22 7F",
            "keyCode": 40,
            "modifiers": [
                "control",
                "option",
                "shift"
            ]
        }
        """
        
        let data = jsonString.data(using: .utf8)!
        let decoder = JSONDecoder()
        let action = try decoder.decode(KeyAction.self, from: data)
        
        XCTAssertEqual(action.keyCode, 40)
        XCTAssertNotNil(action.modifiers)
        XCTAssertEqual(action.modifiers?.count, 3)
        XCTAssertTrue(action.modifiers?.contains(.control) == true)
        XCTAssertTrue(action.modifiers?.contains(.option) == true)
        XCTAssertTrue(action.modifiers?.contains(.shift) == true)
    }

    func testCGEventFlagsTranslation() throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)!
        
        var flags = e.flags
        let modifiers: [ModifierKey] = [.control, .option, .shift]
        for modifier in modifiers {
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
        
        XCTAssertTrue(flags.contains(.maskControl))
        XCTAssertTrue(flags.contains(.maskAlternate))
        XCTAssertTrue(flags.contains(.maskShift))
        XCTAssertFalse(flags.contains(.maskCommand))
        // Verify default flags (like maskNonCoalesced) are preserved
        XCTAssertTrue(flags.contains(.maskNonCoalesced))
    }

    func testConfigLoading() throws {
        let jsonString = """
        {
            "targetBundleIdentifier": "com.apple.dt.Xcode",
            "hotkeys": true,
            "apple_script": false,
            "lightroom_socket": true,
            "customModeButton": {
                "press": {
                    "midiMatch": "90 75 40",
                    "action": "toggle_mode"
                }
            },
            "knobs": [
                {
                    "comment": "Exposure",
                    "plus": { "midiMatch": "B0 21 01", "keyCode": 44 },
                    "minus": { "midiMatch": "B0 21 7F", "keyCode": 43 }
                }
            ],
            "buttons": [
                {
                    "comment": "Undo",
                    "press": { "midiMatch": "90 5F 40", "keyCode": 6, "modifiers": ["command"] }
                }
            ]
        }
        """
        
        let data = jsonString.data(using: .utf8)!
        let decoder = JSONDecoder()
        let config = try decoder.decode(Config.self, from: data)
        
        XCTAssertEqual(config.targetBundleIdentifier, "com.apple.dt.Xcode")
        XCTAssertEqual(config.hotkeys, true)
        XCTAssertEqual(config.apple_script, false)
        XCTAssertEqual(config.lightroom_socket, true)
        XCTAssertNotNil(config.customModeButton)
        XCTAssertEqual(config.knobs?.count, 1)
        XCTAssertEqual(config.buttons?.count, 1)
        
        XCTAssertEqual(config.knobs?[0].comment, "Exposure")
        XCTAssertEqual(config.knobs?[0].plus?.keyCode, 44)
        XCTAssertEqual(config.buttons?[0].comment, "Undo")
        XCTAssertEqual(config.buttons?[0].press?.modifiers?.first, .command)
    }
    
    func testAppVersionFormat() throws {
        let version = Config.appVersion
        let pattern = "^\\d+\\.\\d+\\.\\d+$"
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: version.utf16.count)
        let matches = regex.matches(in: version, options: [], range: range)
        XCTAssertEqual(matches.count, 1, "App version \(version) does not match expected semver format x.y.z")
    }
}


