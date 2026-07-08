// Host-side action engine: `ch57x-whisperer agent` runs a menu-bar process
// that registers F13-F20 global hotkeys via Carbon RegisterEventHotKey and
// runs one zsh script per hotkey from ~/.config/ch57x-whisperer/actions/.
//
// RegisterEventHotKey needs NO permission (no Input Monitoring, no
// Accessibility, no TCC prompt): the system delivers only the registered
// keys, so the process cannot observe typing. Safe for managed/corporate
// Macs — the record command's CGEvent tap is never used here.

import AppKit
import Carbon
import ServiceManagement

let actionsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/ch57x-whisperer/actions")

// macOS virtual keycodes (kVK_F13...kVK_F20); F21-F24 have none, hence the cap.
let hotkeyFKeys: [String: UInt32] = [
    "f13": 105, "f14": 107, "f15": 113, "f16": 106,
    "f17": 64, "f18": 79, "f19": 80, "f20": 90,
]
let hotkeyModifiers: [String: UInt32] = [
    "ctrl": UInt32(controlKey), "shift": UInt32(shiftKey),
    "alt": UInt32(optionKey), "opt": UInt32(optionKey),
    "cmd": UInt32(cmdKey), "win": UInt32(cmdKey),
]

/// "cmd-f13" -> (keycode, carbon modifier mask); nil if not a bindable hotkey name.
func parseHotkeyName(_ name: String) -> (code: UInt32, mods: UInt32)? {
    let parts = name.lowercased().split(separator: "-").map(String.init)
    guard let last = parts.last, let code = hotkeyFKeys[last] else { return nil }
    var mods: UInt32 = 0
    for part in parts.dropLast() {
        guard let m = hotkeyModifiers[part] else { return nil }
        mods |= m
    }
    return (code, mods)
}

// Menu bar icon: just the whispering lips from appIcon(), as a template image
// so it adapts to light/dark menu bars. `update: true` adds a down-arrow
// badge (top-right, Ollama-style) meaning "update available".
func mouthIcon(update: Bool = false) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        // lip curves live in appIcon's "mouth space" (x 322-466, y 178-296);
        // map that box into the 18pt square, vertically centered. The lower
        // lip (y < 256) is squashed to 60% depth — full size overwhelms 18pt.
        func mpt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            let sy = y < 256 ? 256 - (256 - y) * 0.6 : y
            return NSPoint(x: (x - 322) * 18 / 144, y: (sy - 209.2) * 18 / 144 + 3.6)
        }
        let lower = NSBezierPath()
        lower.move(to: mpt(322, 256))
        lower.curve(to: mpt(394, 240), controlPoint1: mpt(338, 247), controlPoint2: mpt(368, 241))
        lower.curve(to: mpt(466, 256), controlPoint1: mpt(420, 241), controlPoint2: mpt(450, 247))
        lower.curve(to: mpt(394, 178), controlPoint1: mpt(446, 202), controlPoint2: mpt(424, 178))
        lower.curve(to: mpt(322, 256), controlPoint1: mpt(364, 178), controlPoint2: mpt(342, 202))
        lower.close()
        let upper = NSBezierPath()
        upper.move(to: mpt(322, 256))
        upper.curve(to: mpt(372, 296), controlPoint1: mpt(334, 278), controlPoint2: mpt(356, 296))
        upper.curve(to: mpt(394, 289), controlPoint1: mpt(382, 296), controlPoint2: mpt(387, 289))
        upper.curve(to: mpt(416, 296), controlPoint1: mpt(401, 289), controlPoint2: mpt(406, 296))
        upper.curve(to: mpt(466, 256), controlPoint1: mpt(432, 296), controlPoint2: mpt(454, 278))
        upper.curve(to: mpt(322, 256), controlPoint1: mpt(428, 261), controlPoint2: mpt(360, 261))
        upper.close()
        NSColor.black.setFill()
        lower.fill()
        upper.fill()

        if update {
            let ctx = NSGraphicsContext.current
            // gap ring so the badge separates from the lips, then the badge,
            // then the arrow knocked out of it
            ctx?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: NSRect(x: 9, y: 9, width: 10, height: 10)).fill()
            ctx?.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: NSRect(x: 10, y: 10, width: 8, height: 8)).fill()
            ctx?.compositingOperation = .destinationOut
            NSBezierPath(rect: NSRect(x: 13.4, y: 13.2, width: 1.2, height: 2.6)).fill()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 14, y: 11.4))
            arrow.line(to: NSPoint(x: 12.2, y: 13.4))
            arrow.line(to: NSPoint(x: 15.8, y: 13.4))
            arrow.close()
            arrow.fill()
            ctx?.compositingOperation = .sourceOver
        }
        return true
    }
    image.isTemplate = true // menu bar tints it for light/dark
    return image
}

