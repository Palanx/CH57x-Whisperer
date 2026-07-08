# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Native macOS (Apple Silicon) configurator for a CH57x-based mini keyboard: 12 keys + 2 clickable knobs, 3 layers, USB VID/PID `1189:8840`. It replaces the vendor's x86_64 Qt app ("MINI_KEYBOARD"). Swift + IOKit HID only — no hidapi, no third-party dependencies.

## Commands

- Build: `swift build`
- Run: `swift run minikbd <command>` — commands: `probe`, `selftest`, `bind`, `led`, `read`, `record`, `gui`
- Verify encoder: `swift run minikbd selftest` (checks byte output against ch57x-keyboard-tool test vectors; asserts are active in debug builds only)
- Hardware smoke test: `swift run minikbd probe` (keyboard must be connected **by USB/dongle**, not Bluetooth — programming only works over USB)

## Architecture

Under `Sources/minikbd/`:

- `Protocol.swift` — pure encoder, no I/O. Produces 64-byte wire messages. Ported from [kriomant/ch57x-keyboard-tool](https://github.com/kriomant/ch57x-keyboard-tool) `src/keyboard/k884x.rs`; consult that file for any protocol question before reverse-engineering anything.
- `Device.swift` — IOKit transport. Opens the keyboard's **vendor HID interface** (usage page `0xFF00`; the device also exposes a normal keyboard interface on usage page 1 — never open that one, it triggers Input Monitoring permissions). Sends via `IOHIDDeviceSetReport`: report ID = first byte (0x03), data = remaining 63 bytes.
- `Read.swift` — config read-back (queries + response decoding, see protocol facts below).
- `Record.swift` — listen-only CGEvent tap that records keystrokes as chord tokens (filters auto-repeat).
- `GUI.swift` — SwiftUI configurator (`minikbd gui`): layer tabs, key/knob grid, chord composer (modifier toggles + searchable key picker, covers F13–F24), colored chip preview of each step (cyan=combination, magenta=named key, orange=media/mouse, red=invalid), media/mouse actions menu, per-key delay field (0–6000 ms between steps, loaded from `read`, written with the binding), LED section, clickable ⓘ info popovers. The LED preview dot mimics the mode (off=gray, backlight=steady, shock/shock2=breathing, press=dim static); LED state can't be read from the device, so the last value Set is remembered per layer in UserDefaults. Runs in the CLI binary via NSApplication, no app bundle.
- `main.swift` — CLI parsing and dispatch. Token tables (`keyCodes`, `mediaCodes`, `mouseButtons`) and `bindMessages` are shared with the GUI, so `read` output is always valid bind input. Spanish ISO aliases (`ñ`, `ç`) parse to the matching HID codes; unnamed codes print/parse as `0xNN`.

## Protocol facts (CH57x 884x variant)

- Every message: 64 bytes zero-padded, starts `0x03`.
- Bind: `[0x03, 0xfe, keyID, layer, 0x01, 0,0,0,0,0, count, (mod, code)...]` then finish sequence `[03 aa aa]`, `[03 fd fe ff]`, `[03 aa aa]`.
- Layer wire byte is 1–3 (not 0-based). Key IDs: buttons 1–12; knob N (1-based) is `16 + 3(N-1) + action` with ccw=0, press=1, cw=2.
- Modifier bitmask: ctrl=1, shift=2, alt=4, cmd=8. Key codes are standard USB HID usages (a=0x04, f13=0x68).
- Max 18 chords per key; delay message type `0x05`, u16 LE ms, max 6000.
- Media bind: type byte `0x02`, consumer usage u16 LE at bytes 11–12 (playpause=0xCD, calculator=0x192). Mouse bind: type `0x03`, subtype at byte 10 (1=click, 3=wheel), modifiers at 11, buttons at 12 (left=1 right=2 middle=4), wheel delta at 15 (1=up, 0xFF=down). Media/mouse bindings hold ONE action, never a chord sequence.
- LED: `[0x03, 0xfe, 0xb0, layer, 0x08, 0,0,0,0,0, 0x01, 0, (color<<4)|mode]` + `[03 fd fe ff]`. Modes: 0=off 1=backlight 2=shock 3=shock2 4=press 5=backlight-white. Colors: 0=white 1=red 2=orange 3=yellow 4=green 5=cyan 6=blue 7=purple.
- Read-back (see `Read.swift`, ported from [kamaaina/macropad_tool](https://github.com/kamaaina/macropad_tool)): send device-type query `0x03 0xfb...`, then per-layer `0x03 0xfa keys knobs layer...`; device answers one input report per key/knob action shaped like the bind message (delay is big-endian in responses). Query tails are verbatim USB captures — replay them exactly.

## macOS permissions

- `minikbd record` needs **Input Monitoring** (System Settings > Privacy & Security > Input Monitoring; open it directly with `open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"`). The first failed run adds the terminal to the list; after enabling the toggle, the terminal must be **fully restarted** for the grant to take effect.
- `screencapture` (used to screenshot the GUI for verification) needs **Screen Recording** for the terminal — same rule: grant the toggle, then fully restart the terminal.
- Talking to the config interface (usage page `0xFF00`) needs no permission — only event taps and screen capture do.

## Hardware constraints

- macOS has no virtual keycodes for F21–F24 (`Events.h` ends at `kVK_F20`), so apps never see those keys — but the HID events DO arrive (verified on this machine: `hidutil` UserKeyMapping remap of F24 works). So F21–F24 are usable via hidutil remap or by reading the raw HID device; hidutil remaps reset on reboot.
- Bluetooth mode drops extended F-keys; anything clever must assume the dongle/USB connection.
- Bindings persist in the keyboard (it has a battery); a bad write only costs re-binding a key, not a brick.
- Disconnected keyboard is handled gracefully everywhere (verified): CLI commands print `error: keyboard not found — is it connected by USB?`, the GUI shows the same in its status line and keeps running.

## Roadmap (agreed with user)

1. ✅ Protocol port + bind/led CLI
2. ✅ Config read-back (`minikbd read`)
3. ✅ Macro recording from the real keyboard (`minikbd record`)
4. ✅ SwiftUI GUI (`minikbd gui` — 12-key + 2-knob grid, 3 layer tabs, composer, chips, LED, media/mouse actions)
5. Host-side action engine: keyboard sends F13–F20, background agent runs scripts/actions
