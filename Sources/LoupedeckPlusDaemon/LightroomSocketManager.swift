import Foundation
import Network
import AppKit

public final class LightroomSocketManager: @unchecked Sendable {
    public static let shared = LightroomSocketManager()
    
    private let queue = DispatchQueue(label: "com.loupedeck.lightroomSocket")
    private var receiverConnection: NWConnection?
    private var senderConnection: NWConnection?
    
    private var receiverPort: Int?
    private var senderPort: Int?
    
    private var timer: DispatchSourceTimer?
    
    private init() {
        startMonitoring()
    }
    
    public func startMonitoring() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now(), repeating: 3.0)
        timer?.setEventHandler { [weak self] in
            self?.checkAndReconnect()
        }
        timer?.resume()
    }
    
    private func checkAndReconnect() {
        // Find if Lightroom is running.
        let runningApps = NSWorkspace.shared.runningApplications
        let isLrRunning = runningApps.contains { app in
            if let bundleID = app.bundleIdentifier?.lowercased() {
                return bundleID.contains("lightroom")
            }
            return false
        }
        
        if !isLrRunning {
            if receiverConnection != nil || senderConnection != nil {
                print("[LightroomSocket] Lightroom is not running. Disconnecting...")
                disconnectAll()
            }
            return
        }
        
        // Read ports
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        var port1URL = tempDir.appendingPathComponent("com.loupedeckplus.remote_control_socket.port1")
        var port2URL = tempDir.appendingPathComponent("com.loupedeckplus.remote_control_socket.port2")
        
        if !FileManager.default.fileExists(atPath: port1URL.path) {
            port1URL = tempDir.appendingPathComponent("com.loupedeck.loupedeck2.port1")
            port2URL = tempDir.appendingPathComponent("com.loupedeck.loupedeck2.port2")
        }
        
        let p1Content = try? String(contentsOf: port1URL, encoding: .utf8)
        let p2Content = try? String(contentsOf: port2URL, encoding: .utf8)
        
        let p1 = p1Content.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let p2 = p2Content.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        
        // Handle Receiver Port (Port 1)
        if let p1 = p1 {
            if receiverConnection == nil || receiverPort != p1 {
                print("[LightroomSocket] Connecting/Reconnecting to Receiver (Port 1): \(p1)")
                disconnectReceiver()
                connectReceiver(port: p1)
            }
        } else {
            if receiverConnection != nil {
                print("[LightroomSocket] Receiver port disappeared. Disconnecting...")
                disconnectReceiver()
            }
        }
        
        // Handle Sender Port (Port 2)
        if let p2 = p2 {
            if senderConnection == nil || senderPort != p2 {
                print("[LightroomSocket] Connecting/Reconnecting to Sender (Port 2): \(p2)")
                disconnectSender()
                connectSender(port: p2)
            }
        } else {
            if senderConnection != nil {
                print("[LightroomSocket] Sender port disappeared. Disconnecting...")
                disconnectSender()
            }
        }
    }
    
    private func connectReceiver(port: Int) {
        self.receiverPort = port
        
        let host = NWEndpoint.Host("127.0.0.1")
        let endpointPort = NWEndpoint.Port(integerLiteral: UInt16(port))
        let connection = NWConnection(host: host, port: endpointPort, using: .tcp)
        self.receiverConnection = connection
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            self.queue.async {
                switch state {
                case .ready:
                    print("[LightroomSocket] Connected to Lightroom Receiver (Port 1) on port \(port)")
                    self.sendHandshake()
                case .failed(let error):
                    print("[LightroomSocket] Receiver connection failed: \(error)")
                    self.disconnectReceiver()
                case .cancelled:
                    print("[LightroomSocket] Receiver connection cancelled")
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }
    
    private func connectSender(port: Int) {
        self.senderPort = port
        
        let host = NWEndpoint.Host("127.0.0.1")
        let endpointPort = NWEndpoint.Port(integerLiteral: UInt16(port))
        let connection = NWConnection(host: host, port: endpointPort, using: .tcp)
        self.senderConnection = connection
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            self.queue.async {
                switch state {
                case .ready:
                    print("[LightroomSocket] Connected to Lightroom Sender (Port 2) on port \(port)")
                    self.receiveEvents()
                case .failed(let error):
                    print("[LightroomSocket] Sender connection failed: \(error)")
                    self.disconnectSender()
                case .cancelled:
                    print("[LightroomSocket] Sender connection cancelled")
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }
    
    private func sendHandshake() {
        sendMessage(action: "handshake", params: "")
    }
    
    public func sendScript(_ script: String) {
        sendMessage(action: "runscript", params: script)
    }
    
    public func sendMessage(action: String, params: String) {
        queue.async {
            guard let conn = self.receiverConnection else {
                print("[LightroomSocket] Cannot send command, not connected to Lightroom.")
                return
            }
            let messageId = Int.random(in: 1000...9999)
            let payload = "\(messageId)|\(action)|\(params)\n"
            guard let data = payload.data(using: .utf8) else { return }
            
            conn.send(content: data, completion: .contentProcessed({ error in
                if let error = error {
                    print("[LightroomSocket] Failed to send command \(action): \(error)")
                } else {
                    print("[LightroomSocket] Sent command: \(action) with params: \(params)")
                }
            }))
        }
    }
    
    private func receiveEvents() {
        guard let conn = senderConnection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            if let data = data, !data.isEmpty {
                if let msg = String(data: data, encoding: .utf8) {
                    print("[LightroomSocket] Event received from Lightroom: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            if error == nil && !isComplete {
                self?.receiveEvents()
            } else if let error = error {
                print("[LightroomSocket] Sender connection error while receiving: \(error)")
                self?.disconnectSender()
            }
        }
    }
    
    private func disconnectReceiver() {
        receiverConnection?.cancel()
        receiverConnection = nil
        receiverPort = nil
        // If receiver is down, sender is guaranteed to be down/closed by Lightroom, so clean it up too.
        disconnectSender()
    }
    
    private func disconnectSender() {
        senderConnection?.cancel()
        senderConnection = nil
        senderPort = nil
    }
    
    private func disconnectAll() {
        disconnectReceiver()
        disconnectSender()
    }
}
