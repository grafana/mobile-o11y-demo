import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { readDemoAppBaseVersion } from './read-demo-app-base-version.mjs';

describe('readDemoAppBaseVersion', () => {
  it('reads the React Native Faro app version base', () => {
    assert.equal(readDemoAppBaseVersion('react-native'), '1.0.0');
  });

  it('reads the native Android versionName base', () => {
    assert.equal(readDemoAppBaseVersion('android-native'), '1.0.0');
  });

  it('reads the native iOS MARKETING_VERSION base', () => {
    assert.equal(readDemoAppBaseVersion('ios-native'), '1.1.0');
  });

  it('rejects unknown targets', () => {
    assert.throws(() => readDemoAppBaseVersion('unknown'), /Unknown demo app target/);
  });
});
