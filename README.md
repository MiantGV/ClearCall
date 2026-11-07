# ClearCall

A small macOS menu-bar app that records calls (any app: WhatsApp, Teams, Zoom, browsers) into **one audio file**, with the echo of the call removed from the microphone so you can use speakers instead of headphones.

## How it works

- **Call audio:** a Core Audio process tap of everything the Mac plays (macOS 14.4+, "System Audio Recording" permission).
- **Your voice:** the default microphone, captured raw (Apple's voice processing is avoided because it turns down other apps).
- Both are resampled to 48 kHz mono and placed on one timeline by host time, then processed in 10 ms frames.
- **Echo cancellation:** WebRTC AEC3 on the microphone, with the call audio as the reference *(in progress)*.
- Output: `Recording <date> at <time>.m4a` (AAC, mono) in the folder chosen in Settings (default `~/Documents/Meeting Recordings`).
- Optional test tracks (`mic-raw.wav`, `mic-cleaned.wav`, `system.wav`) for tuning.

## Building

GitHub Actions builds every push to `main` on a macOS runner and publishes a release with `ClearCall-<version>.zip`.

Locally: `scripts/build-app.sh <version> <build>` (needs Xcode or the Command Line Tools).
