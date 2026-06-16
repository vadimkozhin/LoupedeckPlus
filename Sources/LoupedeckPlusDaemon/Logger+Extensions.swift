import Foundation
import os

extension Logger {
    public static let subsystem = "com.loupedeck.plus"
    
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let midi = Logger(subsystem: subsystem, category: "midi")
    public static let script = Logger(subsystem: subsystem, category: "script")
    public static let config = Logger(subsystem: subsystem, category: "config")
    public static let socket = Logger(subsystem: subsystem, category: "socket")
}
