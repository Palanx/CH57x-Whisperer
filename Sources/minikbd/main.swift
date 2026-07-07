import Foundation
import IOKit.hid

// MARK: - parsing

let keyCodes: [String: UInt8] = {
    var codes: [String: UInt8] = [:]
    for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { codes[String(c)] = UInt8(4 + i) }
    for i in 1...9 { codes["\(i)"] = UInt8(0x1E + i - 1) }
    codes["0"] = 0x27
    for i in 1...12 { codes["f\(i)"] = UInt8(0x3A + i - 1) }
    for i in 13...24 { codes["f\(i)"] = UInt8(0x68 + i - 13) }
    codes.merge([
        "enter": 0x28, "esc": 0x29, "backspace": 0x2A, "tab": 0x2B, "space": 0x2C,
        "minus": 0x2D, "equal": 0x2E, "lbracket": 0x2F, "rbracket": 0x30, "backslash": 0x31,
        "semicolon": 0x33, "quote": 0x34, "grave": 0x35, "comma": 0x36, "dot": 0x37,
        "slash": 0x38, "capslock": 0x39, "insert": 0x49, "home": 0x4A, "pageup": 0x4B,
        "delete": 0x4C, "end": 0x4D, "pagedown": 0x4E,
        "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
    ]) { a, _ in a }
    return codes
}()

let modifierBits: [String: UInt8] = ["ctrl": 1, "shift": 2, "alt": 4, "opt": 4, "cmd": 8, "win": 8]

func parseChord(_ chord: String) throws -> Accord {
    var modifiers: UInt8 = 0
    var code: UInt8 = 0
    let parts = chord.lowercased().split(separator: "-").map(String.init)
    for (i, part) in parts.enumerated() {
        if let bit = modifierBits[part] {
            modifiers |= bit
        } else if i == parts.count - 1, let keyCode = keyCodes[part] {
            code = keyCode
        } else {
            throw MiniKeyboardError("unknown key or modifier: '\(part)'")
        }
    }
    guard modifiers != 0 || code != 0 else { throw MiniKeyboardError("empty chord: '\(chord)'") }
    return Accord(modifiers: modifiers, code: code)
}

func parseKeyID(_ key: String) throws -> UInt8 {
    if let n = UInt8(key), (1...12).contains(n) { return n }
    let knobActions = ["ccw": 0, "press": 1, "cw": 2]
    let parts = key.lowercased().split(separator: "-").map(String.init)
    if parts.count == 2, parts[0].hasPrefix("knob"),
       let n = Int(parts[0].dropFirst(4)), (1...2).contains(n),
       let action = knobActions[parts[1]] {
        return UInt8(16 + 3 * (n - 1) + action)
    }
    throw MiniKeyboardError("invalid key '\(key)' — use 1-12, or knob1-ccw|press|cw, knob2-…")
}

func parseLayer(_ layer: String) throws -> UInt8 {
    guard let n = UInt8(layer), (1...3).contains(n) else {
        throw MiniKeyboardError("layer must be 1-3")
    }
    return n
}

let ledColors = ["white": 0, "red": 1, "orange": 2, "yellow": 3,
                 "green": 4, "cyan": 5, "blue": 6, "purple": 7]

func parseLED(_ mode: String) throws -> (mode: UInt8, color: UInt8) {
    if mode == "off" { return (0, 0) }
    let modes = ["backlight": 1, "shock": 2, "shock2": 3, "press": 4]
    let parts = mode.lowercased().split(separator: "-").map(String.init)
    guard parts.count == 2, let m = modes[parts[0]], let color = ledColors[parts[1]] else {
        throw MiniKeyboardError("invalid led mode — off | backlight-<color> | shock-<color> | shock2-<color> | press-<color>")
    }
    if m == 1 && color == 0 { return (5, 0) } // backlight white has its own mode code
    guard color != 0 else { throw MiniKeyboardError("white only works with backlight") }
    return (UInt8(m), UInt8(color))
}

// MARK: - commands

