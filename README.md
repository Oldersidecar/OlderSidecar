<p align="center"><img src="docs/ikona.png" width="128" alt=""></p>

# Older Sidecar

Shows your Mac's screen on an old jailbroken iPad over USB. The iPad can also work as a trackpad and
remote for the Mac.

[Česky](README.cs.md)

## Requirements

- Mac with macOS 12.3 or later (Intel or Apple Silicon)
- Jailbroken iPad on iOS 6 to 10 (iPad 2, 3, 4, iPad mini 1)
- USB cable. Wi-Fi is not used.

## Install

**iPad:** add `http://oldersidecar.surge.sh/` as a source in Cydia (with http, not https, so that iOS 6 can reach it).
Install **Older Sidecar** on iOS 6, or **Older Sidecar (iOS 7–10)** on newer iPads.
If you only have AppSync, install `OlderSidecar-iOS6.ipa` or `OlderSidecar-iOS7-10.ipa` from [Releases](https://github.com/Oldersidecar/OlderSidecar/releases).

**Mac:**

1. Download `OlderSidecar-1.8.0.dmg` from [Releases](https://github.com/Oldersidecar/OlderSidecar/releases),
   open it and drag Older Sidecar to Applications.
2. The app is not notarized by Apple, so macOS blocks it the first time. Go to
   System Settings > Privacy & Security and click Open Anyway.
3. Allow Screen Recording and Accessibility. The app shows a setup window that walks you through it.

It runs in the menu bar and starts at login. You can turn that off in its menu.

## Use

Plug in the iPad and open Older Sidecar on it. Pick one of two modes:

- **Screen only** - the Mac screen, nothing gets clicked by accident. Pinch to zoom.
- **Control Mac** - the iPad becomes a trackpad with a row of keys (esc, tab, ⌘⌥⌃⇧, arrows), a keyboard
  and buttons for brightness, Mission Control, Launchpad, music, volume and lock. The Mac screen is not shown.

The Mac menu has a resolution picker (4:3 modes fill the whole iPad), shows the iPad's battery, and lets you
change the language. 14 languages are included; the translations were not checked by native speakers yet,
fixes are welcome.

When the Mac sleeps, the iPad says so instead of freezing.

## Build

Needs Xcode Command Line Tools (`xcode-select --install`) and dpkg (`brew install dpkg`).

```
./build.sh
```

- `mac/` - Mac app, output `dist/OlderSidecar-<version>.dmg`
- `ios/` - iPad app (armv7) in two variants: `ios/build.sh ios6` and `ios/build.sh ios7`. Downloads `iPhoneOS10.3.sdk` from
  [theos/sdks](https://github.com/theos/sdks) the first time.
- `cydia/` - both .deb packages and the Cydia repo in `docs/` (uploaded to surge.sh)
- `tools/make-graphics.swift` - draws the icon and textures

The Mac app talks to the iPad through usbmuxd on port 7777 and sends JPEG frames captured with ScreenCaptureKit.

## License

MIT. Sidecar is a trademark of Apple Inc. This project has nothing to do with Apple.
