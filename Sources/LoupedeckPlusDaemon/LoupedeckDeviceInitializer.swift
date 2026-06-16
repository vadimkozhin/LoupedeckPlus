import Foundation
import CoreMIDI
import os

public struct LoupedeckDeviceInitializer {
    /// Executes the captured Loupedeck+ initialization sequence.
    /// - Parameters:
    ///   - destination: The MIDI destination endpoint.
    ///   - sendRawBytes: A closure that takes a byte array and targets a specific endpoint.
    public static func run(
        destination: MIDIEndpointRef,
        sendRawBytes: @escaping ([UInt8], MIDIEndpointRef) -> Void
    ) {
        Logger.midi.info("Starting Loupedeck+ initialization sequence...")
        
        let sequence: [[UInt8]] = [
            // 1. SysEx: Device type / Info query
            [0xF0, 0x30, 0x34, 0x30, 0x36, 0x33, 0x30, 0x30, 0x32, 0xF7],
            
            // 2. Control Change (Channel 2): B1 40 0B
            [0xB1, 0x40, 0x0B],
            
            // 3. SysEx: Serial number request
            [0xF0, 0x30, 0x35, 0x31, 0x30, 0x30, 0x30, 0x30, 0x32, 0x31, 0x30, 0xF7],
            
            // 4. SysEx: Serial number request (duplicate retry matching log)
            [0xF0, 0x30, 0x35, 0x31, 0x30, 0x30, 0x30, 0x30, 0x32, 0x31, 0x30, 0xF7],
            
            // 5. SysEx: SAT mode query/init
            [0xF0, 0x30, 0x34, 0x30, 0x36, 0x33, 0x31, 0x30, 0x32, 0xF7],
            
            // 6. SysEx: LUM mode query/init
            [0xF0, 0x30, 0x34, 0x30, 0x36, 0x33, 0x32, 0x30, 0x32, 0xF7],
            
            // 7. SysEx: HUE mode query/init
            [0xF0, 0x30, 0x34, 0x30, 0x36, 0x33, 0x33, 0x30, 0x32, 0xF7],
            
            // 8. Control Change (Channel 2): B1 40 05
            [0xB1, 0x40, 0x05],
            
            // 9. Control Change (Channel 2): B1 40 01
            [0xB1, 0x40, 0x01],
            
            // 10. Control Change (Channel 2): B1 01 00
            [0xB1, 0x01, 0x00],
            
            // 11. Control Change (Channel 2): B1 04 00
            [0xB1, 0x04, 0x00],
            
            // 12. Control Change (Channel 2): B1 03 00
            [0xB1, 0x03, 0x00],
            
            // 13. Control Change (Channel 2): B1 02 00
            [0xB1, 0x02, 0x00],
            
            // 14. Control Change (Channel 2): B1 01 00
            [0xB1, 0x01, 0x00]
        ]
        
        for msg in sequence {
            sendRawBytes(msg, destination)
            // Add a tiny 2ms delay between messages to ensure Loupedeck parses them cleanly without buffer overflow
            usleep(2000)
        }
        
        Logger.midi.info("Loupedeck+ initialization sequence sent successfully.")
    }
}