func probe() {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, [
        kIOHIDVendorIDKey: KeyboardDevice.vendorID,
        kIOHIDProductIDKey: KeyboardDevice.productID,
    ] as CFDictionary)
    IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
    if devices.isEmpty {
        print("keyboard not found (looking for 1189:8840)")
        exit(1)
    }
    for device in devices {
        func prop(_ key: String) -> Int {
            IOHIDDeviceGetProperty(device, key as CFString) as? Int ?? -1
        }
        let page = prop(kIOHIDPrimaryUsagePageKey)
        print(String(format: "interface: usagePage=0x%04X usage=%d%@",
                     page, prop(kIOHIDPrimaryUsageKey),
                     page == KeyboardDevice.vendorUsagePage ? "  <- config channel" : ""))
    }
}

func selftest() {
    // Vectors from ch57x-keyboard-tool k884x.rs tests.
    let bind = Ch57x.bindKey(keyID: 1, layer: 1, accords: [Accord(modifiers: 1, code: 4)])
    assert(bind == [
        Ch57x.pad([0x03, 0xfe, 0x01, 0x01, 0x01, 0, 0, 0, 0, 0, 0x01, 0x01, 0x04]),
        Ch57x.pad([0x03, 0xaa, 0xaa]),
        Ch57x.pad([0x03, 0xfd, 0xfe, 0xff]),
        Ch57x.pad([0x03, 0xaa, 0xaa]),
    ], "ctrl-a bind vector mismatch")

    let delayed = Ch57x.bindKey(keyID: 1, layer: 1,
                                accords: [Accord(modifiers: 1, code: 4)], delayMS: 1000)
    assert(delayed[1] == Ch57x.pad([0x03, 0xfe, 0x01, 0x01, 0x05, 0xe8, 0x03]),
           "delay vector mismatch")

    let led = Ch57x.setLED(layer: 1, mode: 1, color: 5) // backlight cyan -> 0x51
    assert(led == [
        Ch57x.pad([0x03, 0xfe, 0xb0, 0x01, 0x08, 0, 0, 0, 0, 0, 0x01, 0, 0x51]),
        Ch57x.pad([0x03, 0xfd, 0xfe, 0xff]),
    ], "led vector mismatch")

    let chord = try! parseChord("ctrl-shift-t")
    assert(chord.modifiers == 3 && chord.code == 0x17, "chord parse mismatch")
    assert(try! parseKeyID("knob2-press") == 20, "knob id mismatch")

    print("selftest OK")
}

func usage() -> Never {
    print("""
    usage:
      minikbd probe
      minikbd selftest
      minikbd bind <layer 1-3> <key> <chord>... [--delay <ms>]
          key:   1-12 | knob1-ccw|press|cw | knob2-ccw|press|cw
          chord: a | ctrl-shift-t | cmd-f13 | ... (up to \(Ch57x.maxAccordsPerKey) chords)
      minikbd led <layer 1-3> off|backlight-<color>|shock-<color>|shock2-<color>|press-<color>
          colors: white red orange yellow green cyan blue purple
    """)
    exit(2)
}

// MARK: - main

var args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case nil, "probe": probe()
    case "selftest": selftest()
    case "bind":
        args.removeFirst()
        var delayMS = 0
        if let i = args.firstIndex(of: "--delay") {
            guard i + 1 < args.count, let d = Int(args[i + 1]),
                  (0...Ch57x.maxDelayMS).contains(d) else {
                throw MiniKeyboardError("--delay needs a value of 0-\(Ch57x.maxDelayMS) ms")
            }
            delayMS = d
            args.removeSubrange(i...(i + 1))
        }
        guard args.count >= 3 else { usage() }
        let layer = try parseLayer(args[0])
        let keyID = try parseKeyID(args[1])
        let accords = try args[2...].map(parseChord)
        guard accords.count <= Ch57x.maxAccordsPerKey else {
            throw MiniKeyboardError("max \(Ch57x.maxAccordsPerKey) chords per key")
        }
        let keyboard = try KeyboardDevice.open()
        try keyboard.send(Ch57x.bindKey(keyID: keyID, layer: layer,
                                        accords: accords, delayMS: delayMS))
        print("bound \(args[1]) on layer \(layer) to: \(args[2...].joined(separator: " "))")
    case "led":
        guard args.count == 3 else { usage() }
        let layer = try parseLayer(args[1])
        let (mode, color) = try parseLED(args[2])
        let keyboard = try KeyboardDevice.open()
        try keyboard.send(Ch57x.setLED(layer: layer, mode: mode, color: color))
        print("led on layer \(layer) set to \(args[2])")
    default: usage()
    }
} catch {
    print("error: \(error)")
    exit(1)
}
