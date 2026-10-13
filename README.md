# Light-mulator

A lightweight native macOS app to manage every Android emulator, iOS simulator and plugged-in phone from one window,
with Mac memory and disk usage always in view. About 55 MB of RAM, no background process, no dependencies.

## Features

- **Android emulators**: launch, cold boot, stop, edit, duplicate (APFS clone), wipe, delete. Controls like Android
  Studio's Running Devices pane (power, volume, rotate, back, home, overview, type text, screenshot, record), plus
  device UI toggles over `adb` (dark theme, gesture navigation, layout bounds, TalkBack, font and display size, app language).
- **iOS simulators**: boot, shutdown, erase, open URL or deep link, screenshot, record, appearance, contrast, text
  size, 9:41 status bar.
- **Connected devices**: Android phones (USB or Wi-Fi) and iPhones/iPads (USB) appear the moment they are plugged in,
  and the window switches to the last one plugged. Screen still, controls, device UI, battery and storage details.
  - Android: live, clickable mirror via [scrcpy](https://github.com/Genymobile/scrcpy) when installed, plus `adb shell` in Terminal.
  - iOS: shared clipboard with the Mac. On iOS 27 or later, full control from the Mac (touch, keyboard, copy/paste)
    through Xcode's DeviceHub.
- **Resources**: Mac memory (pressure, each device's share, swap) and storage taken by emulators, simulators, runtimes
  and system images. Stopped devices show what launching would cost against the memory free now.
- **Cleanup**: unused Android system images and leftover files from deleted devices, listed with their size for you
  to delete. Every delete re-checks the target first.

## Tech stack

- Swift 5, SwiftUI and AppKit; macOS 14 or later, Apple silicon.
- No Xcode project and no package dependencies: a single `swiftc` call builds the app.
- System interfaces: `libproc`, `host_statistics64` and `sysctl` for processes and memory; the adb host protocol
  over TCP and the usbmuxd protocol over its Unix socket for device plug events.
- Command-line tools: Android SDK `emulator` and `adb`, Xcode's `simctl` and `devicectl`, and optionally `scrcpy`.

## Architecture

```
Sources/
  App.swift                 entry point, single window
  Store.swift               @MainActor ObservableObject: the one source of truth, owns polling, trackers and actions
  Model.swift, SystemImages.swift, Leftovers.swift      AVDs, SDK paths, system images, leftover scanning
  Simulators.swift          simctl client (JSON)
  DeviceShell.swift         adb shell per device: controls and UI settings
  Phones.swift              physical Android devices, AdbTracker (push-based adb device list)
  IOSDevices.swift          UsbmuxTracker (push-based USB plug events), devicectl client
  System.swift, Memory.swift            process runner, process scanner, Mac memory
  Workbench.swift           sidebar and device list
  Inspector.swift, DeviceControls.swift, SimulatorViews.swift, Views.swift   inspector panes, cards and sheets
  Theme.swift               design tokens (light and dark) and shared components
```

- **Event-driven where possible**: plug and unplug events are pushed by the adb server and usbmuxd; nothing polls for
  devices. Running devices and memory are read through syscalls every 2 s while the app is in front, every 6 s behind.
- **Capability-gated UI**: iOS controls appear only when `devicectl` reports the device supports them.

## Build

Requirements: Xcode (for `swiftc`, `simctl`, `devicectl`), and the Android SDK with `platform-tools` and `emulator`.

```bash
./build.sh            # builds build/Light-mulator.app
./build.sh --install  # also copies it to ~/Applications
```

The app is ad-hoc signed for local use. The icon is generated on the first build.

## Configuration

- Android SDK: `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, else `~/Library/Android/sdk`.
- AVDs: `$ANDROID_AVD_HOME`, else `~/.android/avd`.
- adb server port: `$ANDROID_ADB_SERVER_PORT`, else 5037.
- Launch logs: `~/Library/Logs/Light-mulator/<avd>.log`.

## Notes

- A real iOS device must be trusted, with Developer Mode on, to expose its screen and controls. After an iOS update,
  Xcode prepares the device for a few minutes; the app waits and retries on its own.
- Control from the Mac needs iOS 27 or later; earlier versions get the shared clipboard and the other controls.
- Stop sends `adb emu kill`, which saves the quick-boot state; Force Kill sends SIGKILL.
