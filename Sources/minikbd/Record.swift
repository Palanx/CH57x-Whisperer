// Macro recording: listen-only CGEvent tap turns real keystrokes into
// chord tokens compatible with parseChord. Needs the Input Monitoring
// permission (macOS prompts on first use, or grant manually in
// System Settings > Privacy & Security > Input Monitoring).

import CoreGraphics
import Foundation

// macOS virtual keycode (ANSI layout) -> our key names.
let virtualKeyNames: [Int64: String] = [
    0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
    11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
    18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "equal",
    25: "9", 26: "7", 27: "minus", 28: "8", 29: "0",
    30: "rbracket", 31: "o", 32: "u", 33: "lbracket", 34: "i", 35: "p",
    36: "enter", 37: "l", 38: "j", 39: "quote", 40: "k", 41: "semicolon",
    42: "backslash", 43: "comma", 44: "slash", 45: "n", 46: "m", 47: "dot",
    48: "tab", 49: "space", 50: "grave", 51: "backspace", 57: "capslock",
    64: "f17", 79: "f18", 80: "f19", 90: "f20",
    96: "f5", 97: "f6", 98: "f7", 99: "f3", 100: "f8", 101: "f9",
    103: "f11", 105: "f13", 106: "f16", 107: "f14", 109: "f10", 111: "f12", 113: "f15",
    115: "home", 116: "pageup", 117: "delete", 118: "f4", 119: "end",
    120: "f2", 121: "pagedown", 122: "f1",
    123: "left", 124: "right", 125: "down", 126: "up",
]

private final class Recorder {
    var chords: [String] = []
}

func recordChords() throws -> [String] {
    let recorder = Recorder()
    let callback: CGEventTapCallBack = { _, _, event, userInfo in
        let recorder = Unmanaged<Recorder>.fromOpaque(userInfo!).takeUnretainedValue()
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        if keycode == 53 { // esc ends recording
            CFRunLoopStop(CFRunLoopGetMain())
            return Unmanaged.passUnretained(event)
        }
        var tokens: [String] = []
        let flags = event.flags
        if flags.contains(.maskControl) { tokens.append("ctrl") }
        if flags.contains(.maskShift) { tokens.append("shift") }
        if flags.contains(.maskAlternate) { tokens.append("alt") }
        if flags.contains(.maskCommand) { tokens.append("cmd") }
        if let name = virtualKeyNames[keycode] { tokens.append(name) }
        if !tokens.isEmpty {
            let chord = tokens.joined(separator: "-")
            print("  \(recorder.chords.count + 1): \(chord)")
            recorder.chords.append(chord)
        }
        if recorder.chords.count >= Ch57x.maxAccordsPerKey {
            print("(reached the keyboard's limit of \(Ch57x.maxAccordsPerKey) chords)")
            CFRunLoopStop(CFRunLoopGetMain())
        }
        return Unmanaged.passUnretained(event)
    }

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
        callback: callback,
        userInfo: Unmanaged.passUnretained(recorder).toOpaque()
    ) else {
        throw MiniKeyboardError("""
        cannot listen to keyboard — grant Input Monitoring to your terminal:
        System Settings > Privacy & Security > Input Monitoring
        """)
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    print("recording — type the macro, press ESC to finish (max \(Ch57x.maxAccordsPerKey) chords)")
    CFRunLoopRun()
    CGEvent.tapEnable(tap: tap, enable: false)
    return recorder.chords
}
