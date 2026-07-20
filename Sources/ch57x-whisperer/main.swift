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
    for i in 1...9 { codes["kp\(i)"] = UInt8(0x59 + i - 1) }
    codes["kp0"] = 0x62
    codes.merge([
        "enter": 0x28, "esc": 0x29, "backspace": 0x2A, "tab": 0x2B, "space": 0x2C,
        "minus": 0x2D, "equal": 0x2E, "lbracket": 0x2F, "rbracket": 0x30, "backslash": 0x31,
        "semicolon": 0x33, "quote": 0x34, "grave": 0x35, "comma": 0x36, "dot": 0x37,
        "slash": 0x38, "capslock": 0x39, "insert": 0x49, "home": 0x4A, "pageup": 0x4B,
        "delete": 0x4C, "end": 0x4D, "pagedown": 0x4E,
        "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
        "printscreen": 0x46, "scrolllock": 0x47, "pause": 0x48,
        "numlock": 0x53, "kpslash": 0x54, "kpasterisk": 0x55, "kpminus": 0x56,
        "kpplus": 0x57, "kpenter": 0x58, "kpdot": 0x63, "menu": 0x65,
        "intlhash": 0x32, "intlbackslash": 0x64, "kpequal": 0x67,
    ]) { a, _ in a }
    return codes
}()

// Spanish ISO layout aliases, parse-only: same physical key, the name a Spanish
// speaker knows it by. Display (`read`) keeps the layout-neutral US name.
let keyAliases: [String: UInt8] = ["ñ": 0x33, "ç": 0x32]

let modifierBits: [String: UInt8] = ["ctrl": 1, "shift": 2, "alt": 4, "opt": 4, "cmd": 8, "win": 8]

func parseChord(_ chord: String) throws -> Accord {
    var modifiers: UInt8 = 0
    var code: UInt8 = 0
    let parts = chord.lowercased().split(separator: "-").map(String.init)
    for (i, part) in parts.enumerated() {
        if let bit = modifierBits[part] {
            modifiers |= bit
        } else if i == parts.count - 1, let keyCode = keyCodes[part] ?? keyAliases[part] {
            code = keyCode
        } else if i == parts.count - 1, part.hasPrefix("0x"),
                  let raw = UInt8(part.dropFirst(2), radix: 16) {
            code = raw // whatever `read` printed for an unnamed key binds back verbatim
        } else {
            throw MiniKeyboardError("unknown key or modifier: '\(part)'")
        }
    }
    guard modifiers != 0 || code != 0 else { throw MiniKeyboardError("empty chord: '\(chord)'") }
    return Accord(modifiers: modifiers, code: code)
}

let mediaCodes: [String: UInt16] = Dictionary(mediaNames.map { ($1, $0) }) { a, _ in a }
let mouseButtons: [String: UInt8] = ["click": 1, "rclick": 2, "mclick": 4]

/// One binding: keyboard chords, or a single media/mouse action token
/// (media tokens come from `mediaNames`; mouse is [mods-]click|rclick|mclick|wheelup|wheeldown).
func isActionToken(_ token: String) -> Bool {
    let last = token.lowercased().split(separator: "-").last.map(String.init) ?? token
    return mediaCodes[token.lowercased()] != nil || mouseButtons[last] != nil
        || last == "wheelup" || last == "wheeldown"
}

