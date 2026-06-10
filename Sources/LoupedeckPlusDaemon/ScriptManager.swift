import Foundation

public final class ScriptManager: @unchecked Sendable {
    var scripts = [String: String]()
    private let scriptsDirectory: String
    private var targetBundleIdentifier: String
    private var lock = os_unfair_lock()
    
    public init(targetBundleIdentifier: String, scriptsDirectory: String = "scripts") {
        self.targetBundleIdentifier = targetBundleIdentifier
        self.scriptsDirectory = scriptsDirectory
        loadScripts()
    }
    
    /// Loads all AppleScript files (.applescript, .scpt) recursively from the scripts folder.
    public func loadScripts() {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: scriptsDirectory)
        guard fm.fileExists(atPath: scriptsDirectory) else {
            print("[ScriptManager] Info: '\(scriptsDirectory)' directory not found. Creating it...")
            do {
                try fm.createDirectory(atPath: scriptsDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("[ScriptManager] Error creating 'scripts' directory: \(error.localizedDescription)")
            }
            return
        }
        
        func scanDirectory(url: URL) {
            do {
                let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
                for itemURL in contents {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: itemURL.path, isDirectory: &isDir) {
                        if isDir.boolValue {
                            // Recursively scan subdirectory (like "custom")
                            scanDirectory(url: itemURL)
                        } else {
                            let nameWithoutExtension = itemURL.deletingPathExtension().lastPathComponent
                            let ext = itemURL.pathExtension.lowercased()
                            
                            if ext == "applescript" || ext == "scpt" || ext == "txt" {
                                let content = try String(contentsOf: itemURL, encoding: .utf8)
                                scripts[nameWithoutExtension] = content
                                print("[ScriptManager] Loaded AppleScript: '\(nameWithoutExtension)' (from: \(itemURL.path.replacingOccurrences(of: scriptsDirectory + "/", with: "")))")
                            }
                        }
                    }
                }
            } catch {
                print("[ScriptManager] Error scanning folder \(url.path): \(error.localizedDescription)")
            }
        }
        
        scanDirectory(url: rootURL)
    }
    
    /// Executes a script by name and optionally replaces the {{DEFAULT}} placeholder.
    public func execute(actionName: String, defaultValue: Double?, activeAppPath: String? = nil) {
        guard var scriptSource = scripts[actionName] else {
            print("[ScriptManager] Error: Script '\(actionName)' is not loaded.")
            return
        }
        
        // Replace {{DEFAULT}} if a default value is specified
        if let val = defaultValue {
            scriptSource = scriptSource.replacingOccurrences(of: "{{DEFAULT}}", with: String(val))
        } else {
            scriptSource = scriptSource.replacingOccurrences(of: "{{DEFAULT}}", with: "0.0")
        }
        
        // Dynamically redirect tell application "Capture One" to use target bundle identifier or specific app path
        if let path = activeAppPath {
            scriptSource = scriptSource.replacingOccurrences(
                of: "tell application \"Capture One\"",
                with: "tell application \"\(path)\""
            )
        } else {
            os_unfair_lock_lock(&lock)
            let targetID = targetBundleIdentifier
            os_unfair_lock_unlock(&lock)
            scriptSource = scriptSource.replacingOccurrences(
                of: "tell application \"Capture One\"",
                with: "tell application id \"\(targetID)\""
            )
        }
        
        // Compile the script in memory
        guard let appleScript = NSAppleScript(source: scriptSource) else {
            print("[ScriptManager] Error: Failed to compile AppleScript '\(actionName)'")
            return
        }
        
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        
        if let error = errorInfo {
            print("[ScriptManager] AppleScript execution error ('\(actionName)'): \(error)")
        } else {
            print("[ScriptManager] Successfully executed AppleScript: '\(actionName)'")
        }
    }
    
    public func executeCustomScript(source: String, actionName: String, activeAppPath: String? = nil) {
        var scriptSource = source
        
        if let path = activeAppPath {
            scriptSource = scriptSource.replacingOccurrences(
                of: "tell application \"Capture One\"",
                with: "tell application \"\(path)\""
            )
        } else {
            os_unfair_lock_lock(&lock)
            let targetID = targetBundleIdentifier
            os_unfair_lock_unlock(&lock)
            scriptSource = scriptSource.replacingOccurrences(
                of: "tell application \"Capture One\"",
                with: "tell application id \"\(targetID)\""
            )
        }
        
        guard let appleScript = NSAppleScript(source: scriptSource) else {
            print("[ScriptManager] Error: Failed to compile custom AppleScript '\(actionName)'")
            return
        }
        
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        
        if let error = errorInfo {
            print("[ScriptManager] AppleScript execution error ('\(actionName)'): \(error)")
        } else {
            print("[ScriptManager] Successfully executed custom AppleScript: '\(actionName)'")
        }
    }
    
    public func updateTargetBundleIdentifier(_ newBundleID: String) {
        os_unfair_lock_lock(&lock)
        self.targetBundleIdentifier = newBundleID
        os_unfair_lock_unlock(&lock)
        print("[ScriptManager] Target bundle identifier updated to: \(newBundleID)")
    }
}
