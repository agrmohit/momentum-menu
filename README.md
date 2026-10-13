# Momentum Menu

A macOS menu bar app for Sennheiser MOMENTUM 4 Wireless headphones.

Sennheiser's Smart Control Plus app is iPhone-only — the App Store listing says
"Only for iPhone", so it is not offered on Apple Silicon Macs either. This is a
small native alternative for the things you actually reach for day to day:
battery, noise control and the equaliser.

**Not affiliated with, endorsed by, or supported by Sennheiser or Sonova.**
Sennheiser and MOMENTUM are trademarks of their respective owners. This project
is an independent, interoperable client for headphones you already own.

> [!WARNING]
> This talks to your headphones over a protocol nobody published. It is built
> from community reverse-engineering plus verification against real hardware.
> It can misbehave on firmware it has not seen. Use it at your own risk.

## Status

Verified against a MOMENTUM 4 Wireless on this Mac:

| Feature | State |
| --- | --- |
| Battery level | works |
| Noise control mode (Off / Adaptive / Custom) | works |
| Noise level slider (ANC ↔ transparency) | works |
| Touch-control state (read) | works |
| Equaliser | **not yet working** — see below |
| Bass boost | **not yet working** — see below |
| Firmware version | **not yet working** — see below |

The equaliser, bass boost and firmware reads currently come back rejected with
error `0x05` (malformed or wrong length). On this device that error is
ambiguous: it means either "unsupported" or "this getter needs an argument and
you sent an empty payload". `--probe --diagnose` asks each id both ways to tell
those apart. Resolving this is the next piece of work.

## Explicitly out of scope: firmware updates

This app will never write firmware. A malformed firmware write over a
reverse-engineered protocol bricks the headphones, and there is no recovery
path. Use Sennheiser's own app for firmware.

## Safety

Several GAIA command ids are actively dangerous on this hardware. They are
hard-blocked in [`Commands.swift`](Sources/M4Core/Gaia/Commands.swift), enforced
centrally so no call site can route around the check, and covered by tests:

| Id | Why it is blocked |
| --- | --- |
| `0x0607` | Takes the headphones offline; they need a power cycle to come back |
| `0x0613`, `0x0685` | Reset the control link |
| `0x1403` | **Silently erases a pairing.** It wiped a phone's pairing during someone's indexed scan |
| `0x0801`, `0x0805`, `0x0817` | Act on a paired-device index, effect unknown |
| all other `0x06xx` | Power/system group, known to reset the link. Only battery (`0x0603`) is allowed out of it |

If you extend this, do not sweep command ranges against your own headphones
without reading the protocol notes linked below first. Those warnings were paid
for by other people's hardware.

## Requirements

- Apple Silicon or Intel Mac on macOS 14 or later
- Xcode 15+ (for the Swift toolchain)
- MOMENTUM 4 paired to the Mac

## Build

```bash
./build.sh
```

That produces `build/MomentumMenu.app`. Then:

```bash
# read-only check: reads state, writes nothing
open -W --stdout /dev/stdout build/MomentumMenu.app --args --probe

# add the payload-form diagnostic
open -W --stdout /dev/stdout build/MomentumMenu.app --args --probe --diagnose

# run the menu bar app
open build/MomentumMenu.app
```

Launch it with `open`, not by running the binary directly. macOS attributes a
privacy request to the *responsible process*, so running the executable from a
shell makes your terminal responsible — and since the terminal has no Bluetooth
usage description, the process is killed on its first Bluetooth call.

The app is ad-hoc signed. On first launch macOS will ask for Bluetooth
permission, and Gatekeeper may need a right-click → Open.

## How it works

The headphones expose a Qualcomm **GAIA v3** control channel over Bluetooth
Classic RFCOMM, under the SDP service UUID
`A2129FF3-081B-4C45-8AFE-469D9C4842EC`. Frames look like this:

```
FF 03 | length(u16 BE) | vendor(u16 BE) | command(u16 BE) | payload
                          0x0495 = Sennheiser
```

Responses reuse the request id with status bits laid over it: `| 0x0100`
success, `| 0x0180` error, `| 0x0080` unsolicited notification.

This is why the app can exist on macOS but not on iOS. Raw RFCOMM to a
non-MFi accessory is available through `IOBluetooth` on macOS, and simply not
available to third-party iOS apps at all.

### Project layout

```
Sources/M4Core/Gaia/          frame codec, command ids, safety blocklist
Sources/M4Core/Transport/     IOBluetooth RFCOMM channel
Sources/M4Core/Controller/    device state, request/response matching
Sources/MomentumMenu/         NSStatusItem + SwiftUI popover
Tests/                        codec, blocklist and gain-encoding tests
```

Run the tests with `swift test`. They cover the wire format against captured
frames and need no hardware.

## Credits

The protocol work is not mine. This app is a Swift implementation built on
documentation and code from these projects, and would not exist without them:

- [DanSmith888/omarchy-momentum4](https://github.com/DanSmith888/omarchy-momentum4)
  — `PROTOCOL.md`, verified against firmware 3.38.3. The source of the command
  tables, the EQ gain scaling, and every one of the hazard warnings above.
- [gjabell/momentumctl](https://github.com/gjabell/momentumctl) (MIT) — frame
  format and the captured test vectors this project's codec tests use.
- [Tumult1337/momentum4-control](https://github.com/Tumult1337/momentum4-control)
  (MIT) — the GAIA SDP service UUID, EQ payload shapes, and independent
  confirmation of the command set.
- [stefanfmeyer/smart-connect-bt-audio](https://github.com/stefanfmeyer/smart-connect-bt-audio)
  — GAIA over BLE GATT, and cross-verification of command ids.

Where those sources disagree — notably the payload format for the noise-mode
table at `0x1A00`, where one sends a single `[id, value]` pair and another says
the device requires the whole table — this app tries the short form, and on
rejection falls back to read-modify-write and remembers the answer.

## License

[MIT](LICENSE)
