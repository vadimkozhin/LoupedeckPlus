import Cocoa
import WebKit

@MainActor
public final class ConfigurationWindowController: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    public static let shared = ConfigurationWindowController()
    
    private var window: NSWindow?
    private var webView: WKWebView?
    
    private override init() {
        super.init()
    }
    
    public func show() {
        if window == nil {
            setupWindow()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    public func triggerAboutModal() {
        let jsCode = "if (window.triggerAboutModal) { window.triggerAboutModal(); }"
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript(jsCode, completionHandler: nil)
        }
    }
    
    public func updateDeviceStatus(isConnected: Bool, serialNumber: String?) {
        let serial = serialNumber ?? ""
        let jsCode = "if (window.updateDeviceStatus) { window.updateDeviceStatus(\(isConnected), '\(serial)'); }"
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript(jsCode, completionHandler: nil)
        }
    }
    
    public func evaluateJavaScript(_ jsCode: String) {
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript(jsCode, completionHandler: nil)
        }
    }
    
    private func setupWindow() {
        let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let win = NSWindow(contentRect: rect, styleMask: mask, backing: .buffered, defer: false)
        win.title = "LoupedeckPlus v\(Self.getVersionTag())"
        win.titlebarAppearsTransparent = false
        win.isMovableByWindowBackground = true
        win.minSize = NSSize(width: 1280, height: 720)
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        
        let webConfig = WKWebViewConfiguration()
        let userController = WKUserContentController()
        userController.add(self, name: "loupedeck")
        webConfig.userContentController = userController
        
        // Disable cache during development to ensure updates are reflected
        webConfig.preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        let web = WKWebView(frame: win.contentView!.bounds, configuration: webConfig)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground") // Transparent background while loading HTML
        
        win.contentView?.addSubview(web)
        self.window = win
        self.webView = web
        
        loadUI()
    }
    
    private func loadUI() {
        // First try to locate inside the App Bundle Resources folder (production)
        if let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "ui") {
            webView?.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
            print("[Configurator] Loading UI from App Bundle: \(htmlURL.path)")
        } else {
            // Fallback to local workspace files (developer fallback)
            let fm = FileManager.default
            let workspaceURL = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("resources/ui/index.html")
            if fm.fileExists(atPath: workspaceURL.path) {
                webView?.loadFileURL(workspaceURL, allowingReadAccessTo: workspaceURL.deletingLastPathComponent())
                print("[Configurator] Loading UI from local workspace: \(workspaceURL.path)")
            } else {
                print("[Configurator] Error: Could not locate UI resources!")
            }
        }
    }
    
    public func windowWillClose(_ notification: Notification) {
        // Do not nil out references so the window state is retained and the app does not terminate or crash.
        print("[Configurator] Configuration window closed (hidden).")
    }
    
    // MARK: - WKScriptMessageHandler
    
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "loupedeck",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            return
        }
        
        let callbackID = body["callbackID"] as? String
        
        switch action {
        case "getConfigs":
            handleGetConfigs(callbackID: callbackID)
        case "loadConfig":
            if let name = body["name"] as? String {
                handleLoadConfig(name: name, callbackID: callbackID)
            }
        case "saveConfig":
            if let name = body["name"] as? String, let content = body["content"] as? String {
                handleSaveConfig(name: name, content: content, callbackID: callbackID)
            }
        case "createConfig":
            if let name = body["name"] as? String {
                handleCreateConfig(name: name, callbackID: callbackID)
            }
        case "deleteConfig":
            if let name = body["name"] as? String {
                handleDeleteConfig(name: name, callbackID: callbackID)
            }
        case "renameConfig":
            if let oldName = body["oldName"] as? String, let newName = body["newName"] as? String {
                handleRenameConfig(oldName: oldName, newName: newName, callbackID: callbackID)
            }
        case "getDeviceStatus":
            handleGetDeviceStatus(callbackID: callbackID)
        case "getActiveConfig":
            handleGetActiveConfig(callbackID: callbackID)
        case "setActiveConfig":
            handleSetActiveConfig(body: body, callbackID: callbackID)
        case "browseApp":
            handleBrowseApp(callbackID: callbackID)
        case "getScripts":
            handleGetScripts(callbackID: callbackID)
        case "getSVG":
            handleGetSVG(callbackID: callbackID)
        default:
            print("[Configurator] Warning: Unknown action requested: \(action)")
        }
    }
    
    // MARK: - RPC Message Handlers
    
    private func handleGetSVG(callbackID: String?) {
        let fm = FileManager.default
        if let svgURL = Bundle.main.url(forResource: "ui", withExtension: "svg", subdirectory: "ui") {
            do {
                let content = try String(contentsOf: svgURL, encoding: .utf8)
                sendResponse(callbackID: callbackID, data: content)
                return
            } catch {}
        }
        
        // Fallback to local workspace
        let workspaceURL = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("resources/ui/ui.svg")
        do {
            let content = try String(contentsOf: workspaceURL, encoding: .utf8)
            sendResponse(callbackID: callbackID, data: content)
        } catch {
            sendResponse(callbackID: callbackID, data: nil, error: "Could not find ui.svg in bundle or workspace: \(error.localizedDescription)")
        }
    }
    
    private func handleGetConfigs(callbackID: String?) {
        let fm = FileManager.default
        let dir = Self.getConfigsDirectoryURL()
        do {
            let contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])
            let jsonFiles = contents.filter { $0.pathExtension.lowercased() == "json" }
                                    .map { $0.lastPathComponent }
                                    .sorted()
            sendResponse(callbackID: callbackID, data: jsonFiles)
        } catch {
            sendResponse(callbackID: callbackID, data: nil, error: error.localizedDescription)
        }
    }
    
    private func handleLoadConfig(name: String, callbackID: String?) {
        let dir = Self.getConfigsDirectoryURL()
        let fileURL = dir.appendingPathComponent(name)
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            sendResponse(callbackID: callbackID, data: content)
        } catch {
            sendResponse(callbackID: callbackID, data: nil, error: error.localizedDescription)
        }
    }
    
    private func handleSaveConfig(name: String, content: String, callbackID: String?) {
        let dir = Self.getConfigsDirectoryURL()
        let fileURL = dir.appendingPathComponent(name)
        do {
            // Validate JSON structure first
            if let data = content.data(using: .utf8) {
                _ = try JSONDecoder().decode(Config.self, from: data)
            }
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            
            // Notify AppDelegate to reload config
            DispatchQueue.main.async {
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.reloadCurrentConfig()
                }
            }
            
            sendResponse(callbackID: callbackID, data: "success")
        } catch {
            sendResponse(callbackID: callbackID, data: nil, error: "Save Failed: \(error.localizedDescription)")
        }
    }
    
    private func handleCreateConfig(name: String, callbackID: String?) {
        var fileName = name
        if !fileName.lowercased().hasSuffix(".json") {
            fileName += ".json"
        }
        let dir = Self.getConfigsDirectoryURL()
        let sourceURL = dir.appendingPathComponent("default.json")
        let destURL = dir.appendingPathComponent(fileName)
        
        let fm = FileManager.default
        if fm.fileExists(atPath: destURL.path) {
            sendResponse(callbackID: callbackID, data: nil, error: "A configuration profile with this name already exists.")
            return
        }
        
        do {
            if fm.fileExists(atPath: sourceURL.path) {
                try fm.copyItem(at: sourceURL, to: destURL)
                // Set targetBundleIdentifier to empty string
                if let data = try? Data(contentsOf: destURL),
                   var json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    json["targetBundleIdentifier"] = ""
                    let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
                    try updatedData.write(to: destURL)
                }
            } else {
                // Fallback template
                let basic = """
                {
                  "targetBundleIdentifier": "",
                  "hotkeys": true,
                  "apple_script": true,
                  "lightroom_socket": false,
                  "knobs": [],
                  "buttons": []
                }
                """
                try basic.write(to: destURL, atomically: true, encoding: .utf8)
            }
            sendResponse(callbackID: callbackID, data: fileName)
        } catch {
            sendResponse(callbackID: callbackID, data: nil, error: error.localizedDescription)
        }
    }
    
    private func handleDeleteConfig(name: String, callbackID: String?) {
        if name.lowercased() == "default.json" {
            sendResponse(callbackID: callbackID, data: nil, error: "Cannot delete the default template profile.")
            return
        }
        
        let dir = Self.getConfigsDirectoryURL()
        let fileURL = dir.appendingPathComponent(name)
        let fm = FileManager.default
        
        guard fm.fileExists(atPath: fileURL.path) else {
            sendResponse(callbackID: callbackID, data: nil, error: "Configuration file not found.")
            return
        }
        
        do {
            try fm.removeItem(at: fileURL)
            
            // Check if this was the active config
            let configuratorURL = Self.getConfiguratorConfigURL()
            var activeName = "default.json"
            var json: [String: Any] = [:]
            if let data = try? Data(contentsOf: configuratorURL),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = existing
                if let currentActive = existing["activeConfig"] as? String {
                    activeName = currentActive
                }
            }
            
            if activeName == name {
                json["activeConfig"] = "default.json"
                let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
                try updatedData.write(to: configuratorURL)
                
                // Notify AppDelegate to reload config
                DispatchQueue.main.async {
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.reloadCurrentConfig()
                    }
                }
            }
            
            sendResponse(callbackID: callbackID, data: "success")
        } catch {
            sendResponse(callbackID: callbackID, data: nil, error: "Delete Failed: \(error.localizedDescription)")
        }
    }
    
    private func handleRenameConfig(oldName: String, newName: String, callbackID: String?) {
        if oldName.lowercased() == "default.json" {
            sendResponse(callbackID: callbackID, data: nil, error: "Cannot rename the default template profile.")
            return
        }
        
        var formattedNewName = newName
        if !formattedNewName.lowercased().hasSuffix(".json") {
            formattedNewName += ".json"
        }
        
        if formattedNewName.lowercased() == "default.json" {
            sendResponse(callbackID: callbackID, data: nil, error: "Cannot rename a profile to 'default.json'.")
            return
        }
        
        let dir = Self.getConfigsDirectoryURL()
        let sourceURL = dir.appendingPathComponent(oldName)
        let destURL = dir.appendingPathComponent(formattedNewName)
        
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            sendResponse(callbackID: callbackID, data: nil, error: "Source configuration profile not found.")
            return
        }
        
        if fm.fileExists(atPath: destURL.path) {
            sendResponse(callbackID: callbackID, data: nil, error: "A configuration profile with the new name already exists.")
            return
        }
        
        do {
            try fm.moveItem(at: sourceURL, to: destURL)
            
            // Check if this was the active config
            let configuratorURL = Self.getConfiguratorConfigURL()
            var activeName = "default.json"
            var json: [String: Any] = [:]
            if let data = try? Data(contentsOf: configuratorURL),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = existing
                if let currentActive = existing["activeConfig"] as? String {
                    activeName = currentActive
                }
            }
            
            if activeName == oldName {
                json["activeConfig"] = formattedNewName
                let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
                try updatedData.write(to: configuratorURL)
                
                // Notify AppDelegate to reload config
                DispatchQueue.main.async {
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.reloadCurrentConfig()
                    }
                }
            }
            
            sendResponse(callbackID: callbackID, data: formattedNewName)
        } catch {
            sendResponse(callbackID: callbackID, data: nil, error: "Rename Failed: \(error.localizedDescription)")
        }
    }
    
    private func handleGetDeviceStatus(callbackID: String?) {
        DispatchQueue.main.async {
            guard let appDelegate = NSApp.delegate as? AppDelegate,
                  let listener = appDelegate.getMIDIListener() else {
                self.sendResponse(callbackID: callbackID, data: ["isConnected": false, "serialNumber": ""])
                return
            }
            let isConnected = listener.isKeyboardConnected
            let serial = listener.keyboardSerialNumber ?? ""
            self.sendResponse(callbackID: callbackID, data: ["isConnected": isConnected, "serialNumber": serial])
        }
    }
    
    private func handleGetActiveConfig(callbackID: String?) {
        let fileURL = Self.getConfiguratorConfigURL()
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        } else {
            json["activeConfig"] = "default.json"
        }
        json["version"] = Self.getVersionTag()
        sendResponse(callbackID: callbackID, data: json)
    }
    
    private func handleSetActiveConfig(body: [String: Any], callbackID: String?) {
        let fileURL = Self.getConfiguratorConfigURL()
        var json: [String: Any] = [:]
        
        // Load existing configurations to merge new values
        if let data = try? Data(contentsOf: fileURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        
        if let name = body["name"] as? String {
            json["activeConfig"] = name
        }
        if let globalOverride = body["globalOverride"] as? Bool {
            json["globalOverride"] = globalOverride
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            try data.write(to: fileURL)
            
            // Notify AppDelegate to reload config
            DispatchQueue.main.async {
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.reloadCurrentConfig()
                }
            }
            
            sendResponse(callbackID: callbackID, data: "success")
        } catch {
            sendResponse(callbackID: callbackID, data: nil, error: error.localizedDescription)
        }
    }
    
    private func handleBrowseApp(callbackID: String?) {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.title = "Select Target Application"
            panel.allowedFileTypes = ["app"]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            
            panel.begin { response in
                if response == .OK, let appURL = panel.url {
                    if let bundle = Bundle(url: appURL), let bundleID = bundle.bundleIdentifier {
                        self.sendResponse(callbackID: callbackID, data: bundleID)
                    } else {
                        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
                        if let dict = NSDictionary(contentsOf: plistURL),
                           let bundleID = dict["CFBundleIdentifier"] as? String {
                            self.sendResponse(callbackID: callbackID, data: bundleID)
                        } else {
                            self.sendResponse(callbackID: callbackID, data: nil, error: "Could not read bundle identifier from selected application.")
                        }
                    }
                } else {
                    self.sendResponse(callbackID: callbackID, data: nil, error: "Cancelled")
                }
            }
        }
    }
    
    private func handleGetScripts(callbackID: String?) {
        let fm = FileManager.default
        let scriptsDir = Self.getConfigDirectoryURL().appendingPathComponent("scripts")
        var list = [String]()
        
        func scan(directory: URL) {
            guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: []) else { return }
            for url in contents {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        scan(directory: url)
                    } else {
                        let ext = url.pathExtension.lowercased()
                        if ext == "applescript" || ext == "scpt" || ext == "txt" {
                            let name = url.deletingPathExtension().lastPathComponent
                            list.append(name)
                        }
                    }
                }
            }
        }
        
        scan(directory: scriptsDir)
        list.sort()
        sendResponse(callbackID: callbackID, data: list)
    }
    
    // MARK: - Helper Methods
    
    private func sendResponse(callbackID: String?, data: Any?, error: String? = nil) {
        guard let callbackID = callbackID else { return }
        var jsData = "null"
        
        if let data = data {
            if let array = data as? [String] {
                if let jsonData = try? JSONSerialization.data(withJSONObject: array, options: []),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    jsData = jsonStr
                }
            } else if let dict = data as? [String: Any] {
                if let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: []),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    jsData = jsonStr
                }
            } else if let str = data as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
                    jsData = trimmed
                } else {
                    jsData = "\"\(str.escapingJS())\""
                }
            }
        }
        
        let jsError = error != nil ? "\"\(error!.escapingJS())\"" : "null"
        let jsCode = "window.receiveLoupedeckResponse('\(callbackID)', \(jsData), \(jsError));"
        
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript(jsCode, completionHandler: { _, err in
                if let err = err {
                    print("[Configurator] JS Evaluation error: \(err.localizedDescription)")
                }
            })
        }
    }
    
    // MARK: - Path Helpers
    
    public static func getConfigDirectoryURL() -> URL {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let dir = homeDir.appendingPathComponent(".config/loupedeck-plus")
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    
    public static func getVersionTag() -> String {
        return Config.appVersion
    }
    
    public static func getConfigsDirectoryURL() -> URL {
        let dir = getConfigDirectoryURL().appendingPathComponent("configs")
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    public static func getConfiguratorConfigURL() -> URL {
        return getConfigDirectoryURL().appendingPathComponent("configurator.json")
    }
    
    // MARK: - Seeding
    
    public static func seedConfigsIfNeeded() {
        let fm = FileManager.default
        let userConfigsDir = getConfigsDirectoryURL()
        let destURL = userConfigsDir.appendingPathComponent("default.json")
        
        if !fm.fileExists(atPath: destURL.path) {
            print("[Config] Seeding default configs to \(userConfigsDir.path)...")
            
            // Try to find the configs directory in bundle resources
            let sourceConfigsURL: URL?
            if let resourcePath = Bundle.main.resourcePath {
                let bundleURL = URL(fileURLWithPath: resourcePath).appendingPathComponent("configs")
                sourceConfigsURL = fm.fileExists(atPath: bundleURL.path) ? bundleURL : nil
            } else {
                let localConfigsURL = URL(fileURLWithPath: "configs")
                sourceConfigsURL = fm.fileExists(atPath: localConfigsURL.path) ? localConfigsURL : nil
            }
            
            if let sourceURL = sourceConfigsURL {
                if let contents = try? fm.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil, options: []) {
                    for fileURL in contents {
                        let targetURL = userConfigsDir.appendingPathComponent(fileURL.lastPathComponent)
                        try? fm.copyItem(at: fileURL, to: targetURL)
                    }
                }
            }
        }
        
        // Seed default configurator.json
        let configuratorURL = getConfiguratorConfigURL()
        if !fm.fileExists(atPath: configuratorURL.path) {
            let defaultConfig = "{\n  \"activeConfig\": \"default.json\",\n  \"version\": \"1.0.0\"\n}"
            try? defaultConfig.write(to: configuratorURL, atomically: true, encoding: .utf8)
        } else {
            if let data = try? Data(contentsOf: configuratorURL),
               var json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                if json["version"] == nil {
                    json["version"] = "1.0.0"
                    if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
                        try? updatedData.write(to: configuratorURL)
                    }
                }
            }
        }
        
        // Seed default scripts folder
        let userScriptsDir = getConfigDirectoryURL().appendingPathComponent("scripts")
        if !fm.fileExists(atPath: userScriptsDir.path) {
            try? fm.createDirectory(at: userScriptsDir, withIntermediateDirectories: true)
        }
        
        let sourceScriptsURL: URL?
        if let resourcePath = Bundle.main.resourcePath {
            let bundleURL = URL(fileURLWithPath: resourcePath).appendingPathComponent("scripts")
            sourceScriptsURL = fm.fileExists(atPath: bundleURL.path) ? bundleURL : nil
        } else {
            let localScriptsURL = URL(fileURLWithPath: "scripts")
            sourceScriptsURL = fm.fileExists(atPath: localScriptsURL.path) ? localScriptsURL : nil
        }
        
        if let sourceURL = sourceScriptsURL {
            if let contents = try? fm.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil, options: []) {
                for fileURL in contents {
                    let targetURL = userScriptsDir.appendingPathComponent(fileURL.lastPathComponent)
                    if !fm.fileExists(atPath: targetURL.path) {
                        try? fm.copyItem(at: fileURL, to: targetURL)
                    }
                }
            }
        }
    }
    
    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    // MARK: - WKUIDelegate

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
    
    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Loupedeck Configurator"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = self.window {
            alert.beginSheetModal(for: window) { _ in
                completionHandler()
            }
        } else {
            alert.runModal()
            completionHandler()
        }
    }
    
    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Confirm Action"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        if let window = self.window {
            alert.beginSheetModal(for: window) { response in
                completionHandler(response == .alertFirstButtonReturn)
            }
        } else {
            let response = alert.runModal()
            completionHandler(response == .alertFirstButtonReturn)
        }
    }
}

extension String {
    func escapingJS() -> String {
        return self.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"")
                   .replacingOccurrences(of: "\n", with: "\\n")
                   .replacingOccurrences(of: "\r", with: "\\r")
    }
}
