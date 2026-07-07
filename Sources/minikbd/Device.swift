import Foundation
import IOKit.hid

struct MiniKeyboardError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

final class KeyboardDevice {
    static let vendorID = 0x1189
    static let productID = 0x8840
    static let vendorUsagePage = 0xFF00

    let device: IOHIDDevice
    private let manager: IOHIDManager // keeps the HID session alive for the device handle
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65)
    private var reports: [[UInt8]] = []

    private init(device: IOHIDDevice, manager: IOHIDManager) {
        self.device = device
        self.manager = manager
    }

    deinit { reportBuffer.deallocate() }

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
    /// For numbered reports macOS wants the report ID byte kept in the data,
    /// same as hidapi's mac backend does.
    func send(_ message: [UInt8]) throws {
        let status = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput,
                                          CFIndex(message[0]), message, message.count)
        guard status == kIOReturnSuccess else {
            throw MiniKeyboardError(String(format: "write failed: 0x%08x", status))
        }
    }

    func send(_ messages: [[UInt8]]) throws {
        for message in messages { try send(message) }
    }

    /// Start capturing input reports (device responses). Call once before collectReports.
    func enableReading() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 65, { context, _, _, _, _, report, length in
            guard let context else { return }
            let keyboard = Unmanaged<KeyboardDevice>.fromOpaque(context).takeUnretainedValue()
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            if bytes.first != 0x03 { bytes.insert(0x03, at: 0) } // some stacks strip the report ID
            keyboard.reports.append(bytes)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    /// Pump the run loop and return reports received, stopping after `quiet` seconds
    /// of silence (or `timeout` seconds overall, whichever comes first).
    func collectReports(quiet: TimeInterval = 0.3, timeout: TimeInterval = 5) -> [[UInt8]] {
        defer { reports = [] }
        let deadline = Date().addingTimeInterval(timeout)
        var seen = reports.count
        var lastChange = Date()
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
            if reports.count != seen {
                seen = reports.count
                lastChange = Date()
            } else if !reports.isEmpty && Date().timeIntervalSince(lastChange) > quiet {
                break
            }
        }
        return reports
    }
}
