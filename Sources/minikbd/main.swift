import Foundation
import IOKit.hid

// ponytail: probe only — finds the keyboard's vendor HID interface and opens it.
// Protocol (layers/macros/LEDs) comes next, ported from ch57x-keyboard-tool.

let vendorID = 0x1189
let productID = 0x8840
let vendorUsagePage = 0xFF00

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey: vendorID,
    kIOHIDProductIDKey: productID,
] as CFDictionary)
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
guard !devices.isEmpty else {
    print("keyboard not found (looking for \(String(format: "%04x:%04x", vendorID, productID)))")
    exit(1)
}

func prop(_ device: IOHIDDevice, _ key: String) -> Int {
    IOHIDDeviceGetProperty(device, key as CFString) as? Int ?? -1
}

for device in devices {
    let page = prop(device, kIOHIDPrimaryUsagePageKey)
    let isVendor = page == vendorUsagePage
    print(String(format: "interface: usagePage=0x%04X usage=%d maxOutputReport=%d%@",
                 page,
                 prop(device, kIOHIDPrimaryUsageKey),
                 prop(device, kIOHIDMaxOutputReportSizeKey),
                 isVendor ? "  <- config channel" : ""))
    if isVendor {
        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        print(status == kIOReturnSuccess ? "opened vendor interface OK" : "open failed: \(status)")
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}
