import AppKit
import os.lock

public final class WorkspaceMonitor: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var _isTargetActive: Bool = false
    private var _activeAppPath: String?
    private var targetBundleIdentifier: String
    private var observer: NSObjectProtocol?
    
    public init(targetBundleIdentifier: String) {
        self.targetBundleIdentifier = targetBundleIdentifier
        
        // Determine initial state from the currently active application
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            let active = (frontmostApp.bundleIdentifier?.lowercased() == targetBundleIdentifier.lowercased())
            self._isTargetActive = active
            if active {
                self._activeAppPath = frontmostApp.bundleURL?.path
            }
            print("[WorkspaceMonitor] Initial frontmost application: \(frontmostApp.bundleIdentifier ?? "none") (Target active: \(self._isTargetActive), Path: \(self._activeAppPath ?? "none"))")
        }
        
        // Listen to application activation notifications on the main thread
        self.observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                os_unfair_lock_lock(&self.lock)
                let isActive = (app.bundleIdentifier?.lowercased() == self.targetBundleIdentifier.lowercased())
                let appPath = isActive ? app.bundleURL?.path : nil
                self._isTargetActive = isActive
                self._activeAppPath = appPath
                os_unfair_lock_unlock(&self.lock)
                
                print("[WorkspaceMonitor] Active application changed to: \(app.bundleIdentifier ?? "unknown") (Target active: \(isActive), Path: \(appPath ?? "none"))")
            }
        }
    }
    
    /// Thread-safe getter to check if the target application is currently frontmost.
    /// Uses os_unfair_lock for ultra-low latency.
    public var isTargetActive: Bool {
        os_unfair_lock_lock(&lock)
        let active = _isTargetActive
        os_unfair_lock_unlock(&lock)
        return active
    }
    
    /// Thread-safe getter to get the path of the currently active target application.
    public var activeAppPath: String? {
        os_unfair_lock_lock(&lock)
        let path = _activeAppPath
        os_unfair_lock_unlock(&lock)
        return path
    }
    
    public func updateTargetBundleIdentifier(_ newBundleID: String) {
        os_unfair_lock_lock(&lock)
        self.targetBundleIdentifier = newBundleID
        
        // Immediately re-evaluate status of the new target application under lock
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            let active = (frontmostApp.bundleIdentifier?.lowercased() == newBundleID.lowercased())
            self._isTargetActive = active
            if active {
                self._activeAppPath = frontmostApp.bundleURL?.path
            } else {
                self._activeAppPath = nil
            }
            print("[WorkspaceMonitor] Target bundle ID updated to \(newBundleID). Current frontmost application: \(frontmostApp.bundleIdentifier ?? "none") (Target active: \(active), Path: \(self._activeAppPath ?? "none"))")
        } else {
            self._isTargetActive = false
            self._activeAppPath = nil
        }
        os_unfair_lock_unlock(&lock)
    }
    
    deinit {
        if let observer = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
