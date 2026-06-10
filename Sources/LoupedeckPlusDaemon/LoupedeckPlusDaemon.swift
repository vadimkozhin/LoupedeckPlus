import Cocoa
import Foundation
import CoreGraphics

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var midiListener: MIDIListener?
    private var workspaceMonitor: WorkspaceMonitor?
    private var eventSynthesizer: EventSynthesizer?
    private var scriptManager: ScriptManager?
    
    private var currentRunningConfigName: String?
    private var configuratorActiveConfigName: String = "default.json"
    private var configuratorGlobalOverride: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Setup LaunchAgent if running inside an App Bundle
        registerLaunchAgent()
        
        // Install custom Lightroom and Capture One plugin files if they do not exist
        installPluginsIfNeeded()
        
        // 2. Setup Status Bar Item
        setupStatusBar()
        
        // 3. Setup Edit Menu to enable Copy/Paste shortcuts in WKWebView
        setupEditMenu()
        
        // 4. Check Accessibility Permissions
        checkAccessibilityPermissions()
        
        // 5. Start Loupedeck daemon logic
        startDaemon()
        
        // 6. Listen to active application changes to dynamically switch configs
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }
    
    private func registerLaunchAgent() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension.lowercased() == "app" else {
            print("[App] Running as standalone command-line executable. Skipping launch agent registration.")
            return
        }
        
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let launchAgentsDir = homeDir.appendingPathComponent("Library/LaunchAgents")
        let plistURL = launchAgentsDir.appendingPathComponent("com.loupedeck.plus.plist")
        
        // Inside the App Bundle, the binary is at LoupedeckPlus.app/Contents/MacOS/LoupedeckPlus
        // We look for the executable inside the bundle dynamically
        let executableName = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String ?? "LoupedeckPlus"
        let executablePath = bundleURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName).path
        
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.loupedeck.plus</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
        
        do {
            if !fileManager.fileExists(atPath: launchAgentsDir.path) {
                try fileManager.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true, attributes: nil)
            }
            
            var needsWrite = true
            if fileManager.fileExists(atPath: plistURL.path) {
                if let existingContent = try? String(contentsOf: plistURL, encoding: .utf8),
                   existingContent.contains(executablePath) {
                    needsWrite = false
                }
            }
            
            if needsWrite {
                try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
                print("[App] Registered launch agent at \(plistURL.path)")
            } else {
                print("[App] Launch agent is already up-to-date.")
            }
        } catch {
            print("[App] Failed to register launch agent: \(error.localizedDescription)")
        }
    }
    
    private func installPluginsIfNeeded() {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        
        // 1. Lightroom Plugin Installation
        // Target: ~/Library/Application Support/Adobe/Lightroom/Modules/LoupedeckPlus.lrplugin
        let lrModulesDir = homeDir.appendingPathComponent("Library/Application Support/Adobe/Lightroom/Modules")
        let lrPluginDest = lrModulesDir.appendingPathComponent("LoupedeckPlus.lrplugin")
        
        // 2. Capture One Shortcut Installation
        // Target: ~/Library/Application Support/Capture One/KeyboardShortcuts/LoupedeckPlus.plist
        let c1ShortcutsDir = homeDir.appendingPathComponent("Library/Application Support/Capture One/KeyboardShortcuts")
        let c1ShortcutDest = c1ShortcutsDir.appendingPathComponent("LoupedeckPlus.plist")
        
        // Resolve source paths from App Bundle Resources
        guard let resourceURL = Bundle.main.resourceURL else {
            print("[App] Resources directory not found. Skipping plugin installation.")
            return
        }
        
        let lrPluginSource = resourceURL.appendingPathComponent("plugins/Lightroom/LoupedeckPlus.lrplugin")
        let c1ShortcutSource = resourceURL.appendingPathComponent("plugins/CaptureOne/LoupedeckPlus.plist")
        
        // Install Lightroom plugin if it does not exist
        if !fm.fileExists(atPath: lrPluginDest.path) {
            print("[App] Installing Lightroom Plugin to \(lrPluginDest.path)...")
            do {
                if !fm.fileExists(atPath: lrModulesDir.path) {
                    try fm.createDirectory(at: lrModulesDir, withIntermediateDirectories: true, attributes: nil)
                }
                if fm.fileExists(atPath: lrPluginSource.path) {
                    try fm.copyItem(at: lrPluginSource, to: lrPluginDest)
                    print("[App] Lightroom Plugin installed successfully.")
                } else {
                    print("[App] Error: Lightroom Plugin source not found in bundle resources: \(lrPluginSource.path)")
                }
            } catch {
                print("[App] Failed to copy Lightroom plugin: \(error.localizedDescription)")
            }
        } else {
            print("[App] Lightroom Plugin is already present.")
        }
        
        // Install Capture One shortcut plist if it does not exist
        if !fm.fileExists(atPath: c1ShortcutDest.path) {
            print("[App] Installing Capture One Shortcut plist to \(c1ShortcutDest.path)...")
            do {
                if !fm.fileExists(atPath: c1ShortcutsDir.path) {
                    try fm.createDirectory(at: c1ShortcutsDir, withIntermediateDirectories: true, attributes: nil)
                }
                if fm.fileExists(atPath: c1ShortcutSource.path) {
                    try fm.copyItem(at: c1ShortcutSource, to: c1ShortcutDest)
                    print("[App] Capture One Shortcut plist installed successfully.")
                } else {
                    print("[App] Error: Capture One Shortcut source not found in bundle resources: \(c1ShortcutSource.path)")
                }
            } catch {
                print("[App] Failed to copy Capture One shortcut plist: \(error.localizedDescription)")
            }
        } else {
            print("[App] Capture One Shortcut plist is already present.")
        }
    }
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            // Try loading custom StatusIcon from App Bundle
            if let imageURL = Bundle.main.url(forResource: "StatusIcon", withExtension: "png"),
               let iconImage = NSImage(contentsOf: imageURL) {
                iconImage.isTemplate = false
                button.image = iconImage
            } else if let iconImage = NSImage(named: "StatusIcon") {
                iconImage.isTemplate = false
                button.image = iconImage
            } else {
                // Fallback to standard SF Symbol or emoji
                if #available(macOS 11.0, *) {
                    button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Loupedeck")
                } else {
                    button.title = "🎛️"
                }
            }
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Configuration", action: #selector(openConfiguration), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "About", action: #selector(openAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Exit", action: #selector(exitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
    
    private func setupEditMenu() {
        let mainMenu = NSMenu()
        
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About LoupedeckPlus", action: #selector(openAbout), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit LoupedeckPlus", action: #selector(exitApp), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        
        NSApplication.shared.mainMenu = mainMenu
    }
    
    @objc private func openAbout() {
        ConfigurationWindowController.shared.show()
        ConfigurationWindowController.shared.triggerAboutModal()
    }
    
    @objc private func openConfiguration() {
        ConfigurationWindowController.shared.show()
    }
    
    @objc private func exitApp() {
        print("[App] Exiting application...")
        NSApplication.shared.terminate(nil)
    }
    
    private func checkAccessibilityPermissions() {
        if !EventSynthesizer.hasAccessibilityPermissions() {
            print("[Warning] Daemon is missing macOS Accessibility Permissions!")
            
            // Show standard modal alert
            let alert = NSAlert()
            alert.messageText = "Accessibility Permissions Required"
            alert.informativeText = "Loupedeck Interceptor requires Accessibility permissions to simulate keystrokes and scroll wheel events.\n\nPlease enable Accessibility for this app in System Settings -> Privacy & Security -> Accessibility."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                EventSynthesizer.requestAccessibilityPermissions()
                // Redirect user to Settings
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            print("[Permissions] Accessibility permissions are verified.")
        }
    }
    
    private func loadConfig() -> (Config, String, Bool) {
        let arguments = CommandLine.arguments
        if arguments.count > 1 {
            let configPath = arguments[1]
            do {
                let config = try Config.load(from: configPath)
                return (config, URL(fileURLWithPath: configPath).lastPathComponent, false)
            } catch {
                print("[Config] Error loading argument config: \(error.localizedDescription)")
            }
        }
        
        // Default startup loading
        ConfigurationWindowController.seedConfigsIfNeeded()
        
        let fm = FileManager.default
        let configuratorURL = ConfigurationWindowController.getConfiguratorConfigURL()
        var activeConfigName = "default.json"
        var globalOverride = false
        
        if let data = try? Data(contentsOf: configuratorURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let name = json["activeConfig"] as? String {
                activeConfigName = name
            }
            if let override = json["globalOverride"] as? Bool {
                globalOverride = override
            }
        }
        
        let configsDir = ConfigurationWindowController.getConfigsDirectoryURL()
        var configURL = configsDir.appendingPathComponent(activeConfigName)
        
        if !fm.fileExists(atPath: configURL.path) {
            print("[Config] Active config \(activeConfigName) not found, falling back to default.json")
            activeConfigName = "default.json"
            configURL = configsDir.appendingPathComponent(activeConfigName)
        }
        
        do {
            let config = try Config.load(from: configURL.path)
            return (config, activeConfigName, globalOverride)
        } catch {
            print("[Config] Error loading active config: \(error.localizedDescription)")
            if let bundlePath = Bundle.main.path(forResource: "default", ofType: "json", inDirectory: "configs") {
                if let config = try? Config.load(from: bundlePath) {
                    return (config, "default.json", globalOverride)
                }
            }
            fatalError("Could not load any configuration file.")
        }
    }
    
    public func reloadCurrentConfig() {
        print("[App] Reloading active configuration...")
        
        let (config, activeName, globalOverride) = loadConfig()
        self.configuratorActiveConfigName = activeName
        self.configuratorGlobalOverride = globalOverride
        self.currentRunningConfigName = activeName
        
        applyConfig(config: config, name: activeName, globalOverride: globalOverride)
    }
    
    private func applyConfig(config: Config, name: String, globalOverride: Bool) {
        print("[Config] Applying configuration: \(name). Target bundle ID: \(config.targetBundleIdentifier). Global Override: \(globalOverride)")
        
        // 1. Resolve scripts directory
        let userScriptsURL = ConfigurationWindowController.getConfigDirectoryURL().appendingPathComponent("scripts")
        
        let scriptsDirectoryPath: String
        if FileManager.default.fileExists(atPath: userScriptsURL.path) {
            scriptsDirectoryPath = userScriptsURL.path
        } else if let bundleResources = Bundle.main.resourcePath {
            let bundleScriptsURL = URL(fileURLWithPath: bundleResources).appendingPathComponent("scripts")
            if FileManager.default.fileExists(atPath: bundleScriptsURL.path) {
                scriptsDirectoryPath = bundleScriptsURL.path
            } else {
                scriptsDirectoryPath = "scripts"
            }
        } else {
            scriptsDirectoryPath = "scripts"
        }
        
        // Check if components are already running and can be reused
        if let listener = self.midiListener,
           let monitor = self.workspaceMonitor,
           let manager = self.scriptManager {
            print("[Config] Reusing existing MIDIListener, WorkspaceMonitor, and ScriptManager. Updating config dynamically...")
            manager.updateTargetBundleIdentifier(config.targetBundleIdentifier)
            monitor.updateTargetBundleIdentifier(config.targetBundleIdentifier)
            listener.updateConfig(config, globalOverride: globalOverride)
            print("[App] Configuration dynamic update complete.")
            return
        }
        
        // 2. Dispose old MIDI listener to release resources
        if midiListener != nil {
            print("[MIDI] Disposing old MIDI listener...")
            midiListener = nil
        }
        
        // 3. Re-create components (fallback / initial creation)
        print("[Script] Initializing AppleScript manager with directory: \(scriptsDirectoryPath)")
        let scriptManager = ScriptManager(targetBundleIdentifier: config.targetBundleIdentifier, scriptsDirectory: scriptsDirectoryPath)
        self.scriptManager = scriptManager
        
        workspaceMonitor = WorkspaceMonitor(targetBundleIdentifier: config.targetBundleIdentifier)
        eventSynthesizer = EventSynthesizer()
        
        print("[MIDI] Initializing CoreMIDI listener...")
        let listener = MIDIListener(
            config: config,
            workspaceMonitor: workspaceMonitor!,
            eventSynthesizer: eventSynthesizer!,
            scriptManager: scriptManager
        )
        listener.globalOverride = globalOverride
        self.midiListener = listener
        
        print("[App] Configuration reload/apply complete.")
    }
    
    @objc private func handleWorkspaceAppActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }
        
        // If configurator is currently active/focused, lock to the dropdown selected profile in configurator
        let isConfiguratorActive = (bundleID == Bundle.main.bundleIdentifier)
        
        // Load configurator.json to get the latest override setting
        let configuratorURL = ConfigurationWindowController.getConfiguratorConfigURL()
        var activeConfigName = "default.json"
        var globalOverride = false
        
        if let data = try? Data(contentsOf: configuratorURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let name = json["activeConfig"] as? String {
                activeConfigName = name
            }
            if let override = json["globalOverride"] as? Bool {
                globalOverride = override
            }
        }
        
        self.configuratorActiveConfigName = activeConfigName
        self.configuratorGlobalOverride = globalOverride
        
        // If globalOverride is true, and the configurator window is NOT focused, lock to the override activeConfig Name
        if globalOverride && !isConfiguratorActive {
            if self.currentRunningConfigName != activeConfigName {
                print("[App] Global override active. Locking to \(activeConfigName)")
                self.currentRunningConfigName = activeConfigName
                let configsDir = ConfigurationWindowController.getConfigsDirectoryURL()
                let configURL = configsDir.appendingPathComponent(activeConfigName)
                if let config = try? Config.load(from: configURL.path) {
                    self.applyConfig(config: config, name: activeConfigName, globalOverride: true)
                }
            }
            return
        }
        
        var finalConfigName = "default.json"
        var isOverrideRunning = false
        
        if isConfiguratorActive {
            // When editing in configurator, temporarily override focus logic to run the profile currently selected in dropdown
            finalConfigName = activeConfigName
            isOverrideRunning = true // Enable global override so the Loupedeck keys are responsive inside configurator
        } else {
            // Intercept active app and dynamically match it with configs
            let configsDir = ConfigurationWindowController.getConfigsDirectoryURL()
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: configsDir, includingPropertiesForKeys: nil, options: []) else { return }
            
            var targetConfigName: String? = nil
            for fileURL in files {
                if fileURL.pathExtension.lowercased() == "json" && fileURL.lastPathComponent.lowercased() != "default.json" {
                    if let config = try? Config.load(from: fileURL.path) {
                        if config.targetBundleIdentifier.lowercased() == bundleID.lowercased() {
                            targetConfigName = fileURL.lastPathComponent
                            break
                        }
                    }
                }
            }
            finalConfigName = targetConfigName ?? "default.json"
        }
        
        if finalConfigName != self.currentRunningConfigName {
            print("[App] Switching active configuration from \(self.currentRunningConfigName ?? "nil") to \(finalConfigName) (Trigger app: \(bundleID))")
            self.currentRunningConfigName = finalConfigName
            
            let configsDir = ConfigurationWindowController.getConfigsDirectoryURL()
            let configURL = configsDir.appendingPathComponent(finalConfigName)
            if let config = try? Config.load(from: configURL.path) {
                self.applyConfig(config: config, name: finalConfigName, globalOverride: isOverrideRunning)
            }
            
            // Notify the web UI to auto-switch the profile dropdown
            let cleanName = finalConfigName.escapingJS()
            let jsCode = "if (window.handleProfileAutoSwitch) { window.handleProfileAutoSwitch('\(cleanName)'); }"
            ConfigurationWindowController.shared.evaluateJavaScript(jsCode)
        }
    }
    
    private func startDaemon() {
        reloadCurrentConfig()
        _ = LightroomSocketManager.shared
        print("[Daemon] Daemon is listening and status bar app is running.")
    }
    
    public func getMIDIListener() -> MIDIListener? {
        return midiListener
    }
}

@main
struct LoupedeckPlusDaemon {
    // Hold a strong static reference to the delegate to prevent deallocation
    @MainActor static var delegateReference: AppDelegate?
    
    @MainActor
    static func main() {
        setbuf(stdout, nil)
        
        print("==================================================")
        print("        Loupedeck Interceptor App Wrapper         ")
        print("==================================================")
        
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegateReference = delegate
        app.delegate = delegate
        
        app.run()
    }
}
