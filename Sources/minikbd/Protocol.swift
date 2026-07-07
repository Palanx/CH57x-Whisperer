// CH57x config protocol for 1189:8840 keyboards (12 keys + knobs).
// Byte layout ported from kriomant/ch57x-keyboard-tool (src/keyboard/k884x.rs).
// Every wire message is 64 bytes, zero-padded, starting with report ID 0x03.

struct Accord {
    var modifiers: UInt8 // bitmask: ctrl=1 shift=2 alt=4 cmd=8
    var code: UInt8      // USB HID usage code; 0 = modifier-only press
}

enum Ch57x {
    static let maxAccordsPerKey = 18
    static let maxDelayMS = 6000

    static func pad(_ bytes: [UInt8]) -> [UInt8] {
        bytes + Array(repeating: 0, count: 64 - bytes.count)
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

    /// mode: 0=off 1=backlight 2=shock 3=shock2 4=press 5=backlight-white
    /// color: 0=white 1=red 2=orange 3=yellow 4=green 5=cyan 6=blue 7=purple
    static func setLED(layer: UInt8, mode: UInt8, color: UInt8) -> [[UInt8]] {
        precondition((1...3).contains(layer), "layer must be 1-3")
        let code = (color << 4) | mode
        return [
            pad([0x03, 0xfe, 0xb0, layer, 0x08, 0, 0, 0, 0, 0, 0x01, 0, code]),
            pad([0x03, 0xfd, 0xfe, 0xff]),
        ]
    }
}
