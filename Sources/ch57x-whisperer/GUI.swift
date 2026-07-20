// SwiftUI configurator: 12-key + 2-knob grid, 3 layer tabs.
// Runs inside the CLI binary (`minikbd gui`) — no app bundle needed.
// ponytail: device I/O blocks the main thread ~1s; move to a Task if it annoys.

import AppKit
import SwiftUI

// Quick-insert actions for the binding field: (bind token, menu label).
// Tokens are the same ones `minikbd read` prints, so they round-trip.
let mediaActions: [(String, String)] = [
    ("playpause", "Play / Pause"), ("next", "Next track"), ("prev", "Previous track"),
    ("stop", "Stop"), ("mute", "Mute"), ("volumeup", "Volume up"), ("volumedown", "Volume down"),
    ("brightnessup", "Brightness up"), ("brightnessdown", "Brightness down"),
    ("multimedia", "Media player"), ("calculator", "Calculator"), ("mycomputer", "My Computer"),
    ("email", "E-mail"), ("wwwhome", "Web home"), ("wwwback", "Web back"),
    ("wwwforward", "Web forward"), ("wwwrefresh", "Web refresh"),
]
let mouseActions: [(String, String)] = [
    ("click", "Left click"), ("rclick", "Right click"), ("mclick", "Middle click"),
    ("wheelup", "Wheel up"), ("wheeldown", "Wheel down"),
]

// Every bindable key for the composer picker — includes keys with no Mac
// equivalent (f13-f24) and ones that are awkward to type (space, minus).
let keyGroups: [(String, [String])] = [
    ("Letters", "abcdefghijklmnopqrstuvwxyz".map(String.init)),
    ("Digits", (0...9).map(String.init)),
    ("F keys", (1...24).map { "f\($0)" }),
    ("Navigation", ["up", "down", "left", "right", "home", "end", "pageup", "pagedown",
                    "insert", "delete"]),
    ("Editing", ["enter", "esc", "backspace", "tab", "space", "capslock"]),
    ("Punctuation", ["minus", "equal", "lbracket", "rbracket", "backslash", "semicolon",
                     "quote", "grave", "comma", "dot", "slash"]),
    ("Keypad", (0...9).map { "kp\($0)" } + ["kpdot", "kpenter", "kpplus", "kpminus",
                                            "kpasterisk", "kpslash", "numlock"]),
    ("Other", ["printscreen", "scrolllock", "pause", "menu"]),
]

// Display-only glyphs: chips, tiles and the picker show `.` / `(kp).` instead of
// dot / kpdot. Bind tokens (field, CLI, read output) are untouched.
let keyGlyphs: [String: String] = {
    var g = ["minus": "-", "equal": "=", "lbracket": "[", "rbracket": "]",
             "backslash": "\\", "semicolon": ";", "quote": "'", "grave": "`",
             "comma": ",", "dot": ".", "slash": "/",
             "kpdot": "(kp).", "kpenter": "(kp)enter", "kpplus": "(kp)+",
             "kpminus": "(kp)-", "kpasterisk": "(kp)*", "kpslash": "(kp)/",
             "kpequal": "(kp)="]
    for i in 0...9 { g["kp\(i)"] = "(kp)\(i)" }
    return g
}()

/// shift-kpdot -> shift-(kp). ; tokens without a glyph pass through unchanged
func displayToken(_ token: String) -> String {
    let parts = token.split(separator: "-").map(String.init)
    guard let last = parts.last, let glyph = keyGlyphs[last.lowercased()] else { return token }
    return (parts.dropLast() + [glyph]).joined(separator: "-")
}

struct ContentView: View {
    @State private var layer: UInt8 = 1
    @State private var bindings: [UInt8: [UInt8: String]] = [:] // layer -> keyID -> chords
    @State private var delays: [UInt8: [UInt8: Int]] = [:] // layer -> keyID -> ms between steps
    @State private var delayMS = 0
    @State private var selected: UInt8 = 1
    @State private var chordText = ""
    @State private var status = "click Read to load current bindings"
    @State private var ledMode = "off"
    @State private var ledColor = "cyan"
    @State private var composerMods: Set<String> = []
    @State private var composerKey = "a"
    @State private var keyPickerShown = false
    @State private var keyQuery = ""