func bindMessages(keyID: UInt8, layer: UInt8, tokens: [String], delayMS: Int = 0) throws -> [[UInt8]] {
    guard tokens.count == 1, isActionToken(tokens[0]) else {
        if let bad = tokens.first(where: isActionToken) {
            throw MiniKeyboardError("'\(bad)' is a media/mouse action — bind it alone, without other chords")
        }
        let accords = try tokens.map(parseChord)
        guard accords.count <= Ch57x.maxAccordsPerKey else {
            throw MiniKeyboardError("max \(Ch57x.maxAccordsPerKey) chords per key")
        }
        return Ch57x.bindKey(keyID: keyID, layer: layer, accords: accords, delayMS: delayMS)
    }

    guard delayMS == 0 else { throw MiniKeyboardError("--delay only works with keyboard chords") }
    let token = tokens[0].lowercased()
    if let code = mediaCodes[token] {
        return Ch57x.bindMedia(keyID: keyID, layer: layer, code: code)
    }
    var modifiers: UInt8 = 0
    let parts = token.split(separator: "-").map(String.init)
    for part in parts.dropLast() {
        guard let bit = modifierBits[part] else {
            throw MiniKeyboardError("unknown modifier '\(part)' in '\(token)'")
        }
        modifiers |= bit
    }
    if let buttons = mouseButtons[parts.last!] {
        return Ch57x.bindMouse(keyID: keyID, layer: layer, modifiers: modifiers, buttons: buttons)
    }
    return Ch57x.bindMouse(keyID: keyID, layer: layer, modifiers: modifiers,
                           wheel: parts.last! == "wheelup" ? 1 : -1)
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
    assert(led == Ch57x.ledCommitPreamble() + [
        Ch57x.pad([0x03, 0xfe, 0xb0, 0x01, 0x08, 0, 0, 0, 0, 0, 0x01, 0, 0x51]),
        Ch57x.pad([0x03, 0xfd, 0xfe, 0xff]),
    ], "led vector mismatch")
    // The preamble is what makes the colour survive a power cycle — losing it is silent
    // (the LED still lights up), so pin its shape here.
    assert(led.count == 6 && led[0][1] == 0xfb && led[1][1] == 0xfa,
           "led commit preamble missing")
    assert(led.allSatisfy { $0.count == 65 }, "wire messages must be 65 bytes")

    let media = Ch57x.bindMedia(keyID: 2, layer: 1, code: 0xCD) // playpause
    assert(media.first == Ch57x.pad([0x03, 0xfe, 0x02, 0x01, 0x02, 0, 0, 0, 0, 0, 0, 0xCD, 0]),
           "media vector mismatch")

    let click = Ch57x.bindMouse(keyID: 1, layer: 2, modifiers: 1, buttons: 2) // ctrl-rclick
    assert(click.first == Ch57x.pad([0x03, 0xfe, 0x01, 0x02, 0x03, 0, 0, 0, 0, 0, 0x01, 0x01, 0x02]),
           "mouse click vector mismatch")

    let wheel = Ch57x.bindMouse(keyID: 17, layer: 1, wheel: -1) // knob1-press wheeldown
    assert(wheel.first == Ch57x.pad([0x03, 0xfe, 0x11, 0x01, 0x03, 0, 0, 0, 0, 0, 0x03, 0, 0, 0, 0, 0xFF]),
           "mouse wheel vector mismatch")

    // token dispatch: media/mouse/keyboard all route to the right message type
    assert(try! bindMessages(keyID: 1, layer: 1, tokens: ["calculator"]).first?[4] == 0x02)
    assert(try! bindMessages(keyID: 1, layer: 1, tokens: ["cmd-wheelup"]).first?[4] == 0x03)
    assert(try! bindMessages(keyID: 1, layer: 1, tokens: ["ctrl-a"]).first?[4] == 0x01)
    assert((try? bindMessages(keyID: 1, layer: 1, tokens: ["a", "click"])) == nil,
           "mixing chords with mouse must fail")

    let chord = try! parseChord("ctrl-shift-t")
    assert(chord.modifiers == 3 && chord.code == 0x17, "chord parse mismatch")
    assert(try! parseKeyID("knob2-press") == 20, "knob id mismatch")

    // language coverage: everything the recorder can emit binds back, every
    // bindable code has a display name, and Spanish aliases hit the right keys
    for (vk, name) in virtualKeyNames {
        assert(keyCodes[name] != nil, "recorded key '\(name)' (vk \(vk)) is not bindable")
    }
    for (name, code) in keyCodes {
        assert(keyNames[code] != nil, "'\(name)' (0x\(String(code, radix: 16))) has no display name")
    }
    assert(try! parseChord("ñ").code == 0x33, "ñ alias mismatch")
    assert(try! parseChord("ç").code == 0x32, "ç alias mismatch")

    // agent script names: same chord vocabulary, Carbon keycodes/modifiers
    assert(parseHotkeyName("f13")! == (105, 0), "f13 hotkey mismatch")
    assert(parseHotkeyName("cmd-shift-f20")! == (90, 0x300), // cmdKey|shiftKey
           "cmd-shift-f20 hotkey mismatch")
    assert(parseHotkeyName("f12") == nil && parseHotkeyName("f21") == nil
           && parseHotkeyName("foo-f13") == nil, "invalid hotkey names must be rejected")

    // update version comparison
    assert(isNewerVersion("v1.2.0", than: "1.1.9"), "1.2.0 > 1.1.9")
    assert(!isNewerVersion("v1.0.0", than: "1.1.0"), "1.0.0 < 1.1.0")
    assert(!isNewerVersion("1.1.0", than: "1.1.0"), "equal is not newer")
    assert(isNewerVersion("1.1.0.1", than: "1.1"), "longer tail wins")
    assert(isNewerVersion("2.0", than: "1.9.9"), "major bump wins")
    assert(appVersion != "0", "CFBundleShortVersionString missing from Info.plist")

    print("selftest OK")
}

