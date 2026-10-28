# React Native source maps

Release builds run Hermes bytecode, so device stack traces point at bytecode
offsets. Frontend Observability maps them back to `src/` files when it has a
source map for that exact build, uploaded under the same bundle id that the app
reports as `meta.app.bundleId`.

A release build does this in four steps:

1. Metro bundles the JS with `@grafana/faro-metro-plugin` (`metro.config.js`),
   which bakes in the bundle id.
2. Hermes compiles the bundle to bytecode.
3. `compose-source-maps.js` merges the Metro and Hermes maps into one composed
   map. Only the composed map resolves device frames.
4. `faro-cli metro upload` uploads the composed map under the bundle id. On
   Android a Gradle step runs it. On iOS the committed Xcode phase
   `[Faro] Upload composed source map (Release)` runs it.

Plugin details: [`@grafana/faro-metro-plugin` README](https://github.com/grafana/faro-javascript-bundler-plugins/blob/main/packages/faro-metro-plugin/README.md).

## Configure

```bash
cp sourcemaps.config.example.json sourcemaps.config.json   # gitignored
```

| Env var | `sourcemaps.config.json` key | Value |
| --- | --- | --- |
| — | `appName` | Must stay `QuickPizza_ReactNative`, the `app.name` in `src/bootstrap.ts`. |
| `FARO_SOURCEMAP_ENDPOINT` | `endpoint` | From **Frontend Observability → your app → Settings → Source maps** (not the collector URL). |
| `FARO_SOURCEMAP_APP_ID` | `appId` | Same page. |
| `FARO_SOURCEMAP_STACK_ID` | `stackId` | Same page. |
| `FARO_SOURCEMAP_API_KEY` | `apiKey` | Access policy token with `sourcemaps:write` (add `sourcemaps:read` / `sourcemaps:delete` to list or remove maps). Without it the API returns `401 invalid scope requested`. |
| `FARO_BUNDLE_ID` | — | iOS only. One stable id per shipped build. |

Env vars override the JSON values. The iOS upload phase reads **only** env vars,
from the shell or from the gitignored `ios/.xcode.env.local`.

**Bundle ids:** Android derives `applicationId@versionCode@versionName` from the
Faro Gradle plugin and writes it to `android/app/build/faro/bundle-id-release.txt`.
For this app it is `com.grafana.quickpizza.rn@1@1.0.0`, distinct from the native
Android app's `com.grafana.quickpizza.android@1@1.0.0`. The RN build uploads
both the JS map and the native R8 symbols under that id. On iOS, set
`FARO_BUNDLE_ID` yourself. Changing the id means uploading a new map.

## Build and upload

Run from `Mobiles/react-native/`. `ENABLE_FARO_PAYLOAD_DIAGNOSTICS=true` makes
the app log `[Faro diagnostics]` payloads, which you need for verification.

```bash
export FARO_SOURCEMAP_ENDPOINT="https://faro-api-<region>.grafana.net/faro/api/v1"
export FARO_SOURCEMAP_APP_ID="<app-id>"
export FARO_SOURCEMAP_STACK_ID="<stack-id>"
export FARO_SOURCEMAP_API_KEY="<token>"
export ENABLE_FARO_PAYLOAD_DIAGNOSTICS=true

# Android
yarn android --mode=release

# iOS (SOURCEMAP_FILE is already set on the Release configuration)
export FARO_BUNDLE_ID="$(git rev-parse --short HEAD)-$(date +%s)"
yarn ios --mode Release
```

Composed map paths:

- Android: `android/app/build/generated/sourcemaps/react/release/index.android.bundle.map`
- iOS: `$(DERIVED_FILE_DIR)/main.jsbundle.map` (under `~/Library/Developer/Xcode/DerivedData`)

On Android a failed upload fails the build, but missing credentials, map or
bundle-id file skip the upload silently, so a green build does not prove an upload.
Unset `FARO_BUNDLE_ID` before an Android release build; an iOS-style value is not
a valid Android release identity and fails the build. On iOS it only logs a warning; a
`[Faro] Skipping composed source map upload` line means a `FARO_*` var is
missing, the map is missing, or the upload is disabled. Set
`FARO_SKIP_SOURCEMAP_UPLOAD=1` to skip the upload while iterating.

To re-upload manually (Android example):

```bash
npx faro-cli metro upload \
  --map android/app/build/generated/sourcemaps/react/release/index.android.bundle.map \
  --endpoint "$FARO_SOURCEMAP_ENDPOINT" \
  --app-id "$FARO_SOURCEMAP_APP_ID" \
  --stack-id "$FARO_SOURCEMAP_STACK_ID" \
  --api-key "$FARO_SOURCEMAP_API_KEY" \
  --bundle-id "$(cat android/app/build/faro/bundle-id-release.txt)"
```

## Verify

1. Install the release build, then tap **Debug → Exceptions → Handled exception**.
2. Check the payload: `adb logcat -d | rg '\[Faro diagnostics\]'` or
   `npx react-native log-ios | rg 'Faro diagnostics'`. The `[init]` line shows
   `meta.app.bundleId`. The `[exception]` frames name `index.android.bundle` or
   `main.jsbundle`.
3. Check the map locally with `scripts/verify-sourcemap.js`:

   ```bash
   node scripts/verify-sourcemap.js --android-release --logcat
   # If logcat rotated: add --logcat-clear --logcat-wait 15000, then trigger the exception within 15 s
   node scripts/verify-sourcemap.js --ios-release --ios-log   # or --ios-log path/to/simulator.log
   ```

   | Verdict | Meaning | Next step |
   | --- | --- | --- |
   | **PASS** | At least one device frame resolves into `src/`. | Upload (or rely on the build step) and check Grafana. `node_modules/react-native` frames are normal. |
   | **FAIL** | No frame resolves, and the composed map has empty or flattened mappings. | Often an outdated `@grafana/faro-metro-plugin`. Upgrade it, then rebuild (Android: `( cd android && ./gradlew :app:createBundleReleaseJsAndAssets --rerun-tasks )`). |
   | **WARN** | The map has mappings, but no frame resolves into `src/`. | The frames probably come from another build. Reinstall, re-trigger, rerun. |

   The script checks frames against the map. It does not compare bundle ids, so
   confirm separately that the diagnostics `bundleId` matches the upload.
4. In Frontend Observability, open the error. Frames should point at `src/...`.
   The collector caches stack-trace lookups for up to about 30 minutes, so test
   with an error the build has not sent before, such as
   **Debug → Unhandled exception**.