    var body: some View {
        VStack(spacing: 12) {
            Picker("Layer", selection: $layer) {
                ForEach(1...3, id: \.self) { Text("Layer \($0)").tag(UInt8($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                knob(1)
                Spacer()
                knob(2)
            }

            Label("keys", systemImage: "square.grid.4x3.fill")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                ForEach(1...12, id: \.self) { n in
                    slot(UInt8(n), title: "\(n)")
                }
            }

            Divider()

            HStack {
                HStack(spacing: 4) {
                    Text(keyLabel(selected)).bold()
                    info("""
                    **Binding field** — edits the key selected above.

                    One keystroke per word, typed in order:
                    • `h i` types *h*, then *i*
                    • `ctrl-shift-t` presses the keys together
                    • un-typeable keys have names: `space`, `minus`, `f24`, `kpdot`, `ñ`

                    The chips below preview each step:
                    cyan = combination · magenta = named key
                    orange = media/mouse · red = invalid

                    Chips show punctuation and keypad keys as the real \
                    character: `dot` → **.** and `kpdot` → **(kp).** \
                    The field itself always uses the names.

                    **Write** sends the binding to the keyboard.
                    """)
                }
                .fixedSize()
                TextField("chords, e.g. ctrl-shift-t f13 — or pick an action →", text: $chordText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(write)
                Menu {
                    Section("Media") {
                        ForEach(mediaActions, id: \.0) { token, label in
                            Button(label) { chordText = token }
                        }
                    }
                    Section("Mouse") {
                        ForEach(mouseActions, id: \.0) { token, label in
                            Button(label) { chordText = token }
                        }
                    }
                } label: {
                    Label("actions", systemImage: "wand.and.stars")
                }
                .fixedSize()
                .help("""
                Bind a media key or mouse action instead of keystrokes — play/pause, \
                volume, brightness, clicks, scroll wheel… Picking one replaces the field: \
                the keyboard stores a single action per key (modifiers allowed, e.g. \
                ctrl-wheelup).
                """)
                Button("Write", action: write)
                    .help("Write the field's binding to the selected key. It persists inside the keyboard.")
            }

            HStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                            Text(displayToken(token))
                                .font(.caption.monospaced())
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(chipColor(token).opacity(0.18), in: Capsule())
                                .foregroundStyle(chipColor(token))
                        }
                    }
                }
                if !tokens.isEmpty {
                    Text("\(tokens.count)/\(Ch57x.maxAccordsPerKey)")
                        .font(.caption)
                        .foregroundStyle(tokens.count > Ch57x.maxAccordsPerKey ? .red : .secondary)
                }
            }
            .frame(height: 20) // reserved so the window doesn't jump when chips appear

            HStack {
                HStack(spacing: 4) {
                    Label("delay", systemImage: "timer")
                    info("""
                    **Delay between steps** — a property of the selected key, \
                    not a step in the sequence.

                    The keyboard pauses this many milliseconds between *every* \
                    keystroke of this key's macro. One value per key, \
                    0–\(Ch57x.maxDelayMS) ms; 0 means full speed.

                    It is stored in the keyboard together with the binding \
                    when you press **Write**.
                    """)
                }
                .frame(width: 110, alignment: .leading)
                TextField("0", value: $delayMS, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onChange(of: delayMS) { v in
                        delayMS = min(max(0, v), Ch57x.maxDelayMS)
                    }
                Stepper("", value: $delayMS, in: 0...Ch57x.maxDelayMS, step: 50)
                    .labelsHidden()
                Text("ms between steps").foregroundStyle(.secondary)
                Spacer()
            }

            HStack {
                HStack(spacing: 4) {
                    Label("compose", systemImage: "plus.square.on.square")
                    info("""
                    **Chord composer** — build a keystroke without typing it. \
                    Useful for keys your Mac doesn't have, like F13–F24.

                    1. Toggle the modifiers you want
                    2. Pick the key (the list is searchable)
                    3. **Add step** appends it to the binding field
                    """)
                }
                .frame(width: 110, alignment: .leading)
                ForEach(["ctrl", "shift", "alt", "cmd"], id: \.self) { mod in
                    Toggle(mod, isOn: Binding(
                        get: { composerMods.contains(mod) },
                        set: { on in if on { composerMods.insert(mod) } else { composerMods.remove(mod) } }
                    ))
                    .toggleStyle(.button)
                }
                Button {
                    keyQuery = ""
                    keyPickerShown = true
                } label: {
                    HStack {
                        Text(displayToken(composerKey))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .frame(minWidth: 70)
                }
                .popover(isPresented: $keyPickerShown, arrowEdge: .bottom) {
                    VStack(spacing: 6) {
                        TextField("search key…", text: $keyQuery)
                            .textFieldStyle(.roundedBorder)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(keyGroups, id: \.0) { group, keys in
                                    let hits = keys.filter {
                                        keyQuery.isEmpty || $0.contains(keyQuery.lowercased())
                                            || displayToken($0).contains(keyQuery.lowercased())
                                    }
                                    if !hits.isEmpty {
                                        Text(group).font(.caption).foregroundStyle(.secondary)
                                            .padding(.top, 4)
                                        ForEach(hits, id: \.self) { key in
                                            Button(displayToken(key)) {
                                                composerKey = key
                                                keyPickerShown = false
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(key == composerKey ? Color.accentColor : .primary)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .frame(width: 190, height: 280)
                }
                Button("Add step") {
                    let mods = ["ctrl", "shift", "alt", "cmd"].filter(composerMods.contains)
                    let token = (mods + [composerKey]).joined(separator: "-")
                    chordText = chordText.isEmpty ? token : chordText + " " + token
                }
            }

            Divider()

            HStack {
                HStack(spacing: 4) {
                    Label("led", systemImage: "lightbulb")
                    info("""
                    **LED backlight** — for the layer selected above.

                    Pick a mode and a color, then **Set**. \
                    The dot previews your choice.

                    **Limitation:** the keyboard can't report its LED \
                    state, so this display is a memory, not a readout — \
                    it shows the last value set from this app (GUI or \
                    `ch57x-whisperer led`), per layer. If the LEDs were changed \
                    any other way, or never set from here, it shows *off* \
                    while the real LEDs may glow. Press **Set** to bring \
                    both back in sync.
                    """)
                }
                .frame(width: 110, alignment: .leading)
                LEDDot(color: ledSwiftUIColor, mode: ledMode)
                    .id("\(layer)-\(ledMode)-\(ledColor)") // restart the breathing on any change
                Spacer()
                Picker("", selection: $ledMode) {
                    ForEach(["off", "backlight", "sweep", "sweep-reverse", "press"], id: \.self) { Text($0) }
                }
                .frame(width: 140)
                Picker("", selection: $ledColor) {
                    ForEach(ledColors.sorted { $0.value < $1.value }.map(\.key), id: \.self) { Text($0) }
                }
                .frame(width: 120)
                .disabled(ledMode == "off")
                Spacer()
                Button("Set", action: setLED)
            }

            Divider()

            HStack {
                Button("Read from keyboard", action: read)
                info("""
                **Read from keyboard** — loads every stored binding: \
                12 keys + both knobs, all 3 layers.

                Do this first. The keyboard keeps its config even unplugged, \
                so what you see here is what it will really do.
                """)
                Spacer()
                Text(status).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding()
        .frame(minWidth: 500)
        .onChange(of: layer) { _ in
            select(selected)
            loadLED()
        }
        .onAppear(perform: loadLED)
    }

    /// visible ⓘ icon; click for a popover, hover for the classic tooltip
    private func info(_ text: String) -> some View {
        InfoButton(text: text)
    }

    private var tokens: [String] {
        chordText.split(separator: " ").map(String.init)
    }

    /// cyan: combination (shift-f12 — wins over magenta); magenta: named key spelled
    /// as a word (space, f24, kpdot) or bare modifier; orange: media/mouse action;
    /// red: won't parse — catches typing "-" instead of "minus" before Write.
    private func chipColor(_ token: String) -> Color {
        let lower = token.lowercased()
        if isActionToken(lower) { return .orange }
        guard (try? parseChord(lower)) != nil else { return .red }
        let parts = lower.split(separator: "-").map(String.init)
        if parts.count > 1 { return .cyan }
        if modifierBits[lower] != nil || (lower.count > 1 && keyCodes[lower] != nil) {
            return Color(red: 0.9, green: 0.2, blue: 0.9)
        }
        return .primary
    }

    private func knob(_ n: Int) -> some View {
        let base = UInt8(16 + 3 * (n - 1))
        return VStack(spacing: 4) {
            Label("knob \(n)", systemImage: "dial.medium").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                slot(base, title: "left").frame(width: 70)
                slot(base + 1, title: "press").frame(width: 70)
                slot(base + 2, title: "right").frame(width: 70)
            }
        }
    }

    private func slot(_ id: UInt8, title: String) -> some View {
        let bound = bindings[layer]?[id] ?? ""
        let delay = delays[layer]?[id] ?? 0
        return Button {
            select(id)
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    Text(title).bold()
                    if delay > 0, !bound.isEmpty {
                        Text("⏱\(delay)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(bound.isEmpty ? "—"
                     : bound.split(separator: " ").map { displayToken(String($0)) }.joined(separator: " "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.bordered)
        .tint(selected == id ? .accentColor : nil)
    }

    private func select(_ id: UInt8) {
        selected = id
        chordText = bindings[layer]?[id] ?? ""
        delayMS = delays[layer]?[id] ?? 0
    }

    private func read() {
        do {
            let (_, _, mappings) = try fetchMappings(layers: [1, 2, 3])
            bindings = [:]
            delays = [:]
            for m in mappings {
                bindings[m.layer, default: [:]][m.keyNumber] = m.text
                delays[m.layer, default: [:]][m.keyNumber] = m.delayMS
            }
            select(selected)
            status = "read \(mappings.count) bindings"
        } catch {
            status = "\(error)"
        }
    }

    private var ledSwiftUIColor: Color {
        switch ledColor {
        case "white": .white
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "cyan": .cyan
        case "blue": .blue
        default: .purple
        }
    }

    /// The device can't report its LED state, so remember what we last set per layer.
    private func loadLED() {
        let saved = UserDefaults.standard.string(forKey: "led.layer\(layer)")?
            .split(separator: " ").map(String.init) ?? []
        ledMode = saved.count == 2 ? saved[0] : "off"
        ledColor = saved.count == 2 ? saved[1] : "cyan"
    }

    private func setLED() {
        do {
            let spec = ledMode == "off" ? "off" : "\(ledMode)-\(ledColor)"
            let (mode, color) = try parseLED(spec)
            try KeyboardDevice.open().send(Ch57x.setLED(layer: layer, mode: mode, color: color))
            UserDefaults.standard.set("\(ledMode) \(ledColor)", forKey: "led.layer\(layer)")
            status = "led on layer \(layer) set to \(spec)"
        } catch {
            status = "\(error)"
        }
    }

    private func write() {
        do {
            let chords = chordText.split(separator: " ").map(String.init)
            guard !chords.isEmpty else { throw MiniKeyboardError("type chords first") }
            try KeyboardDevice.open().send(bindMessages(keyID: selected, layer: layer,
                                                        tokens: chords, delayMS: delayMS))
            bindings[layer, default: [:]][selected] = chords.joined(separator: " ")
            delays[layer, default: [:]][selected] = delayMS
            status = "bound \(keyLabel(selected)) on layer \(layer)"
        } catch {
            status = "\(error)"
        }
    }
}

/// tiny LED preview, one look per mode: off = gray, backlight = steady glow,
/// sweep/sweep-reverse = pulsing, press = dim until a key would light it.
/// The real sweep runs key by key across the pad; a single dot can't show that, so the
/// pulse just means "this mode animates" rather than mimicking it.
private struct LEDDot: View {
    let color: Color
    let mode: String
    @State private var dim = false

    private var breathDuration: Double? {
        switch mode {
        case "sweep", "sweep-reverse": 1.0
        default: nil // off, backlight, press: static
        }
    }

    var body: some View {
        let off = mode == "off"
        let press = mode == "press"
        Circle()
            .fill(off ? Color.gray.opacity(0.35) : color)
            .frame(width: 11, height: 11)
            .shadow(color: off || press ? .clear : color.opacity(0.8), radius: dim ? 1 : 5)
            .opacity(off ? 1 : press ? 0.35 : dim ? 0.25 : 1)
            .onAppear {
                guard let duration = breathDuration else { return }
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

private struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(.init(text)) // .init: render the markdown in the string
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
        }
    }
}

// MARK: - App icon
// No bundle, no assets: the Dock icon is drawn in code — the macropad face
// with whisper waves drifting down onto it, one key lit because it listened.

func appIcon(size: CGFloat = 512) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 512 // design in 512-point space
        func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(roundedRect: NSRect(x: x * s, y: y * s, width: w * s, height: h * s),
                         xRadius: r * s, yRadius: r * s)
        }
        func gray(_ white: CGFloat) -> NSColor { NSColor(calibratedWhite: white, alpha: 1) }

        // squircle body = the keyboard itself
        let body = rr(32, 32, 448, 448, 104)
        NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.22, alpha: 1),
                   ending: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.12, alpha: 1))!
            .draw(in: body, angle: -90)

        // everything below stays inside the squircle
        body.addClip()

        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }

        // the whisperer: parted lips, emoji-flat so they survive Dock sizes,
        // drawn FIRST so the lower lip slips behind the keyboard.
        // mpt remaps the shape (tuned around (394, 245)) to its place and scale.
        func mpt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            pt(256 + (x - 394) * 1.25, 358 + (y - 245) * 1.25)
        }
        let lipDark = NSColor(calibratedRed: 0.78, green: 0.12, blue: 0.32, alpha: 1)
        let lipLight = NSColor(calibratedRed: 0.93, green: 0.25, blue: 0.42, alpha: 1)

        let lower = NSBezierPath() // its bottom hides behind the pad
        lower.move(to: mpt(322, 256))
        lower.curve(to: mpt(394, 240), controlPoint1: mpt(338, 247), controlPoint2: mpt(368, 241))
        lower.curve(to: mpt(466, 256), controlPoint1: mpt(420, 241), controlPoint2: mpt(450, 247))
        lower.curve(to: mpt(394, 178), controlPoint1: mpt(446, 202), controlPoint2: mpt(424, 178))
        lower.curve(to: mpt(322, 256), controlPoint1: mpt(364, 178), controlPoint2: mpt(342, 202))
        lower.close()
        lipLight.setFill()
        lower.fill()

        let upper = NSBezierPath() // cupid's bow on top
        upper.move(to: mpt(322, 256))
        upper.curve(to: mpt(372, 296), controlPoint1: mpt(334, 278), controlPoint2: mpt(356, 296))
        upper.curve(to: mpt(394, 289), controlPoint1: mpt(382, 296), controlPoint2: mpt(387, 289))
        upper.curve(to: mpt(416, 296), controlPoint1: mpt(401, 289), controlPoint2: mpt(406, 296))
        upper.curve(to: mpt(466, 256), controlPoint1: mpt(432, 296), controlPoint2: mpt(454, 278))
        upper.curve(to: mpt(322, 256), controlPoint1: mpt(428, 261), controlPoint2: mpt(360, 261))
        upper.close()
        lipDark.setFill()
        upper.fill()

        // the device, landscape, centered, over the lower lip:
        // 4x3 keys + knob column at right
        let pad = rr(66, 88, 380, 240, 26)
        gray(0.17).setFill()
        pad.fill()
        pad.lineWidth = 5 * s
        gray(0.32).setStroke()
        pad.stroke()

        let lit = NSColor.cyan
        for row in 0..<3 {
            for col in 0..<4 {
                let key = rr(81 + CGFloat(col) * 74, 103 + CGFloat(row) * 74, 62, 62, 13)
                if row == 2, col == 0 { // top-left key heard the whisper
                    NSGraphicsContext.current?.cgContext.setShadow(
                        offset: .zero, blur: 18 * s, color: lit.cgColor)
                    lit.withAlphaComponent(0.9).setFill()
                    key.fill()
                    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0)
                } else {
                    gray(0.26).setFill()
                    key.fill()
                }
            }
        }

        for cy: CGFloat in [260, 156] {
            let knob = NSBezierPath(ovalIn: NSRect(x: 378 * s, y: (cy - 24) * s,
                                                   width: 48 * s, height: 48 * s))
            gray(0.30).setFill()
            knob.fill()
            knob.lineWidth = 4 * s
            gray(0.46).setStroke()
            knob.stroke()
            let mark = NSBezierPath()
            mark.move(to: pt(402, cy))
            mark.line(to: pt(414, cy + 12))
            mark.lineWidth = 6 * s
            mark.lineCapStyle = .round
            gray(0.78).setStroke()
            mark.stroke()
        }
        return true
    }
}

// Agent ("Action Whisperer") app icon: the whisperer's lips from mouthIcon(),
// but full-color like appIcon() and centered on the same squircle with no
// keyboard — the app that acts on what the keyboard says. The lip curves are
// the frozen shared design (also in appIcon/mouthIcon); only the transform
// differs (2x, centered, whole lower lip shown since no pad hides it).
func agentIcon(size: CGFloat = 512) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 512
        func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(roundedRect: NSRect(x: x * s, y: y * s, width: w * s, height: h * s),
                         xRadius: r * s, yRadius: r * s)
        }
        let body = rr(32, 32, 448, 448, 104)
        NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.22, alpha: 1),
                   ending: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.12, alpha: 1))!
            .draw(in: body, angle: -90)
        body.addClip()

        func mpt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: (256 + (x - 394) * 2.0) * s, y: (256 + (y - 237) * 2.0) * s)
        }
        let lipDark = NSColor(calibratedRed: 0.78, green: 0.12, blue: 0.32, alpha: 1)
        let lipLight = NSColor(calibratedRed: 0.93, green: 0.25, blue: 0.42, alpha: 1)

        let lower = NSBezierPath()
        lower.move(to: mpt(322, 256))
        lower.curve(to: mpt(394, 240), controlPoint1: mpt(338, 247), controlPoint2: mpt(368, 241))
        lower.curve(to: mpt(466, 256), controlPoint1: mpt(420, 241), controlPoint2: mpt(450, 247))
        lower.curve(to: mpt(394, 178), controlPoint1: mpt(446, 202), controlPoint2: mpt(424, 178))
        lower.curve(to: mpt(322, 256), controlPoint1: mpt(364, 178), controlPoint2: mpt(342, 202))
        lower.close()
        lipLight.setFill()
        lower.fill()

        let upper = NSBezierPath()
        upper.move(to: mpt(322, 256))
        upper.curve(to: mpt(372, 296), controlPoint1: mpt(334, 278), controlPoint2: mpt(356, 296))
        upper.curve(to: mpt(394, 289), controlPoint1: mpt(382, 296), controlPoint2: mpt(387, 289))
        upper.curve(to: mpt(416, 296), controlPoint1: mpt(401, 289), controlPoint2: mpt(406, 296))
        upper.curve(to: mpt(466, 256), controlPoint1: mpt(432, 296), controlPoint2: mpt(454, 278))
        upper.curve(to: mpt(322, 256), controlPoint1: mpt(428, 261), controlPoint2: mpt(360, 261))
        upper.close()
        lipDark.setFill()
        upper.fill()
        return true
    }
}

