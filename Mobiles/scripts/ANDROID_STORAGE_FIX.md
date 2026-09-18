# Android Emulator Storage Issues - Solutions Guide

## Quick Diagnosis

If you're seeing storage errors when starting the Android emulator or running apps, try these solutions in order:

## Solution 1: Run the Automated Fix Script (Recommended)

From the repository root, run the cleanup script with exactly one Android emulator connected. It requires `adb`, Java for the React Native Gradle build, and GNU `timeout` on `PATH` (on macOS, install Coreutils and add its `gnubin` directory to `PATH`).

The script uninstalls the native Android and React Native QuickPizza apps, deleting their local app data. Reinstall them afterward.

```bash
./Mobiles/scripts/fix-android-storage.sh
```

The script:
- Uninstalls the native Android and React Native QuickPizza apps
- Runs `gradlew clean` for the React Native Android build
- Attempts to clear system caches, logs, and temporary files
- Displays current storage status

Protected directories can reject cleanup on non-rooted emulator images. The script ignores those errors, so its success messages do not guarantee that every directory was cleared.

## Solution 2: Alternative ADB Commands

If `pm trim-caches` doesn't work, try these alternatives:

### Clear specific directories
```bash
# Select one emulator serial from the list
adb devices
DEVICE=emulator-5554

# Clear various cache directories
adb -s "$DEVICE" shell "rm -rf /data/dalvik-cache/*"
adb -s "$DEVICE" shell "rm -rf /cache/*"
adb -s "$DEVICE" shell "rm -rf /data/local/tmp/*"
adb -s "$DEVICE" shell "rm -rf /data/anr/*"
adb -s "$DEVICE" shell "rm -rf /data/tombstones/*"
```

These directories may require root access. To reset only the React Native demo, use `adb -s "$DEVICE" shell pm clear com.grafana.quickpizza.rn`. This deletes **all app data**, including login state and configuration overrides, rather than only the cache; see the [ADB package manager reference](https://developer.android.com/tools/adb#pm).

### Root access method (if needed)

This requires an emulator image that supports `adb root`; Google Play images do not.

```bash
# Try with root access
adb -s emulator-5554 root
adb -s emulator-5554 shell "rm -rf /data/dalvik-cache/*"
adb -s emulator-5554 unroot
```

## Solution 3: Cold Boot the Emulator

A cold boot bypasses the saved snapshot and preserves installed apps and data:

```bash
# 1. List available emulators
emulator -list-avds

# 2. Close the selected emulator (substitute its serial)
adb -s emulator-5554 emu kill

# 3. Cold boot without loading a snapshot
emulator -avd YOUR_AVD_NAME -no-snapshot-load &

# Wait for boot to complete, then try your app again
```

If you need a factory reset instead, add `-wipe-data`. This removes installed apps, settings, and user data; it is not part of a normal cold boot. See the [emulator command-line reference](https://developer.android.com/studio/run/emulator-commandline).

## Solution 4: Increase Emulator Storage (Permanent Fix)

1. Open **Android Studio**
2. Go to **Tools → Device Manager** (or AVD Manager)
3. Find your emulator and click **Edit** (pencil icon)
4. Click **Show Advanced Settings**
5. Under **Memory and Storage**:
   - Increase **Internal Storage** to 4096 MB or higher
   - Increase **SD Card** if needed
6. Click **Finish**
7. Restart the emulator

## Solution 5: Create a New AVD

If the above doesn't work, create a fresh emulator:

```bash
# Using Android Studio:
# 1. Tools → Device Manager
# 2. Create Device
# 3. Select a device (e.g., Pixel 8)
# 4. Select a system image (API 35 recommended)
# 5. Show Advanced Settings:
#    - Internal Storage: 4096 MB
#    - SD Card: 512 MB
# 6. Finish

# Or using command line:
# Install this system image first. Use x86_64 instead of arm64-v8a on an x86_64 host.
sdkmanager "system-images;android-35;google_apis;arm64-v8a"
avdmanager create avd -n Pixel_8_API_35_Large \
  -k "system-images;android-35;google_apis;arm64-v8a" \
  -d "pixel_8" \
  --sdcard 512M
```

The command sets the SD card size, not internal storage. Adjust internal storage in Device Manager as described above.

## Solution 6: Clean Build on React Native App

Sometimes the issue is with the app build cache:

```bash
# From the repository root:
cd Mobiles/react-native

# Clean Android build
cd android
./gradlew clean
rm -rf .gradle build app/build
cd ..

# Clean Metro bundler cache
yarn start --reset-cache

# In another terminal, from Mobiles/react-native/, reinstall the app
yarn android
```

## Checking Storage Status

To see current storage usage:

```bash
adb devices
DEVICE=emulator-5554 # Substitute the emulator serial to inspect

# Overall storage
adb -s "$DEVICE" shell "df -h /data"

# Largest packages
adb -s "$DEVICE" shell pm list packages | tr -d '\r' | cut -d: -f2 | while read -r pkg; do
    adb -s "$DEVICE" shell "du -sh /data/data/$pkg 2>/dev/null"
done | sort -rh | head -10
```

Reading other apps' data directories requires root; on a non-rooted image, inspect app storage in Android Settings instead.

## Prevention Tips

1. **Remove test app data when needed**: The fix script uninstalls both QuickPizza Android apps
2. **Use larger storage**: Set Internal Storage to at least 4 GB when creating AVDs
3. **Reset disposable emulators when needed**: `-wipe-data` deletes installed apps and user data
4. **Remove unused apps**: Uninstall test apps you're not using
5. **Disable snapshots** if you don't need them: `-no-snapshot-save -no-snapshot-load`

## Troubleshooting

### If nothing works:
1. Delete the AVD completely and create a new one with more storage
2. Check your host machine has enough disk space
3. Verify Android SDK is up to date
4. Restart your computer (sometimes helps with locked files)

### AVD location (to manually delete):
- **macOS/Linux**: `~/.android/avd/`
- **Windows**: `C:\Users\<username>\.android\avd\`

You can delete an AVD folder manually if Android Studio can't remove it.

## Running the React Native Demo

After fixing storage:

```bash
# From the repository root:
cd Mobiles/react-native

# Make sure backend is running
docker run --rm -d -p 3333:3333 ghcr.io/grafana/quickpizza-mobile-local:latest

# Start Metro
yarn start

# In another terminal, run Android
yarn android
```

## Need More Help?

- Check emulator logs: `adb -s emulator-5554 logcat`
- Android Studio Event Log: View → Tool Windows → Event Log
- React Native logs: Metro bundler terminal output
