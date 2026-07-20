// CH57x config protocol for 1189:8840 keyboards (12 keys + knobs).
// Byte layout ported from kriomant/ch57x-keyboard-tool (src/keyboard/k884x.rs).
// Every wire message is the report ID byte 0x03 followed by 64 zero-padded payload
// bytes — 65 total. Sending 64 (only 63 of payload) still applies LED colours live but
// silently skips the flash commit, so they die on the next power cycle. Verified
// 2026-07-20 by capturing the vendor app's IOHIDDeviceSetReport calls: its bytes are
// identical to ours, only the length differed.

struct Accord {
    var modifiers: UInt8 // bitmask: ctrl=1 shift=2 alt=4 cmd=8
    var code: UInt8      // USB HID usage code; 0 = modifier-only press
}

enum Ch57x {
    static let maxAccordsPerKey = 18
    static let maxDelayMS = 6000

    static let wireLength = 65 // report ID + 64 payload bytes, as the vendor app sends

    static func pad(_ bytes: [UInt8]) -> [UInt8] {
        bytes + Array(repeating: 0, count: wireLength - bytes.count)
    }

    static let finish: [[UInt8]] = [
        pad([0x03, 0xaa, 0xaa]),
        pad([0x03, 0xfd, 0xfe, 0xff]),
        pad([0x03, 0xaa, 0xaa]),
    ]

    /// layer is the wire byte: 1-3. keyID: buttons 1-12, knob N (1-based)
    /// ccw/press/cw = 16+3(N-1) ... +2.
    static func bindKey(keyID: UInt8, layer: UInt8, accords: [Accord], delayMS: Int = 0) -> [[UInt8]] {
        precondition((1...3).contains(layer), "layer must be 1-3")
        precondition(!accords.isEmpty && accords.count <= maxAccordsPerKey)
        precondition(delayMS >= 0 && delayMS <= maxDelayMS)

        var msg: [UInt8] = [0x03, 0xfe, keyID, layer, 0x01, 0, 0, 0, 0, 0]
        // Single modifier-only press uses count 0 so it can combo with real keys.
        msg.append(accords.count == 1 && accords[0].code == 0 ? 0 : UInt8(accords.count))
        for accord in accords {
            msg += [accord.modifiers, accord.code]
        }

        var messages = [pad(msg)]
        if delayMS > 0 {
            messages.append(pad([0x03, 0xfe, keyID, layer, 0x05,
                                 UInt8(delayMS & 0xff), UInt8(delayMS >> 8)]))
        }
        return messages + finish
    }

    /// code: USB HID consumer usage (playpause=0xCD, calculator=0x192), u16 LE on the wire.
    static func bindMedia(keyID: UInt8, layer: UInt8, code: UInt16) -> [[UInt8]] {
        precondition((1...3).contains(layer), "layer must be 1-3")
        return [pad([0x03, 0xfe, keyID, layer, 0x02, 0, 0, 0, 0, 0,
                     0, UInt8(code & 0xff), UInt8(code >> 8)])] + finish
    }

    /// One mouse action: buttons (left=1 right=2 middle=4) or wheel (1 up, -1 down), not both.
    static func bindMouse(keyID: UInt8, layer: UInt8, modifiers: UInt8 = 0,
                          buttons: UInt8 = 0, wheel: Int8 = 0) -> [[UInt8]] {
        precondition((1...3).contains(layer), "layer must be 1-3")
        precondition((buttons != 0) != (wheel != 0), "exactly one of buttons/wheel")
        let payload: [UInt8] = wheel != 0
            ? [0x03, modifiers, 0, 0, 0, UInt8(bitPattern: wheel)]
            : [0x01, modifiers, buttons]
        return [pad([0x03, 0xfe, keyID, layer, 0x03, 0, 0, 0, 0, 0] + payload)] + finish
    }

    /// The LED write only reaches flash when it is preceded by the vendor's query
    /// preamble **on the same open HID session**. Without it the colour applies live and
    /// then dies on the next power cycle — which is exactly the bug we chased on
    /// 2026-07-20. Byte-for-byte what MINI_KEYBOARD sends (captured); the tails it sends
    /// are uninitialised heap, so zeros do just as well. Neither reference port does this.
    static func ledCommitPreamble() -> [[UInt8]] {
        [pad([0x03, 0xfb, 0xfb, 0xfb, 0x01])]
            + (1...3).map { pad([0x03, 0xfa, 0x0f, 0x03, UInt8($0), 0x7f]) }
    }

    /// mode: 0=off 1=backlight 2=breathing 3=breathing-slow 4=press 5=backlight-white
    /// color: 0=white 1=red 2=orange 3=yellow 4=green 5=cyan 6=blue 7=purple
    /// Send the whole array through one KeyboardDevice — the preamble and the write must
    /// share a session.
    static func setLED(layer: UInt8, mode: UInt8, color: UInt8) -> [[UInt8]] {
        precondition((1...3).contains(layer), "layer must be 1-3")
        let code = (color << 4) | mode
        return ledCommitPreamble() + [
            pad([0x03, 0xfe, 0xb0, layer, 0x08, 0, 0, 0, 0, 0, 0x01, 0, code]),
            pad([0x03, 0xfd, 0xfe, 0xff]),
        ]
    }
}
