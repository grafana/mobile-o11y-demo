import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const REPO_ROOT = fileURLToPath(new URL('../..', import.meta.url));
const VERSION_PATTERN = /^\d+\.\d+\.\d+$/;

const TARGETS = {
  'react-native': {
    file: 'Mobiles/react-native/src/core/config/appVersionResolver.ts',
    pattern: /const\s+DEFAULT_APP_VERSION\s*=\s*['"]([^'"]+)['"]/,
  },
  'android-native': {
    file: 'Mobiles/android/app/build.gradle.kts',
    pattern: /quickPizzaDemoVersionName\s*=\s*providers\.gradleProperty\("quickpizzaDemoVersionName"\)\.orElse\("([^"]+)"\)/,
  },
  'ios-native': {
    file: 'Mobiles/ios/QuickPizzaIos.xcodeproj/project.pbxproj',
    pattern: /MARKETING_VERSION = ([^;\s]+);/,
  },
};

export function readDemoAppBaseVersion(target, { repoRoot = REPO_ROOT } = {}) {
  const config = TARGETS[target];
  if (!config) {
    throw new Error(`Unknown demo app target: ${target}`);
  }

  const filePath = path.join(repoRoot, config.file);
  const content = readFileSync(filePath, 'utf8');
  const version = config.pattern.exec(content)?.[1];

  if (!version) {
    throw new Error(`Could not resolve base version for ${target}`);
  }
  if (!VERSION_PATTERN.test(version)) {
    throw new Error(`Expected semver base version for ${target}, got ${version}`);
  }

  return version;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  console.log(readDemoAppBaseVersion(process.argv[2]));
}
