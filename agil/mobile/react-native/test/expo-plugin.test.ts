import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const source = readFileSync(
  fileURLToPath(new URL('../expo/withAgilCall.cjs', import.meta.url)),
  'utf8',
);

function loadPlugin() {
  const mockConfigPlugins = {
    withInfoPlist(config: Record<string, unknown>, apply: (config: Record<string, unknown>) => unknown) {
      const next = { ...config, modResults: { ...(config.modResults as object) } };
      return apply(next);
    },
    withAndroidManifest(config: Record<string, unknown>, apply: (config: Record<string, unknown>) => unknown) {
      const current = (config.modResults as Record<string, unknown>) ?? {};
      const next = {
        ...config,
        modResults: {
          ...current,
          manifest: { ...((current.manifest as object) ?? {}) },
        },
      };
      return apply(next);
    },
  };
  const sandbox = {
    module: { exports: {} as Record<string, unknown> },
    exports: {},
    require: (id: string) => {
      if (id === '@expo/config-plugins') return mockConfigPlugins;
      throw new Error(`Unexpected require: ${id}`);
    },
    console,
  };
  vm.runInNewContext(source, sandbox);
  return sandbox.module.exports as unknown as (
    config: Record<string, unknown>,
    props?: Record<string, unknown>,
  ) => Record<string, unknown>;
}

test('Expo plugin adds iOS usage strings and Android permissions', () => {
  const plugin = loadPlugin();
  const result = plugin({
    modResults: {
      NSCameraUsageDescription: 'existing camera text',
      manifest: {
        'uses-permission': [{ $: { 'android:name': 'android.permission.INTERNET' } }],
      },
    },
  });
  const modResults = result.modResults as Record<string, unknown>;
  assert.equal(modResults.NSCameraUsageDescription, 'existing camera text');
  assert.match(String(modResults.NSMicrophoneUsageDescription), /microphone/i);

  const manifest = modResults.manifest as Record<string, unknown>;
  const permissions = manifest['uses-permission'] as Array<{ $: Record<string, string> }>;
  const names = permissions.map((entry) => entry.$['android:name']);
  assert.ok(names.includes('android.permission.INTERNET'));
  assert.ok(names.includes('android.permission.CAMERA'));
  assert.ok(names.includes('android.permission.RECORD_AUDIO'));
  assert.ok(names.includes('android.permission.MODIFY_AUDIO_SETTINGS'));

  const features = manifest['uses-feature'] as Array<{ $: Record<string, string> }>;
  assert.ok(features.some((entry) => entry.$['android:name'] === 'android.hardware.camera'));
  assert.ok(features.some((entry) => entry.$['android:name'] === 'android.hardware.microphone'));
});

test('Expo plugin is idempotent and accepts custom permission text', () => {
  const plugin = loadPlugin();
  const first = plugin({ modResults: {} }, {
    cameraPermission: 'Custom camera',
    microphonePermission: 'Custom microphone',
  });
  const second = plugin(first, {
    cameraPermission: 'Custom camera',
    microphonePermission: 'Custom microphone',
  });
  const modResults = second.modResults as Record<string, unknown>;
  assert.equal(modResults.NSCameraUsageDescription, 'Custom camera');
  assert.equal(modResults.NSMicrophoneUsageDescription, 'Custom microphone');
  const manifest = modResults.manifest as Record<string, unknown>;
  const permissions = manifest['uses-permission'] as Array<{ $: Record<string, string> }>;
  assert.equal(
    permissions.filter((entry) => entry.$['android:name'] === 'android.permission.CAMERA').length,
    1,
  );
});