func runGUI() {
    // ICON_PNG=<path>: write the icon and exit (used to render docs/icon.png)
    if let out = ProcessInfo.processInfo.environment["ICON_PNG"] {
        let rep = NSBitmapImageRep(data: appIcon(size: 1024).tiffRepresentation!)!
        try! rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: out))
        print("icon written to \(out)")
        exit(0)
    }
    // AGENT_ICON_PNG=<path>: same, for the Action Whisperer helper's icon.
    if let out = ProcessInfo.processInfo.environment["AGENT_ICON_PNG"] {
        let rep = NSBitmapImageRep(data: agentIcon(size: 1024).tiffRepresentation!)!
        try! rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: out))
        print("agent icon written to \(out)")
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.applicationIconImage = appIcon()

    // minimal main menu: Quit + Help ▸ update status ("Up to Date (v…)" when
    // current, "Restart to Update (v…)" when a GitHub release is newer)
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit CH57x Whisperer",
                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu

    // Agent controls (packaged installs only — source builds use the CLI).
    if Bundle.main.bundlePath.hasSuffix(".app") {
        let agentMenuItem = NSMenuItem()
        mainMenu.addItem(agentMenuItem)
        let agentMenu = NSMenu(title: "Agent")
        agentMenu.addItem(withTitle: "Start Action Whisperer",
                          action: #selector(AgentControl.startAgent), keyEquivalent: "")
            .target = AgentControl.shared
        agentMenu.addItem(withTitle: "Start at Login",
                          action: #selector(AgentControl.startAtLogin), keyEquivalent: "")
            .target = AgentControl.shared
        agentMenu.addItem(withTitle: "Remove from Login",
                          action: #selector(AgentControl.removeFromLogin), keyEquivalent: "")
            .target = AgentControl.shared
        agentMenuItem.submenu = agentMenu
    }

    let helpMenuItem = NSMenuItem()
    mainMenu.addItem(helpMenuItem)
    let helpMenu = NSMenu(title: "Help")
    let updateItem = helpMenu.addItem(withTitle: "Checking for Updates…",
                                      action: nil, keyEquivalent: "")
    helpMenuItem.submenu = helpMenu
    app.mainMenu = mainMenu

    // automatic updates only for .app installs — source builds shouldn't
    // race their embedded version against GitHub releases
    if Bundle.main.bundlePath.hasSuffix(".app") {
        let updater = Updater.shared
        updater.host = .gui
        updater.onChange = {
            switch updater.state {
            case .checking:
                updateItem.title = "Checking for Updates…"
                updateItem.action = nil
            case .upToDate:
                updateItem.title = "Up to Date (v\(appVersion))"
                updateItem.action = nil
            case .checkFailed: // clickable retry
                updateItem.title = "Check for Updates"
                updateItem.target = updater
                updateItem.action = #selector(Updater.check)
            case .available, .failed:
                updateItem.title = "Restart to Update (\(updater.newVersion))"
                updateItem.target = updater
                updateItem.action = #selector(Updater.restartToUpdate)
            case .downloading, .installing:
                updateItem.title = "Updating…"
                updateItem.action = nil
            }
        }
        updater.startChecking()
        // AppKit owns the delegate of menus titled "Help" (search field), so
        // NSMenuDelegate never fires there — watch menu-bar tracking instead
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                               object: mainMenu, queue: nil) { _ in
            updater.menuWillOpen(helpMenu)
        }
    } else {
        updateItem.title = "Updates: app installs only"
    }
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
    window.title = "CH57x Whisperer"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: ContentView())
    window.center()
    window.makeKeyAndOrderFront(nil)
    NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: nil
    ) { _ in app.terminate(nil) }
    app.activate(ignoringOtherApps: true)
    app.run()
}
