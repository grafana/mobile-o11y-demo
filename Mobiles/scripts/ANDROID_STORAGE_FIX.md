# Android emulator storage errors

Use this when the emulator runs out of space or app installs fail with storage
errors. Try the steps in order.

## 1. Run the cleanup script

```bash
./Mobiles/scripts/fix-android-storage.sh
```

Start exactly one emulator first. The script doesn't check this: with two
emulators running, its `adb -s` calls fail.

The script:

- uninstalls `com.grafana.quickpizza.android` and `com.grafana.quickpizza.rn`,
  which deletes their app data (login state, Debug overrides). Reinstall them
  afterward.
- runs `gradlew clean` for the React Native Android build. It needs Java for
  this, but a failed clean doesn't stop the script.
- tries to clear `/data/dalvik-cache`, `/cache`, `/data/local/tmp`, ANR and
  tombstone files, and the logcat buffer.
- prints `df -h /data` and warns above 90 % usage.

Each `adb` call runs under GNU `timeout`. On macOS, install Coreutils and put its
`gnubin` directory on `PATH`. Without it, every `adb` step is silently skipped.
On non-rooted images, the protected directories reject deletion and the script
ignores the errors, so a "cleared" message does not guarantee the space was freed.

React Native's `react-native/scripts/clean-and-reinstall.sh` runs this script and
also cleans the Gradle and Metro caches. Its `--wipe-emulator` flag resets the
emulator.

To reset only the React Native app's data instead, run
`adb shell pm clear com.grafana.quickpizza.rn`. This deletes all of its data, not
just the cache.

## 2. Cold boot the emulator

A cold boot skips the saved snapshot and keeps installed apps and data:

```bash
adb -s emulator-5554 emu kill
emulator -avd <avd-name> -no-snapshot-load
```

Add `-wipe-data` for a factory reset. That removes all installed apps and data.

## 3. Give the AVD more storage

In Android Studio, open **Device Manager**, edit the AVD, and under **Show
Advanced Settings → Memory and Storage** set **Internal Storage** to 4096 MB or
more. Restart the emulator. Alternatively, create a new AVD with that setting.

After fixing storage, rebuild with `yarn start --reset-cache` and `yarn android`
from `Mobiles/react-native/`.
