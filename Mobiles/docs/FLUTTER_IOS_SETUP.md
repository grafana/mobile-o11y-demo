# Flutter — iOS Toolchain Setup

Simple steps to set up the iOS toolchain (Xcode + Simulator) so you can run the
**Flutter** QuickPizza app on iOS. For the React Native, native iOS, or native
Android apps, see their own setup docs linked from
[`../README.md`](../README.md).

## Setup Steps

### 1. Install Xcode
- Open App Store
- Search for "Xcode" and install it
- Wait for installation to complete (~15GB, may take 30-60 minutes)

### 2. Configure Xcode
```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```

### 3. Download iOS Simulator Runtime
- Open Xcode
- Go to **Xcode > Settings > Platforms**
- Download an iOS version (e.g., iOS 17.0 or latest)

### 4. Verify Setup
```bash
cd Mobiles/flutter
flutter doctor
```
You should see ✓ for Xcode.

---

## Open iOS Simulator

**Option 1: Using Command Line**
```bash
open -a Simulator
```

**Option 2: Using Xcode**
- Open Xcode
- Go to **Xcode > Open Developer Tool > Simulator**

**Option 3: Boot Specific Simulator**
```bash
xcrun simctl list devices available
# Replace the placeholder with a simulator UDID from the list.
xcrun simctl boot "<simulator-udid>"
open -a Simulator
```

---

## Run the App

First complete the Flutter app's [installation and configuration](../flutter/README.md#installation), including `flutter pub get`, `config.json`, and a running QuickPizza backend. The commands below start from the repository root.

### Quick Start (Recommended)

**Easiest way - automatically opens simulator and runs the app:**
```bash
cd Mobiles/flutter
./scripts/run-ios.sh
```

This script:
- Checks for a connected iOS device
- Opens Simulator if no iOS device is connected
- Waits for it to be ready
- Runs the app automatically

### Manual Steps

1. **Make sure the simulator is running** (you should see the iOS home screen)

2. **Run the app:**

**Using the helper script (recommended):**
```bash
cd Mobiles/flutter
./scripts/run-ios.sh
```

**Using VS Code:**
- Open the repository root in VS Code, select **Flutter (debug)**, and press **F5** (uses [`.vscode/launch.json`](../../.vscode/launch.json) with `config.json`).

**Or manually:**
```bash
cd Mobiles/flutter
flutter devices
# Replace the placeholder with a device ID from the list.
flutter run -d "<ios-device-id>" --dart-define-from-file=config.json
```

---

## Quick Troubleshooting

**Simulator not showing in `flutter devices`:**
- Make sure Simulator app is open and showing a booted device
- Wait a few seconds and try `flutter devices` again

**Need more help?**
- Run diagnostics: `flutter doctor -v`
