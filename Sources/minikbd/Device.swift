import Foundation
import IOKit.hid

struct MiniKeyboardError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct KeyboardDevice {
    static let vendorID = 0x1189
    static let productID = 0x8840
    static let vendorUsagePage = 0xFF00

    let device: IOHIDDevice
    let manager: IOHIDManager // keeps the HID session alive for the device handle

    static func open() throws -> KeyboardDevice {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductIDKey: productID,
            kIOHIDDeviceUsagePageKey: vendorUsagePage,
        ] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let device = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first else {
            throw MiniKeyboardError("keyboard not found — is it connected by USB?")
        }
        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            throw MiniKeyboardError(String(format: "cannot open device: 0x%08x", status))
        }
        return KeyboardDevice(device: device, manager: manager)
    }

    /// message: 64 bytes starting with report ID 0x03 (as on the wire).
    func send(_ message: [UInt8]) throws {
        var data = Array(message.dropFirst())
        let status = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput,
                                          CFIndex(message[0]), &data, data.count)
        guard status == kIOReturnSuccess else {
            throw MiniKeyboardError(String(format: "write failed: 0x%08x", status))
        }
    }

    func send(_ messages: [[UInt8]]) throws {
        for message in messages { try send(message) }
    }
}
