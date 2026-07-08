// Auto-update from GitHub releases (Palanx/CH57x-Whisperer). Both the GUI
// and the agent check the latest release tag on launch and every 6 hours;
// "Restart to Update" downloads the release DMG (floating progress window),
// replaces /Applications/CH57x Whisperer.app in-process (so failures can
// still be reported), then a detached relauncher restarts whatever was
// running before — GUI, agent, or both. Nothing is installed that wasn't
// already in use.

import AppKit
import SwiftUI

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
let installedApp = "/Applications/CH57x Whisperer.app"
private let releaseAPI = "https://api.github.com/repos/Palanx/CH57x-Whisperer/releases/latest"

/// "v1.2.0" vs "1.1.9": numeric per component, missing components count as 0.
func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".").map { Int($0) ?? 0 }
    }
    let a = parts(candidate), b = parts(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

final class Updater: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = Updater()

    enum Host { case gui, agent, cli }
    enum State {
        case checking, upToDate, checkFailed, available
        case downloading(Double), installing
        case failed(String)
    }

    var host: Host = .cli
    @Published private(set) var state: State = .checking { didSet { onChange?() } }
    var onChange: (() -> Void)?
    private(set) var newVersion = ""
    private var dmgURL: URL?
    private var progressObservation: NSKeyValueObservation?
    private var window: NSWindow?

    func startChecking() {
        check()
        Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    /// NSMenuDelegate: re-check when the user opens the Help / status menu, so
    /// a release published after the last 6-hourly check shows up immediately.
    func menuWillOpen(_ menu: NSMenu) {
        switch state {
        case .upToDate, .checkFailed: check()
        default: break // don't disturb an offer or a running download
        }
    }

    @objc func check() {
        switch state { case .downloading, .installing: return; default: break }
        var request = URLRequest(url: URL(string: releaseAPI)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                DispatchQueue.main.async { self.state = .checkFailed }
                return
            }
            let assets = (json["assets"] as? [[String: Any]]) ?? []
            let dmg = assets.compactMap { $0["browser_download_url"] as? String }
                .first { $0.hasSuffix(".dmg") }
            DispatchQueue.main.async {
                if isNewerVersion(tag, than: appVersion), let dmg, let url = URL(string: dmg) {
                    self.newVersion = tag
                    self.dmgURL = url
                    self.state = .available
                } else {
                    self.state = .upToDate
                }
            }
        }.resume()
    }

    @objc func restartToUpdate() {
        guard let dmgURL else { return }
        showWindow()
        state = .downloading(0)
        let task = URLSession.shared.downloadTask(with: dmgURL) { location, _, error in
            guard let location else {
                DispatchQueue.main.async {
                    self.state = .failed("download failed: \(error?.localizedDescription ?? "unknown error")")
                }
                return
            }
            let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("ch57x-update.dmg")
            try? FileManager.default.removeItem(at: dmg)
            do {
                try FileManager.default.moveItem(at: location, to: dmg)
            } catch {
                DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
                return
            }
            DispatchQueue.main.async { self.state = .installing }
            do {
                try self.replaceApp(dmg: dmg) // still on the URLSession queue
                DispatchQueue.main.async { NSApp.terminate(nil) } // relauncher takes over
            } catch {
                DispatchQueue.main.async { self.state = .failed("\(error)") }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
            DispatchQueue.main.async {
                if case .downloading = self.state { self.state = .downloading(progress.fractionCompleted) }
            }
        }
        task.resume()
    }

    // Everything that can fail happens here, before we quit — errors reach the
    // window. Replacing the bundle under running processes is safe: they keep
    // their old inodes until the relauncher restarts them.
    private func replaceApp(dmg: URL) throws {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("ch57x-update-mount").path
        try run("/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-quiet", "-mountpoint", mount)
        defer { try? run("/usr/bin/hdiutil", "detach", mount, "-quiet") }
        let newApp = mount + "/CH57x Whisperer.app"
        guard FileManager.default.fileExists(atPath: newApp) else {
            throw MiniKeyboardError("no app found inside the downloaded DMG")
        }
        // relaunch exactly what is running now (this process included)
        let instances = runningInstances()
        let agentWasRunning = host == .agent || !instances.agents.isEmpty
        let guiWasRunning = host == .gui || !instances.guis.isEmpty
        try? FileManager.default.removeItem(atPath: installedApp)
        try run("/usr/bin/ditto", newApp, installedApp)
        spawnRelauncher(gui: guiWasRunning, agent: agentWasRunning,
                        kill: instances.agents + instances.guis)
    }

    // The launchd-spawned agent's command line is just "ch57x-whisperer agent"
    // (argv[0] from the bundled plist, no path), the Finder-launched GUI is the
    // full bundle path — match by shape, collect pids, never pattern-kill.
    private func runningInstances() -> (agents: [Int], guis: [Int]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fl", "ch57x-whisperer"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var agents: [Int] = [], guis: [Int] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pid = Int(parts[0]),
                  pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let command = parts[1]
            if command.hasSuffix(" agent") {
                agents.append(pid)
            } else if command.contains("CH57x Whisperer.app") || command.hasSuffix(" gui") {
                guis.append(pid)
            }
        }
        return (agents, guis)
    }

    private func spawnRelauncher(gui: Bool, agent: Bool, kill pids: [Int]) {
        let binary = installedApp + "/Contents/MacOS/ch57x-whisperer"
        var script = """
        #!/bin/zsh
        # wait for the updating process to exit, then bounce the rest
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        """
        if !pids.isEmpty { script += "\nkill \(pids.map(String.init).joined(separator: " ")) 2>/dev/null" }
        script += "\nsleep 1"
        if agent {
            // the login item plist is path-based, so it survived the replace;
            // start it again — or plain-spawn if the agent wasn't installed
            script += "\nlaunchctl start ch57x-whisperer.agent 2>/dev/null" +
                      " || nohup '\(binary)' agent >> /tmp/ch57x-agent.log 2>&1 &"
        }
        if gui { script += "\nopen -a 'CH57x Whisperer'" }
        script += "\nrm -- \"$0\"\n"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ch57x-relaunch.sh")
        try? script.write(to: path, atomically: true, encoding: .utf8)
        let process = Process() // detached: children survive our exit
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [path.path]
        try? process.run()
    }

    private func run(_ tool: String, _ args: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
            throw MiniKeyboardError("\(URL(fileURLWithPath: tool).lastPathComponent) failed: " +
                                    message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: progress / error window

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
                             styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "Software Update"
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.contentView = NSHostingView(rootView: UpdateProgressView(updater: self))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func closeWindow() {
        window?.orderOut(nil)
        if case .failed = state { state = .available } // keep offering the update
    }
}

struct UpdateProgressView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(spacing: 12) {
            switch updater.state {
            case .downloading(let fraction):
                Text("Downloading CH57x Whisperer \(updater.newVersion)…").font(.headline)
                ProgressView(value: fraction)
                Text("\(Int(fraction * 100)) %")
                    .monospacedDigit().foregroundStyle(.secondary)
            case .installing:
                Text("Installing \(updater.newVersion)…").font(.headline)
                ProgressView()
                Text("The app restarts by itself when done.")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text("Update Failed").font(.headline)
                Text(message)
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Close") { updater.closeWindow() }
            default:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - `ch57x-whisperer update` (CLI)

func runUpdate() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let updater = Updater.shared
    var started = false
    updater.onChange = {
        switch updater.state {
        case .upToDate:
            print("up to date (v\(appVersion))")
            exit(0)
        case .checkFailed:
            print("error: update check failed — no network, or GitHub unreachable")
            exit(1)
        case .available where !started:
            started = true
            print("updating to \(updater.newVersion)…")
            updater.restartToUpdate()
        case .failed(let message):
            print("error: \(message)")
            exit(1)
        default:
            break
        }
    }
    updater.check()
    app.run()
}
