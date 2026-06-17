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
                                let relPath = itemURL.path.replacingOccurrences(of: scriptsDirectory + "/", with: "")
                                do {
                                    let content = try String(contentsOf: itemURL, encoding: .utf8)
                                    
                                    // Check for null bytes / binary file markers
                                    if content.contains("\0") {
                                        Logger.script.warning("Script '\(nameWithoutExtension, privacy: .public)' (at: \(relPath, privacy: .public)) contains null bytes and might be a binary file. Continuing load anyway...")
                                    }
                                    // Check line endings
                                    if content.contains("\r") && !content.contains("\n") {
                                        Logger.script.warning("Script '\(nameWithoutExtension, privacy: .public)' (at: \(relPath, privacy: .public)) uses old Classic Mac line endings (CR only). Converting or checking endings is advised.")
                                    }
                                    
                                    scripts[nameWithoutExtension] = content
                                    Logger.script.info("Loaded AppleScript: '\(nameWithoutExtension, privacy: .public)' (from: \(relPath, privacy: .public))")
                                } catch {
                                    Logger.script.error("Failed to load script '\(nameWithoutExtension, privacy: .public)' at '\(relPath, privacy: .public)' due to error: \(error.localizedDescription, privacy: .public)")
                                    diagnoseFileError(at: itemURL, error: error, relPath: relPath)
                                }
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
    
    private func diagnoseFileError(at url: URL, error: Error, relPath: String) {
        do {
            let data = try Data(contentsOf: url)
            if data.isEmpty {
                Logger.script.error("Diagnosis for '\(relPath, privacy: .public)': File is empty (0 bytes).")
                return
            }
            
            // Check for compiled AppleScript (.scpt) magic bytes "FasD"
            if data.count >= 4 {
                let magic = data.prefix(4)
                if magic[0] == 0x46 && magic[1] == 0x61 && magic[2] == 0x73 && magic[3] == 0x44 {
                    Logger.script.error("Diagnosis for '\(relPath, privacy: .public)': The file appears to be a compiled binary AppleScript (.scpt format) containing magic bytes 'FasD'. The daemon expects plain text scripts saved in UTF-8 format.")
                    return
                }
            }
            
            // Check for general binary format
            var nullCount = 0
            var controlCount = 0
            for byte in data.prefix(min(data.count, 1024)) {
                if byte == 0 {
                    nullCount += 1
                } else if byte < 32 && byte != 9 && byte != 10 && byte != 13 {
                    controlCount += 1
                }
            }
            if nullCount > 0 || controlCount > 20 {
                Logger.script.error("Diagnosis for '\(relPath, privacy: .public)': The file appears to be in binary format (found \(nullCount) null bytes and \(controlCount) control characters in the first 1KB). Plain text UTF-8 is required.")
                return
            }
            
            // Test other encodings
            let encodings: [(String.Encoding, String)] = [
                (.utf16, "UTF-16"),
                (.ascii, "ASCII"),
                (.windowsCP1252, "Windows CP1252"),
                (.isoLatin1, "ISO-8859-1 (Latin 1)")
            ]
            for (enc, name) in encodings {
                if let _ = String(data: data, encoding: enc) {
                    Logger.script.error("Diagnosis for '\(relPath, privacy: .public)': The file is not encoded in UTF-8 but can be successfully decoded using \(name). Please save the file using UTF-8 encoding.")
                    return
                }
            }
            
            Logger.script.error("Diagnosis for '\(relPath, privacy: .public)': The file contains invalid byte sequences for UTF-8 and could not be identified as standard plain text.")
        } catch {
            Logger.script.error("Diagnosis for '\(relPath, privacy: .public)': Failed to read file data for diagnostics: \(error.localizedDescription, privacy: .public)")
        }
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

    private func logAppleScriptError(errorInfo: NSDictionary, source: String, actionName: String) {
        let briefMessage = errorInfo["NSAppleScriptErrorBriefMessage"] as? String ?? ""
        let detailedMessage = errorInfo["NSAppleScriptErrorMessage"] as? String ?? ""
        let errorNumber = errorInfo["NSAppleScriptErrorNumber"] as? Int ?? 0
        
        var lineDetails = ""
        if let rangeValue = errorInfo["NSAppleScriptErrorRange"] as? NSValue {
            let range = rangeValue.rangeValue
            if range.location != NSNotFound {
                let utf16 = source.utf16
                if range.location <= utf16.count {
                    let prefixUTF16 = utf16.prefix(range.location)
                    if let prefixStr = String(prefixUTF16) {
                        let lines = prefixStr.components(separatedBy: .newlines)
                        let lineNum = lines.count
                        let allLines = source.components(separatedBy: .newlines)
                        if lineNum >= 1 && lineNum <= allLines.count {
                            let lineContent = allLines[lineNum - 1]
                            let colNum = lines.last?.count ?? 0
                            var arrow = ""
                            if colNum > 0 {
                                arrow = String(repeating: " ", count: colNum) + "^"
                            } else {
                                arrow = "^"
                            }
                            lineDetails = "\nError at line \(lineNum):\n\(lineContent)\n\(arrow)"
                        }
                    }
                }
            }
        }
        
        let msg = detailedMessage.isEmpty ? briefMessage : detailedMessage
        Logger.script.error("AppleScript error ('\(actionName, privacy: .public)') [Error \(errorNumber)]: \(msg, privacy: .public)\(lineDetails, privacy: .public)")
    }

    private func executeCompiledScript(_ appleScript: NSAppleScript, actionName: String) {
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        
        if let error = errorInfo {
            let source = appleScript.source ?? ""
            logAppleScriptError(errorInfo: error, source: source, actionName: actionName)
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
