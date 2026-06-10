import XCTest
import Foundation
@testable import LoupedeckPlusDaemon

final class ScriptManagerTests: XCTestCase {
    var tempDirectoryURL: URL!
    
    override func setUp() {
        super.setUp()
        // Create a unique temporary directory for script loading tests
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! fm.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        tempDirectoryURL = tempDir
    }
    
    override func tearDown() {
        let fm = FileManager.default
        try? fm.removeItem(at: tempDirectoryURL)
        super.tearDown()
    }
    
    func testScriptLoadingFromDirectory() throws {
        let fm = FileManager.default
        
        // Write mock applescript files
        let scriptA = "tell application \"Capture One\"\n  adjust exposure by {{DEFAULT}}\nend tell"
        let scriptB = "tell application \"Capture One\"\n  reset crop\nend tell"
        
        let fileA = tempDirectoryURL.appendingPathComponent("adjust_exposure.applescript")
        let fileB = tempDirectoryURL.appendingPathComponent("reset_crop.scpt")
        let fileIgnore = tempDirectoryURL.appendingPathComponent("ignore_me.json")
        
        try scriptA.write(to: fileA, atomically: true, encoding: .utf8)
        try scriptB.write(to: fileB, atomically: true, encoding: .utf8)
        try "{}".write(to: fileIgnore, atomically: true, encoding: .utf8)
        
        // Initialize manager
        let manager = ScriptManager(targetBundleIdentifier: "com.test.app", scriptsDirectory: tempDirectoryURL.path)
        
        // Assert loaded scripts
        XCTAssertEqual(manager.scripts.count, 2)
        XCTAssertEqual(manager.scripts["adjust_exposure"], scriptA)
        XCTAssertEqual(manager.scripts["reset_crop"], scriptB)
        XCTAssertNil(manager.scripts["ignore_me"])
    }
    
    func testBundleIdentifierUpdate() throws {
        let manager = ScriptManager(targetBundleIdentifier: "com.old.app", scriptsDirectory: tempDirectoryURL.path)
        
        // Update bundle ID
        manager.updateTargetBundleIdentifier("com.new.app")
        
        // Load target scripts
        let fm = FileManager.default
        let sourceCode = "tell application \"Capture One\"\n  set val to 1\nend tell"
        let fileURL = tempDirectoryURL.appendingPathComponent("test_script.applescript")
        try sourceCode.write(to: fileURL, atomically: true, encoding: .utf8)
        
        manager.loadScripts()
        XCTAssertEqual(manager.scripts["test_script"], sourceCode)
    }
}
