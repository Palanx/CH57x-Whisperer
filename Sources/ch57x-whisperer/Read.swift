// Config read-back for the 0x8840 keyboard.
// Protocol from kamaaina/macropad_tool (src/keyboard/k884x.rs, src/decoder.rs):
// send a device-type query (0x03 0xfb...), then per layer a read request
// (0x03 0xfa keys knobs layer...); the device answers with one input report
// per key/knob action, in the same shape as the bind message.
// The query tails are byte-exact USB captures; only the first bytes are
// believed meaningful, but we replay them verbatim.

import Foundation

enum Ch57xRead {
    static let deviceTypeQuery: [UInt8] = Array([
        0x03, 0xfb, 0xfb, 0xfb, 0x02, 0x06, 0x2c, 0xd0, 0x80, 0x00, 0xdc, 0xcf, 0x80, 0x00,
        0xcc, 0xd2, 0x21, 0x01, 0xe0, 0xcf, 0x80, 0x00, 0x2c, 0xd0, 0x80, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xd0, 0x0d, 0x48, 0x00, 0xfc, 0xcf, 0x80, 0x00, 0xc0, 0x61, 0xbc, 0x06,
        0x38, 0xd0, 0x80, 0x00, 0x70, 0xf5, 0x1e, 0x62, 0x98, 0xda, 0x11, 0x62, 0x0c, 0x80,
        0x00, 0x00, 0x48, 0x09, 0x00, 0x06, 0xff, 0xff, 0xff,
    ].prefix(Ch57x.wireLength))

    static func readLayer(keys: UInt8, knobs: UInt8, layer: UInt8) -> [UInt8] {
        Array([
            0x03, 0xfa, keys, knobs, layer, 0x06, 0x00, 0xcc, 0x80, 0x00, 0xc0, 0xcc, 0x80,
            0x00, 0x7c, 0xf2, 0x02, 0x69, 0x00, 0x00, 0x00, 0x00, 0x4d, 0x00, 0x14, 0x06, 0xc0,
            0xcc, 0x80, 0x00, 0x49, 0x01, 0x00, 0x00, 0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0xb0, 0xcc, 0x80, 0x00, 0x40, 0xcd, 0x80, 0x00, 0x88, 0x05, 0x00, 0x06, 0xc0,
            0x0a, 0x10, 0x06, 0xe0, 0xcc, 0x80, 0x00, 0xc7, 0xb6, 0x48,
        ].prefix(Ch57x.wireLength))
    }
}

struct ReadMapping {
    let keyNumber: UInt8
    let layer: UInt8
    let delayMS: Int
    let text: String
}

let keyNames: [UInt8: String] = Dictionary(keyCodes.map { ($1, $0) }) { first, _ in first }

let mediaNames: [UInt16: String] = [
    0xB5: "next", 0xB6: "prev", 0xB7: "stop", 0xCD: "playpause",
    0xE2: "mute", 0xE9: "volumeup", 0xEA: "volumedown",
    0x6F: "brightnessup", 0x70: "brightnessdown",
    0x183: "multimedia", 0x18A: "email", 0x192: "calculator", 0x194: "mycomputer",
    0x223: "wwwhome", 0x224: "wwwback", 0x225: "wwwforward", 0x227: "wwwrefresh",
]

func modifierString(_ bits: UInt8) -> String {
    let names = ["ctrl", "shift", "alt", "cmd", "rctrl", "rshift", "ralt", "rcmd"]
    return (0..<8).compactMap { bits >> $0 & 1 == 1 ? names[$0] : nil }.joined(separator: "-")
}

func decodeMapping(_ buf: [UInt8]) -> ReadMapping? {
    guard buf.count >= 46, buf[1] == 0xfa else { return nil }
    var parts: [String] = []

    switch buf[4] {
    case 0x02: // media key, consumer usage u16 LE
        let code = UInt16(buf[11]) | UInt16(buf[12]) << 8
        parts.append(mediaNames[code] ?? String(format: "media-0x%04x", code))
    case 0x03: // mouse
        var chunk = modifierString(buf[11])
        let click = [0x01: "click", 0x02: "rclick", 0x04: "mclick"][Int(buf[12])]
        let wheel = [0x01: "wheelup", 0xFF: "wheeldown"][Int(buf[15])]
        for piece in [click, wheel].compactMap({ $0 }) {
            chunk = chunk.isEmpty ? piece : chunk + "-" + piece
        }
        if !chunk.isEmpty { parts.append(chunk) }
    default: // keyboard chords: (modifier, code) pairs from byte 11
        var i = 11
        while i + 1 < 46 {
            let modifiers = buf[i], code = buf[i + 1]
            if modifiers == 0 && code == 0 { break }
            var chunk = modifierString(modifiers)
            if code != 0 {
                let name = keyNames[code] ?? String(format: "0x%02x", code)
                chunk = chunk.isEmpty ? name : chunk + "-" + name
            }
            parts.append(chunk)
            i += 2
        }
    }

    return ReadMapping(keyNumber: buf[2], layer: buf[3],
                       delayMS: Int(buf[5]) << 8 | Int(buf[6]),
                       text: parts.joined(separator: " "))
}

func keyLabel(_ id: UInt8) -> String {
    guard id >= 16 else { return "key \(id)" }
    let n = (Int(id) - 16) / 3 + 1
    let action = ["ccw", "press", "cw"][(Int(id) - 16) % 3]
    return "knob\(n) \(action)"
}

func fetchMappings(layers: [UInt8]) throws -> (keys: UInt8, knobs: UInt8, mappings: [ReadMapping]) {
    let keyboard = try KeyboardDevice.open()
    keyboard.enableReading()

    try keyboard.send(Ch57xRead.deviceTypeQuery)
    let info = keyboard.collectReports(quiet: 0.2, timeout: 2)
    var keys: UInt8 = 12, knobs: UInt8 = 2
    if let first = info.first, first.count > 3, first[1] == 0xfb {
        keys = first[2]
        knobs = first[3]
    }

    var mappings: [ReadMapping] = []
    for l in layers {
        try keyboard.send(Ch57xRead.readLayer(keys: keys, knobs: knobs, layer: l))
        mappings += keyboard.collectReports().compactMap(decodeMapping)
    }
    return (keys, knobs, mappings)
}

func readConfig(layer: UInt8?) throws {
    let layers: [UInt8] = layer.map { [$0] } ?? [1, 2, 3]
    let (keys, knobs, mappings) = try fetchMappings(layers: layers)
    print("device: \(keys) keys, \(knobs) knobs")

    for l in layers {
        let layerMappings = mappings.filter { $0.layer == l }
        print("layer \(l):")
        if layerMappings.isEmpty { print("  (no response)") }
        for mapping in layerMappings {
            let delay = mapping.delayMS > 0 ? " (delay \(mapping.delayMS)ms)" : ""
            print("  \(keyLabel(mapping.keyNumber)): \(mapping.text.isEmpty ? "(unbound)" : mapping.text)\(delay)")
        }
    }
}
