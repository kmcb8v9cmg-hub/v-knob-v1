# Volume Knob for macOS

A small, native floating volume controller and live spectrum analyzer for macOS. Volume Knob stays above other windows and provides a rotary control, slider, volume up/down buttons, one-click mute, and sound-reactive visuals.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Support Volume Knob

Volume Knob is free to download and use. If it helps you, please consider a **suggested $5 donation** through [Cash App — $DarwinGoble0000420](https://cash.app/$DarwinGoble0000420). Donations are optional and are not required to download or use the app.

## Features

- Floating, always-on-top glass panel
- Rotary drag and click control
- Glowing red volume hash marks surrounding the green dial ring
- Standard volume slider
- Volume up and down buttons
- Large mute/unmute button
- Real-time 24-band green spectrum analyzer
- Auto mode prefers Mac audio and falls back to the microphone when music stops
- Dedicated Mac Audio and Microphone modes
- Sound-reactive glow around the knob
- Optional Smart Level with Gentle-to-Strong control for consistent track loudness
- Privacy screen with white, pink, brown, and speech-shaped noise
- Adjustable microphone noise detector with spectrum alerts and calibration
- Multi-speaker broadcasting through a macOS Multi-Output Device
- Optional 15, 30, or 60 minute privacy-noise timer
- Bluetooth and external-speaker support
- Menu-bar access
- No accounts, analytics, network requests, or audio recording
- Native SwiftUI and Core Audio implementation

Version 2 analyzes audio locally only to draw the spectrum. Audio samples are never recorded, saved, or transmitted. macOS asks permission before Mac Audio or Microphone access is enabled.

## Requirements

- macOS 14 Sonoma or newer
- Apple Silicon or Intel Mac
- Xcode 16 or newer, or a compatible Swift 6 toolchain, to build from source

## Build

```sh
./scripts/build-app.sh
```

The packaged application will be created at:

```text
dist/Volume Knob.app
```

## Install

```sh
./scripts/install.sh
```

Or drag `dist/Volume Knob.app` into the Applications folder.

To open Volume Knob automatically, add it under **System Settings → General → Login Items**.

## Use

- Drag the knob up/right to increase volume or down/left to decrease it.
- Click around the knob to jump to a level.
- Drag the green slider for precise control.
- Use the speaker-minus and speaker-plus buttons for 10% steps.
- Select **Mute** to silence output and **Unmute** to restore it.
- Select the speaker icon in the menu bar for quick access.
- Choose **Auto**, **Mac Audio**, or **Microphone** beside the spectrum. Auto switches to the microphone after Mac audio is quiet for about one second.
- Turn on **Smart Level** to slowly balance louder and quieter recordings. Set the strength from **Gentle** to **Strong**. Smart Level responds only to Mac audio and pauses when music stops or output is muted.
- Open the **Privacy** tab to start a capped privacy-noise signal, set its type and timer, or enable the microphone noise detector.
- Use **Speaker Setup** to open Audio MIDI Setup. Create and select a Multi-Output Device to broadcast through several compatible speakers.
- Start connected amplifiers at a low level. The in-app generator is capped, but external hardware can still make the output dangerously loud.
- Privacy Noise starts at 26% and can be raised to 60%; increase it gradually, especially with amplified or multi-speaker outputs.

## Project layout

```text
Package.swift
Sources/VolumeKnob/main.swift
Resources/Info.plist
scripts/build-app.sh
scripts/install.sh
```

## Privacy

Volume Knob operates entirely on the Mac. It does not connect to the internet, collect telemetry, record audio, or store listening history. Live samples are analyzed only in memory and immediately discarded. See [SECURITY.md](SECURITY.md).

## License

MIT License. See [LICENSE](LICENSE).
