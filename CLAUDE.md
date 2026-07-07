# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Native macOS (Apple Silicon) configurator for a CH57x-based mini keyboard: 12 keys + 2 clickable knobs, 3 layers, USB VID/PID `1189:8840`. It replaces the vendor's x86_64 Qt app ("MINI_KEYBOARD"). Swift + IOKit HID only — no hidapi, no third-party dependencies.

## Commands

- Build: `swift build`
- Run: `swift run minikbd <command>` — commands: `probe`, `selftest`, `bind`, `led`
- Verify encoder: `swift run minikbd selftest` (checks byte output against ch57x-keyboard-tool test vectors; asserts are active in debug builds only)
- Hardware smoke test: `swift run minikbd probe` (keyboard must be connected **by USB/dongle**, not Bluetooth — programming only works over USB)

## Architecture

Three files under `Sources/minikbd/`:

- `Protocol.swift` — pure encoder, no I/O. Produces 64-byte wire messages. Ported from [kriomant/ch57x-keyboard-tool](https://github.com/kriomant/ch57x-keyboard-tool) `src/keyboard/k884x.rs`; consult that file for any protocol question before reverse-engineering anything.
- `Device.swift` — IOKit transport. Opens the keyboard's **vendor HID interface** (usage page `0xFF00`; the device also exposes a normal keyboard interface on usage page 1 — never open that one, it triggers Input Monitoring permissions). Sends via `IOHIDDeviceSetReport`: report ID = first byte (0x03), data = remaining 63 bytes.
- `main.swift` — CLI parsing and dispatch.

## Protocol facts (CH57x 884x variant)

- Every message: 64 bytes zero-padded, starts `0x03`.
- Bind: `[0x03, 0xfe, keyID, layer, 0x01, 0,0,0,0,0, count, (mod, code)...]` then finish sequence `[03 aa aa]`, `[03 fd fe ff]`, `[03 aa aa]`.
- Layer wire byte is 1–3 (not 0-based). Key IDs: buttons 1–12; knob N (1-based) is `16 + 3(N-1) + action` with ccw=0, press=1, cw=2.
- Modifier bitmask: ctrl=1, shift=2, alt=4, cmd=8. Key codes are standard USB HID usages (a=0x04, f13=0x68).
- Max 18 chords per key; delay message type `0x05`, u16 LE ms, max 6000.
- LED: `[0x03, 0xfe, 0xb0, layer, 0x08, 0,0,0,0,0, 0x01, 0, (color<<4)|mode]` + `[03 fd fe ff]`. Modes: 0=off 1=backlight 2=shock 3=shock2 4=press 5=backlight-white. Colors: 0=white 1=red 2=orange 3=yellow 4=green 5=cyan 6=blue 7=purple.
- Read-back (see `Read.swift`, ported from [kamaaina/macropad_tool](https://github.com/kamaaina/macropad_tool)): send device-type query `0x03 0xfb...`, then per-layer `0x03 0xfa keys knobs layer...`; device answers one input report per key/knob action shaped like the bind message (delay is big-endian in responses). Query tails are verbatim USB captures — replay them exactly.

## Hardware constraints

- macOS has no virtual keycodes for F21–F24 (`Events.h` ends at `kVK_F20`), so apps never see those keys — but the HID events DO arrive (verified on this machine: `hidutil` UserKeyMapping remap of F24 works). So F21–F24 are usable via hidutil remap or by reading the raw HID device; hidutil remaps reset on reboot.
- Bluetooth mode drops extended F-keys; anything clever must assume the dongle/USB connection.
- Bindings persist in the keyboard (it has a battery); a bad write only costs re-binding a key, not a brick.

## Roadmap (agreed with user)

1. ✅ Protocol port + bind/led CLI
2. ✅ Config read-back (`minikbd read`)
3. Macro recording from the real keyboard (CGEvent tap, needs Input Monitoring)
4. SwiftUI GUI (12-key + 2-knob grid, 3 layer tabs)
5. Host-side action engine: keyboard sends F13–F20, background agent runs scripts/actions
