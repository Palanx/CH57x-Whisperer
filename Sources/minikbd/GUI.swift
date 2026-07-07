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

struct ContentView: View {
    @State private var layer: UInt8 = 1
    @State private var bindings: [UInt8: [UInt8: String]] = [:] // layer -> keyID -> chords
    @State private var selected: UInt8 = 1
    @State private var chordText = ""
    @State private var status = "click Read to load current bindings"
    @State private var ledMode = "backlight"
    @State private var ledColor = "cyan"
    @State private var composerMods: Set<String> = []
    @State private var composerKey = "a"

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
                    The key being edited — click any key or knob action above to select it. \
                    Its binding is one keystroke per word, typed in order: "h i" presses h \
                    then i. Join simultaneous keys with dashes (ctrl-shift-t). Keys that \
                    can't be typed have names: space, minus, f24, kpdot, ñ… Chips below \
                    preview each step: cyan = combination, magenta = named key, orange = \
                    media/mouse action, red = invalid. Write sends it to the keyboard.
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
                            Text(token)
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
                    Label("compose", systemImage: "plus.square.on.square")
                    info("""
                    Build a keystroke without typing it — useful for keys your Mac doesn't \
                    have, like F13–F24. Toggle modifiers, pick the key, then Add step to \
                    append it to the binding field.
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
                Picker("", selection: $composerKey) {
                    ForEach(keyGroups, id: \.0) { group, keys in
                        Section(group) {
                            ForEach(keys, id: \.self) { Text($0) }
                        }
                    }
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
                    Backlight effect for the layer selected above. Pick a mode and a color, \
                    then Set. The keyboard can't report its current LED state, so the pickers \
                    always start from defaults.
                    """)
                }
                .frame(width: 110, alignment: .leading)
                Spacer()
                Picker("", selection: $ledMode) {
                    ForEach(["off", "backlight", "shock", "shock2", "press"], id: \.self) { Text($0) }
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
                Load every binding stored in the keyboard — all 12 keys and both knobs \
                across the 3 layers — and show them in the grid. Do this first; the \
                keyboard keeps its config even unplugged.
                """)
                Spacer()
                Text(status).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding()
        .frame(minWidth: 500)
        .onChange(of: layer) { _ in select(selected) }
    }

    /// visible ⓘ icon; hover it for the explanation
    private func info(_ text: String) -> some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .help(text)
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
        return Button {
            select(id)
        } label: {
            VStack(spacing: 2) {
                Text(title).bold()
                Text(bound.isEmpty ? "—" : bound)
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
    }

    private func read() {
        do {
            let (_, _, mappings) = try fetchMappings(layers: [1, 2, 3])
            bindings = [:]
            for m in mappings {
                bindings[m.layer, default: [:]][m.keyNumber] = m.text
            }
            select(selected)
            status = "read \(mappings.count) bindings"
        } catch {
            status = "\(error)"
        }
    }

    private func setLED() {
        do {
            let spec = ledMode == "off" ? "off" : "\(ledMode)-\(ledColor)"
            let (mode, color) = try parseLED(spec)
            try KeyboardDevice.open().send(Ch57x.setLED(layer: layer, mode: mode, color: color))
            status = "led on layer \(layer) set to \(spec)"
        } catch {
            status = "\(error)"
        }
    }

    private func write() {
        do {
            let chords = chordText.split(separator: " ").map(String.init)
            guard !chords.isEmpty else { throw MiniKeyboardError("type chords first") }
            try KeyboardDevice.open().send(bindMessages(keyID: selected, layer: layer, tokens: chords))
            bindings[layer, default: [:]][selected] = chords.joined(separator: " ")
            status = "bound \(keyLabel(selected)) on layer \(layer)"
        } catch {
            status = "\(error)"
        }
    }
}

func runGUI() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
    window.title = "minikbd"
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
