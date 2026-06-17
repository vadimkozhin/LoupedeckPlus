import Foundation

public enum ModifierKey: String, Codable, Sendable {
    case command
    case shift
    case option
    case control
}

public enum RelativeMode: String, Codable, Sendable {
    case twosComplement = "twos_complement"
    case binaryOffset = "binary_offset"
    case absolute
    case auto
}

public enum ByteMatcher: Equatable {
    case exact(UInt8)
    case wildcard
}

public struct KeyAction: Codable {
    public let midiMatch: String
    public let keyCode: UInt16?
    public let modifiers: [ModifierKey]?
    public let action: String?
    public let relativeMode: RelativeMode?
    public let socketCommand: String?
    public let parsedMatchers: [ByteMatcher]?
    
    enum CodingKeys: String, CodingKey {
        case midiMatch
        case keyCode
        case modifiers
        case action
        case relativeMode
        case socketCommand
    }
    
    public init(
        midiMatch: String,
        keyCode: UInt16?,
        modifiers: [ModifierKey]?,
        action: String?,
        relativeMode: RelativeMode?,
        socketCommand: String?
    ) {
        self.midiMatch = midiMatch
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
        self.relativeMode = relativeMode
        self.socketCommand = socketCommand
        self.parsedMatchers = Self.parseMidiMatch(midiMatch)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.midiMatch = try container.decode(String.self, forKey: .midiMatch)
        self.keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
        self.modifiers = try container.decodeIfPresent([ModifierKey].self, forKey: .modifiers)
        self.action = try container.decodeIfPresent(String.self, forKey: .action)
        self.relativeMode = try container.decodeIfPresent(RelativeMode.self, forKey: .relativeMode)
        self.socketCommand = try container.decodeIfPresent(String.self, forKey: .socketCommand)
        self.parsedMatchers = Self.parseMidiMatch(self.midiMatch)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(midiMatch, forKey: .midiMatch)
        try container.encodeIfPresent(keyCode, forKey: .keyCode)
        try container.encodeIfPresent(modifiers, forKey: .modifiers)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encodeIfPresent(relativeMode, forKey: .relativeMode)
        try container.encodeIfPresent(socketCommand, forKey: .socketCommand)
    }
    
    private static func parseMidiMatch(_ midiMatch: String) -> [ByteMatcher]? {
        let components = midiMatch.lowercased()
            .split { $0.isWhitespace || $0 == ":" || $0 == "-" }
            .map { String($0) }
        
        guard !components.isEmpty else { return nil }
        
        var matchers = [ByteMatcher]()
        for comp in components {
            if comp == "*" {
                matchers.append(.wildcard)
            } else if let byte = UInt8(comp, radix: 16) {
                matchers.append(.exact(byte))
            } else {
                matchers.append(.wildcard)
            }
        }
        
        while matchers.count < 3 {
            matchers.append(.wildcard)
        }
        
        return matchers
    }
    
    /// Checks if the incoming raw MIDI status and data bytes match this action.
    public func matches(status: UInt8, data1: UInt8, data2: UInt8) -> Bool {
        guard let matchers = parsedMatchers else { return false }
        
        // Match Status
        switch matchers[0] {
        case .exact(let val): if status != val { return false }
        case .wildcard: break
        }
        
        // Match Data1
        switch matchers[1] {
        case .exact(let val): if data1 != val { return false }
        case .wildcard: break
        }
        
        // Match Data2
        switch matchers[2] {
        case .exact(let val): if data2 != val { return false }
        case .wildcard: break
        }
        
        return true
    }
}

public struct CustomModeButton: Codable {
    public let comment: String?
    public let press: KeyAction?
    public let release: KeyAction?
}

public struct KnobMapping: Codable {
    public let comment: String?
    public let defaultValue: Double?
    public let press: KeyAction?
    public let release: KeyAction?
    public let cmPress: KeyAction?
    public let cmRelease: KeyAction?
    public let plus: KeyAction?
    public let minus: KeyAction?
    public let cmPlus: KeyAction?
    public let cmMinus: KeyAction?
    public let fnPress: KeyAction?
    public let fnRelease: KeyAction?
    public let cmFnPress: KeyAction?
    public let cmFnRelease: KeyAction?
    public let fnPlus: KeyAction?
    public let fnMinus: KeyAction?
    public let cmFnPlus: KeyAction?
    public let cmFnMinus: KeyAction?
    
    enum CodingKeys: String, CodingKey {
        case comment
        case defaultValue = "default"
        case press
        case release
        case cmPress = "cm_press"
        case cmRelease = "cm_release"
        case plus
        case minus
        case cmPlus = "cm_plus"
        case cmMinus = "cm_minus"
        case fnPress = "fn_press"
        case fnRelease = "fn_release"
        case cmFnPress = "cm_fn_press"
        case cmFnRelease = "cm_fn_release"
        case fnPlus = "fn_plus"
        case fnMinus = "fn_minus"
        case cmFnPlus = "cm_fn_plus"
        case cmFnMinus = "cm_fn_minus"
    }
}

public struct ButtonMapping: Codable {
    public let comment: String?
    public let press: KeyAction?
    public let release: KeyAction?
    public let cmPress: KeyAction?
    public let cmRelease: KeyAction?
    public let fnPress: KeyAction?
    public let fnRelease: KeyAction?
    public let cmFnPress: KeyAction?
    public let cmFnRelease: KeyAction?
    
    enum CodingKeys: String, CodingKey {
        case comment
        case press
        case release
        case cmPress = "cm_press"
        case cmRelease = "cm_release"
        case fnPress = "fn_press"
        case fnRelease = "fn_release"
        case cmFnPress = "cm_fn_press"
        case cmFnRelease = "cm_fn_release"
    }
}

public struct Config: Codable {
    // Application version tag - update this value when releasing new versions
    public static let appVersion = "0.5.5"

    public let targetBundleIdentifier: String
    public let hotkeys: Bool?
    public let apple_script: Bool?
    public let lightroom_socket: Bool?
    public let customModeButton: CustomModeButton?
    public let knobs: [KnobMapping]?
    public let buttons: [ButtonMapping]?
    
    public static func load(from path: String) throws -> Config {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(Config.self, from: data)
    }
}
