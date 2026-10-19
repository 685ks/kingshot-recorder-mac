# Kingshot Recorder for Mac, with QuickRecorder recording

This repository builds the Mac installer of [Kingshot Recorder](https://github.com/wlfkkkk/Kingshot-Recorder) (by wlfk)
with a new recording part for macOS based on [QuickRecorder](https://github.com/lihaoyun6/QuickRecorder) by lihaoyun6.

With it the Mac version records, besides the emulator over ADB as before:

- a whole screen or a single window (for example the BlueStacks Air window), with a live preview;
- the desktop sound and the microphone (the two sound switches).

Everything else (the window, the Blurrer, quality presets, the access key, updates) is Kingshot Recorder as released.

## Install

1. Download **KingshotRecorder-osx-Setup.pkg** (or the **.dmg**) from the [release](../../releases/tag/mac-quickrecorder).
2. The installer is not signed by Apple. **Right-click it and choose Open**. If macOS still refuses, go to
   **System Settings > Privacy & Security** and click **Open Anyway**.
3. The first time you pick a screen or window, macOS asks to allow **Screen & System Audio Recording** for Kingshot
   Recorder. Allow it, then quit and reopen the app. The microphone is asked for the first time you switch it on.
4. Needs macOS 13 (Ventura) or newer on an Apple Silicon Mac.

After an update macOS may ask for Screen Recording again, because the app is only ad hoc signed.

## What is in here

- `ksrec/main.swift`: **ksrec**, the capture helper. Its ScreenCaptureKit code is adapted from QuickRecorder and it is
  licensed under the GNU AGPL v3.0 (`LICENSE`), like QuickRecorder.
- `payload/payload.zip`: the compiled (bytecode) Kingshot Recorder program code that uses ksrec. Kingshot Recorder is
  Copyright (c) 2026 wlfk - 685; it is not covered by this repository's license.
- `repack.py` and `.github/workflows/build.yml`: put both into the released Mac 0.1.0 program, sign it ad hoc, build the
  installer, install it on a GitHub Mac machine and start it as a test.