func usage() -> Never {
    print("""
    usage:
      ch57x-whisperer probe
      ch57x-whisperer selftest
      ch57x-whisperer bind <layer 1-3> <key> <chord>... [--delay <ms>]
          key:   1-12 | knob1-ccw|press|cw | knob2-ccw|press|cw
          chord: a | ctrl-shift-t | cmd-f13 | ... (up to \(Ch57x.maxAccordsPerKey) chords)
          or ONE media/mouse action instead of chords:
            media: \(mediaCodes.keys.sorted().joined(separator: " "))
            mouse: [mods-]click | rclick | mclick | wheelup | wheeldown (e.g. ctrl-wheelup)
      ch57x-whisperer led <layer 1-3> off|backlight-<color>|shock-<color>|shock2-<color>|press-<color>
          colors: white red orange yellow green cyan blue purple
      ch57x-whisperer read [layer 1-3]     print bindings stored in the keyboard
      ch57x-whisperer record [<layer 1-3> <key>]
          record chords from your real keyboard (ESC ends); with layer+key,
          bind the result immediately
      ch57x-whisperer gui                  open the SwiftUI configurator
      ch57x-whisperer agent [--install|--uninstall]
          menu-bar agent: F13-F20 hotkeys run zsh scripts from
          ~/.config/ch57x-whisperer/actions/ (f13.sh, cmd-f14.sh, ...);
          --install adds a login LaunchAgent, --uninstall removes it
      ch57x-whisperer update               update to the latest GitHub release
    """)
    exit(2)
}

// MARK: - main

// LED memory lived in the process-name defaults domain before the app gained
// a CFBundleIdentifier; copy it into the new domain once.
if let old = UserDefaults(suiteName: "ch57x-whisperer") {
    for layer in 1...3 where UserDefaults.standard.string(forKey: "led.layer\(layer)") == nil {
        if let value = old.string(forKey: "led.layer\(layer)") {
            UserDefaults.standard.set(value, forKey: "led.layer\(layer)")
        }
    }
}

var args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    // No args: the Action Whisperer helper runs the agent; the main app run
    // from Finder opens the GUI; a bare terminal invocation probes.
    case nil:
        if Bundle.main.bundleIdentifier == agentBundleID { try runAgent(args: []) }
        else if Bundle.main.bundlePath.hasSuffix(".app") { runGUI() }
        else { probe() }
    case "probe": probe()
    case "selftest": selftest()
    case "gui": runGUI()
    case "agent": try runAgent(args: Array(args.dropFirst()))
    case "update": runUpdate()
    case "read":
        try readConfig(layer: args.count > 1 ? parseLayer(args[1]) : nil)
    case "record":
        args.removeFirst()
        let chords = try recordChords()
        guard !chords.isEmpty else { throw MiniKeyboardError("nothing recorded") }
        print("recorded: \(chords.joined(separator: " "))")
        if args.count >= 2 {
            let layer = try parseLayer(args[0])
            let keyID = try parseKeyID(args[1])
            let accords = try chords.map(parseChord)
            let keyboard = try KeyboardDevice.open()
            try keyboard.send(Ch57x.bindKey(keyID: keyID, layer: layer, accords: accords))
            print("bound \(args[1]) on layer \(layer)")
        } else {
            print("bind it with: ch57x-whisperer bind <layer> <key> \(chords.joined(separator: " "))")
        }
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
        let keyboard = try KeyboardDevice.open()
        try keyboard.send(bindMessages(keyID: keyID, layer: layer,
                                       tokens: Array(args[2...]), delayMS: delayMS))
        print("bound \(args[1]) on layer \(layer) to: \(args[2...].joined(separator: " "))")
    case "led":
        guard args.count == 3 else { usage() }
        let layer = try parseLayer(args[1])
        let (mode, color) = try parseLED(args[2])
        let keyboard = try KeyboardDevice.open()
        try keyboard.send(Ch57x.setLED(layer: layer, mode: mode, color: color))
        // Keep the GUI's per-layer LED memory in sync (same binary, same defaults).
        let parts = args[2].split(separator: "-", maxSplits: 1)
        UserDefaults.standard.set("\(parts[0]) \(parts.count > 1 ? parts[1] : "cyan")",
                                  forKey: "led.layer\(layer)")
        print("led on layer \(layer) set to \(args[2])")
    case "raw":
        // ponytail: protocol lab bench, not a feature — no validation, deliberately
        // absent from usage(). `raw 03 fe b0 01 08 ... -- 03 fd fe ff` sends one
        // padded 64-byte message per `--`-separated group.
        let groups = args.dropFirst().split(separator: "--").map(Array.init)
        guard !groups.isEmpty else { usage() }
        let messages = try groups.map { group -> [UInt8] in
            let bytes = try group.map { (token: String) -> UInt8 in
                guard let byte = UInt8(token, radix: 16) else {
                    throw MiniKeyboardError("not a hex byte: \(token)")
                }
                return byte
            }
            guard (1...Ch57x.wireLength).contains(bytes.count) else {
                throw MiniKeyboardError("message must be 1-\(Ch57x.wireLength) bytes, got \(bytes.count)")
            }
            return Ch57x.pad(bytes)
        }
        let keyboard = try KeyboardDevice.open()
        try keyboard.send(messages)
        for message in messages {
            print("sent: " + message.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ") + " ...")
        }
    default: usage()
    }
} catch {
    print("error: \(error)")
    exit(1)
}
