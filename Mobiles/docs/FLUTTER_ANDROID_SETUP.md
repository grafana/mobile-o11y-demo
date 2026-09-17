# Flutter — Android Toolchain Setup

Simple steps to set up the Android toolchain (Android Studio + emulator) so you
can run the **Flutter** QuickPizza app on Android. The native Kotlin/Compose app
has its own guide ([`ANDROID_NATIVE_SETUP.md`](./ANDROID_NATIVE_SETUP.md)); for
the other apps see [`../README.md`](../README.md).

## Setup Steps

### 1. Install Android Studio
- Download from: https://developer.android.com/studio
- Install and complete the setup wizard
- Choose "Standard" installation (it will download Android SDK automatically)

### 2. Install SDK Components
- Open Android Studio
- Go to **Settings > Android SDK** (or **Preferences > Android SDK** on macOS)
- **SDK Platforms tab:** Install the platform required by your Flutter SDK's `compileSdkVersion` (used in [`build.gradle.kts`](../flutter/android/app/build.gradle.kts)). The emulator's system image is selected separately below.
- **SDK Tools tab:** Ensure these are checked:
  - ✅ Android SDK Build-Tools
  - ✅ Android SDK Platform-Tools
  - ✅ Android Emulator
  - ✅ Android SDK Command-line Tools (latest)
- Click **Apply** and wait for installation

### 3. Accept Android Licenses
```bash
flutter doctor --android-licenses
```
Type `y` and press Enter for each license.

### 4. Create Android Virtual Device (AVD)
- In Android Studio: **Tools > Device Manager**
- Click **Create Device** (+ button)
- Choose a device (e.g., Pixel 5, Pixel 6)
- Select an Android version (download if needed)
- Click **Finish**

### 5. Verify Setup
```bash
cd Mobiles/flutter
flutter doctor
```
You should see ✓ for Android toolchain.

---

## Open Android Emulator

**Option 1: From Android Studio**
- Open Android Studio
- Go to **Tools > Device Manager**
- Click the **Play** button (▶️) next to your AVD

**Option 2: From Command Line**
```bash
# List available emulators
flutter emulators

# Replace the placeholder with an emulator ID from the list.
flutter emulators --launch "<emulator_id>"
```

---

## Run the App

First complete the Flutter app's [installation and configuration](../flutter/README.md#installation), including `flutter pub get`, `config.json`, and a running QuickPizza backend. The commands below start from the repository root.

### Quick Start (Recommended)

**Easiest way - automatically opens emulator and runs the app:**
```bash
cd Mobiles/flutter
./scripts/run-android.sh
```

This script:
- Checks for a connected Android device
- Launches an emulator if no Android device is connected
- Waits for it to be ready
- Runs the app automatically

### Manual Steps

1. **Make sure the emulator is running** (you should see the Android home screen)

2. **Run the app:**

**Using the helper script (recommended):**
```bash
cd Mobiles/flutter
./scripts/run-android.sh
```

**Using VS Code:**
- Open the repository root in VS Code, select **Flutter (debug)**, and press **F5** (uses [`.vscode/launch.json`](../../.vscode/launch.json) with `config.json`).

**Or manually:**
```bash
cd Mobiles/flutter
flutter devices
# Replace the placeholder with a device ID from the list.
flutter run -d "<android-device-id>" --dart-define-from-file=config.json
```

---

## Quick Troubleshooting

**Emulator not showing in `flutter devices`:**
- Make sure emulator is running and fully booted
- Wait a few seconds and try `flutter devices` again

**Android SDK not found:**
```bash
# Find your SDK path in Android Studio: Settings > Android SDK
# Then configure Flutter:
flutter config --android-sdk ~/Library/Android/sdk
```

**Licenses not accepted:**
```bash
flutter doctor --android-licenses
```

**Need more help?**
- Run diagnostics: `flutter doctor -v`
