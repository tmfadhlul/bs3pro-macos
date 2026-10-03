# BS3 Pro Control for macOS

A tiny native menu-bar app to control the **Flydigi BS3 Pro** laptop cooler on macOS, since Flydigi ships no Mac app.
Universal binary: Intel and Apple Silicon, macOS 13+.

## Features

- Live fan RPM in the menu bar
- Gears: Quiet / Standard / Strong / Max (uses the device's own gear RPM table)
- Custom fan speed, 0–5000 RPM
- Auto mode: picks a gear from macOS thermal pressure
- RGB: solid / breathe / rainbow, color swatches + custom color picker, brightness, on/off
- Gear indicator light, power-on start, smart start/stop
- Launch at login

## Install

1. Download `BS3Pro.dmg` from [Releases](../../releases), open it, drag **BS3Pro** to Applications.
2. The app is ad-hoc signed, not notarized. On first launch right-click → **Open**, or run:
   `xattr -dr com.apple.quarantine /Applications/BS3Pro.app`
3. Connect the cooler with USB. A fan icon with the RPM appears in the menu bar.

## Build

Needs only Xcode Command Line Tools (`xcode-select --install`):

```sh
./build.sh          # -> build/BS3Pro.app and build/BS3Pro.dmg (universal)
```

## Notes

- USB only (VID `0x37D7`, PID `0x1004`). Bluetooth isn't supported yet.
- Over USB on macOS, commands are raw `5A A5 cmd len payload checksum` frames with **no** report-ID prefix; replies arrive prefixed with `0x03`.
- On firmware with controller tier 1, the device ignores a direct switch to gear 4, so **Max** sets the gear-4 RPM as a custom speed instead.
- Applying a light effect writes the cooler's flash memory, so it happens only when you press Apply or tap a swatch.
- The device can't report the state of the gear light, power-on start or smart start/stop; the app shows the last value you set.

## Credits

The HID protocol comes from [THRM](https://github.com/hs20789/THRM) (MIT, © 2025 Tianli), an open-source Windows/Linux controller for Flydigi BS-series coolers.
Not affiliated with Flydigi.
