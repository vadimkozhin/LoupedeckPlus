import Foundation
import os

public final class ScriptManager: @unchecked Sendable {
    private struct ScriptCacheKey: Hashable {
        let actionName: String
        let activeAppPath: String?
        let defaultValue: Double?
    }

    var scripts = [String: String]()
    private let scriptsDirectory: String
    private var targetBundleIdentifier: String
    private var compiledScripts = [ScriptCacheKey: NSAppleScript]()
    private var lock = os_unfair_lock()
    
    public init(targetBundleIdentifier: String, scriptsDirectory: String = "scripts") {
        self.targetBundleIdentifier = targetBundleIdentifier
        self.scriptsDirectory = scriptsDirectory
        loadScripts()
    }
    
    /// Loads all AppleScript files (.applescript) recursively from the scripts folder.
    public func loadScripts() {
        os_unfair_lock_lock(&lock)
        compiledScripts.removeAll()
        os_unfair_lock_unlock(&lock)
        
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: scriptsDirectory)
        guard fm.fileExists(atPath: scriptsDirectory) else {
            Logger.script.info("'\(self.scriptsDirectory, privacy: .public)' directory not found. Creating it...")
            do {
                try fm.createDirectory(atPath: scriptsDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                Logger.script.error("Error creating 'scripts' directory: \(error.localizedDescription, privacy: .public)")
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
                            
                            if ext == "applescript" || ext == "txt" {
                                let content = try String(contentsOf: itemURL, encoding: .utf8)
                                scripts[nameWithoutExtension] = content
                                let relPath = itemURL.path.replacingOccurrences(of: scriptsDirectory + "/", with: "")
                                Logger.script.info("Loaded AppleScript: '\(nameWithoutExtension, privacy: .public)' (from: \(relPath, privacy: .public))")
                            }
                        }
                    }
                }
            } catch {
                Logger.script.error("Error scanning folder \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        
        scanDirectory(url: rootURL)
    }
    
    private func redirectCaptureOneTell(in source: String, activeAppPath: String?) -> String {
        let pattern = #"tell\s+application\s+"Capture\s+One[^"]*""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return source
        }
        
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let replacement: String
        if let path = activeAppPath {
            replacement = "tell application \"\(path)\""
        } else {
            os_unfair_lock_lock(&lock)
            let targetID = targetBundleIdentifier
            os_unfair_lock_unlock(&lock)
            replacement = "tell application id \"\(targetID)\""
        }
        
        let escapedReplacement = NSRegularExpression.escapedTemplate(for: replacement)
        return regex.stringByReplacingMatches(in: source, options: [], range: range, withTemplate: escapedReplacement)
    }

    private func executeCompiledScript(_ appleScript: NSAppleScript, actionName: String) {
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        
        if let error = errorInfo {
            Logger.script.error("AppleScript execution error ('\(actionName, privacy: .public)'): \(String(describing: error), privacy: .public)")
        } else {
            Logger.script.info("Successfully executed AppleScript: '\(actionName, privacy: .public)'")
        }
    }

    /// Executes a script by name and optionally replaces the {{DEFAULT}} placeholder.
    public func execute(actionName: String, defaultValue: Double?, activeAppPath: String? = nil) {
        let key = ScriptCacheKey(actionName: actionName, activeAppPath: activeAppPath, defaultValue: defaultValue)
        
        os_unfair_lock_lock(&lock)
        if let cachedScript = compiledScripts[key] {
            os_unfair_lock_unlock(&lock)
            executeCompiledScript(cachedScript, actionName: actionName)
            return
        }
        os_unfair_lock_unlock(&lock)
        
        guard var scriptSource = scripts[actionName] else {
            Logger.script.error("Error: Script '\(actionName, privacy: .public)' is not loaded.")
            return
        }
        
        // Replace {{DEFAULT}} if a default value is specified
        if let val = defaultValue {
            scriptSource = scriptSource.replacingOccurrences(of: "{{DEFAULT}}", with: String(val))
        } else {
            scriptSource = scriptSource.replacingOccurrences(of: "{{DEFAULT}}", with: "0.0")
        }
        
        scriptSource = redirectCaptureOneTell(in: scriptSource, activeAppPath: activeAppPath)
        
        // Compile the script in memory
        guard let appleScript = NSAppleScript(source: scriptSource) else {
            Logger.script.error("Error: Failed to compile AppleScript '\(actionName, privacy: .public)'")
            return
        }
        
        os_unfair_lock_lock(&lock)
        compiledScripts[key] = appleScript
        os_unfair_lock_unlock(&lock)
        
        executeCompiledScript(appleScript, actionName: actionName)
    }
    
    public func executeCustomScript(source: String, actionName: String, activeAppPath: String? = nil) {
        let key = ScriptCacheKey(actionName: "custom_\(actionName)", activeAppPath: activeAppPath, defaultValue: nil)
        
        os_unfair_lock_lock(&lock)
        if let cachedScript = compiledScripts[key] {
            os_unfair_lock_unlock(&lock)
            executeCompiledScript(cachedScript, actionName: actionName)
            return
        }
        os_unfair_lock_unlock(&lock)
        
        let scriptSource = redirectCaptureOneTell(in: source, activeAppPath: activeAppPath)
        
        guard let appleScript = NSAppleScript(source: scriptSource) else {
            Logger.script.error("Error: Failed to compile custom AppleScript '\(actionName, privacy: .public)'")
            return
        }
        
        os_unfair_lock_lock(&lock)
        compiledScripts[key] = appleScript
        os_unfair_lock_unlock(&lock)
        
        executeCompiledScript(appleScript, actionName: actionName)
    }
    
    public func updateTargetBundleIdentifier(_ newBundleID: String) {
        os_unfair_lock_lock(&lock)
        self.targetBundleIdentifier = newBundleID
        self.compiledScripts.removeAll()
        os_unfair_lock_unlock(&lock)
        Logger.script.info("Target bundle identifier updated to: \(newBundleID, privacy: .public)")
    }
}