private final class HotkeyAgent: NSObject {
    struct Binding {
        let token: String
        let script: URL
        var ref: EventHotKeyRef?
    }

    var bindings: [Binding] = []
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    func start() {
        statusItem.button?.image = mouthIcon()
        statusItem.button?.toolTip = "CH57x Whisperer agent"

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hotkeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            Unmanaged<HotkeyAgent>.fromOpaque(userData!).takeUnretainedValue()
                .fire(index: Int(hotkeyID.id))
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        // automatic updates only for .app installs (same rule as the GUI)
        if Bundle.main.bundlePath.hasSuffix(".app") {
            Updater.shared.host = .agent
            Updater.shared.onChange = { [weak self] in self?.refreshUpdateUI() }
            Updater.shared.startChecking()
        }
        reload()
    }

    func refreshUpdateUI() {
        let badge: Bool
        switch Updater.shared.state {
        case .available, .downloading, .installing, .failed: badge = true
        default: badge = false
        }
        statusItem.button?.image = mouthIcon(update: badge)
        rebuildMenu()
    }

    @objc func reload() {
        for binding in bindings where binding.ref != nil { UnregisterEventHotKey(binding.ref) }
        bindings = []

        try? FileManager.default.createDirectory(at: actionsDir, withIntermediateDirectories: true)
        let scripts = ((try? FileManager.default.contentsOfDirectory(atPath: actionsDir.path)) ?? [])
            .filter { $0.hasSuffix(".sh") }.sorted()
        if scripts.isEmpty { writeExampleScript() }

        for script in scripts {
            let token = String(script.dropLast(3))
            guard let (code, mods) = parseHotkeyName(token) else {
                print("skipping \(script): name must be [ctrl-][shift-][alt-][cmd-]f13...f20")
                continue
            }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x63683578), // "ch5x"
                                   id: UInt32(bindings.count))
            let status = RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref)
            guard status == noErr else {
                print("cannot register \(token) (in use by another app?)")
                continue
            }
            bindings.append(Binding(token: token, script: actionsDir.appendingPathComponent(script),
                                    ref: ref))
            print("registered \(token) -> \(script)")
        }
        rebuildMenu()
    }

    func fire(index: Int) {
        guard bindings.indices.contains(index) else { return }
        let binding = bindings[index]
        let front = NSWorkspace.shared.frontmostApplication
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [binding.script.path]
        var env = ProcessInfo.processInfo.environment
        env["FRONT_APP"] = front?.bundleIdentifier ?? ""
        env["FRONT_APP_NAME"] = front?.localizedName ?? ""
        process.environment = env
        do { try process.run() } catch {
            print("error running \(binding.script.lastPathComponent): \(error)")
        }
    }

    @objc func fireFromMenu(_ sender: NSMenuItem) { fire(index: sender.tag) }
    @objc func openFolder() { NSWorkspace.shared.open(actionsDir) }

    func rebuildMenu() {
        let menu = NSMenu()
        switch Updater.shared.state {
        case .available, .failed:
            let item = menu.addItem(withTitle: "Restart to Update (\(Updater.shared.newVersion))",
                                    action: #selector(Updater.restartToUpdate), keyEquivalent: "")
            item.target = Updater.shared
            menu.addItem(.separator())
        case .downloading, .installing:
            menu.addItem(withTitle: "Updating…", action: nil, keyEquivalent: "")
            menu.addItem(.separator())
        default:
            break // up to date / still checking: no update row, badge-free mouth
        }
        if bindings.isEmpty {
            menu.addItem(withTitle: "No scripts in ~/.config/ch57x-whisperer/actions",
                         action: nil, keyEquivalent: "")
        }
        for (i, binding) in bindings.enumerated() {
            let item = menu.addItem(withTitle: "\(binding.token)  —  \(binding.script.lastPathComponent)",
                                    action: #selector(fireFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reload Scripts", action: #selector(reload), keyEquivalent: "r")
            .target = self
        menu.addItem(withTitle: "Open Actions Folder", action: #selector(openFolder), keyEquivalent: "o")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Agent", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        if Bundle.main.bundlePath.hasSuffix(".app") {
            menu.delegate = Updater.shared // re-check for updates on menu open
        }
        statusItem.menu = menu
    }

    func writeExampleScript() {
        let example = actionsDir.appendingPathComponent("f13.sh.example")
        guard !FileManager.default.fileExists(atPath: example.path) else { return }
        try? """
        #!/bin/zsh
        # Runs when F13 is pressed. Rename to f13.sh to activate (then Reload
        # Scripts in the menu bar). Name pattern: [ctrl-][shift-][alt-][cmd-]f13...f20.sh
        # The agent sets FRONT_APP (bundle id) and FRONT_APP_NAME before running.

        open -a "Rider"   # focus-or-launch — open -a does both

        case "$FRONT_APP" in
          com.jetbrains.rider) cd ~/Work/game && dotnet build ;;
          com.unity3d.*)       echo "already in Unity" ;;
          *)                   ;;
        esac
        """.write(to: example, atomically: true, encoding: .utf8)
    }
}

// MARK: - launchd install

// Plain ~/Library/LaunchAgents plist, on purpose. SMAppService would show the
// app's icon in Login Items, but it pins the app's code signature — with our
// ad-hoc signing every update looks like tampering and launchd kills the
// agent with EX_CONFIG, and BTM never refreshes the pin (verified 2026-07-08,
// same wall as Apple forums #795022). A path-based plist survives every
// update. The pretty Settings icon needs a Developer ID; revisit then.
private let launchAgentLabel = "ch57x-whisperer.agent"
private let launchAgentPlist = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")

private func launchctl(_ args: [String], quiet: Bool = false) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = args
    if quiet { process.standardError = FileHandle.nullDevice }
    try? process.run()
    process.waitUntilExit()
}

private func removeLegacyLaunchAgent() {
    guard FileManager.default.fileExists(atPath: launchAgentPlist.path) else { return }
    launchctl(["unload", launchAgentPlist.path], quiet: true)
    try? FileManager.default.removeItem(at: launchAgentPlist)
    print("removed \(launchAgentPlist.path)")
}

private func installLaunchAgent() throws {
    // clean up any SMAppService registration from earlier experiments
    try? SMAppService.agent(plistName: "com.palanx.ch57x-whisperer.agent.plist").unregister()
    let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let plist: [String: Any] = [
        "Label": launchAgentLabel,
        "ProgramArguments": [binary, "agent"],
        "RunAtLoad": true,
        "StandardOutPath": "/tmp/ch57x-agent.log",
        "StandardErrorPath": "/tmp/ch57x-agent.log",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: launchAgentPlist)
    launchctl(["unload", launchAgentPlist.path], quiet: true) // replace a previous install cleanly
    launchctl(["load", "-w", launchAgentPlist.path])
    print("""
    installed \(launchAgentPlist.path)
    runs at login: \(binary) agent   (log: /tmp/ch57x-agent.log)
    """)
}

private func uninstallLaunchAgent() {
    try? SMAppService.agent(plistName: "com.palanx.ch57x-whisperer.agent.plist").unregister()
    removeLegacyLaunchAgent()
}

func runAgent(args: [String]) throws {
    switch args.first {
    case "--install": try installLaunchAgent(); return
    case "--uninstall": uninstallLaunchAgent(); return
    case .some(let bad): throw MiniKeyboardError("unknown agent option '\(bad)'")
    case nil: break
    }
    setvbuf(stdout, nil, _IOLBF, 0) // line-buffer so the LaunchAgent log is live
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    let agent = HotkeyAgent()
    agent.start()
    print("agent running — scripts: \(actionsDir.path)")
    app.run()
}
