'use strict';

/**
 * Expo config plugin for `@agil/calls-react-native`.
 *
 * Usage (app.json / app.config.js):
 *
 *   "plugins": [
 *     ["@agil/calls-react-native/expo-plugin", {
 *       "cameraPermission": "Разрешите доступ к камере для видеозвонков",
 *       "microphonePermission": "Разрешите доступ к микрофону для звонков"
 *     }]
 *   ]
 *
 * It adds the iOS usage strings and the Android CAMERA/RECORD_AUDIO manifest
 * entries. No native binaries or WebRTC modules are involved.
 */

const CAMERA_PERMISSION = 'android.permission.CAMERA';
const MICROPHONE_PERMISSION = 'android.permission.RECORD_AUDIO';
const AUDIO_SETTINGS_PERMISSION = 'android.permission.MODIFY_AUDIO_SETTINGS';

const DEFAULT_CAMERA_TEXT = 'Allow $(PRODUCT_NAME) to access the camera for video calls.';
const DEFAULT_MICROPHONE_TEXT = 'Allow $(PRODUCT_NAME) to access the microphone for calls.';

function withAgilCall(config, props = {}) {
  const { withInfoPlist, withAndroidManifest } = require('@expo/config-plugins');
  const cameraText = props.cameraPermission || DEFAULT_CAMERA_TEXT;
  const microphoneText = props.microphonePermission || DEFAULT_MICROPHONE_TEXT;

  config = withInfoPlist(config, (configWithInfoPlist) => {
    const info = configWithInfoPlist.modResults;
    if (!info.NSCameraUsageDescription) info.NSCameraUsageDescription = cameraText;
    if (!info.NSMicrophoneUsageDescription) info.NSMicrophoneUsageDescription = microphoneText;
    return configWithInfoPlist;
  });

  config = withAndroidManifest(config, (configWithManifest) => {
    const manifest = configWithManifest.modResults.manifest;
    manifest['uses-permission'] = manifest['uses-permission'] || [];
    const existingPermissions = new Set(
      manifest['uses-permission'].map((entry) => entry && entry.$ && entry.$['android:name']),
    );
    for (const permission of [
      CAMERA_PERMISSION,
      MICROPHONE_PERMISSION,
      AUDIO_SETTINGS_PERMISSION,
    ]) {
      if (!existingPermissions.has(permission)) {
        manifest['uses-permission'].push({ $: { 'android:name': permission } });
      }
    }

    manifest['uses-feature'] = manifest['uses-feature'] || [];
    const hasCameraFeature = manifest['uses-feature'].some(
      (entry) => entry && entry.$ && entry.$['android:name'] === 'android.hardware.camera',
    );
    if (!hasCameraFeature) {
      manifest['uses-feature'].push({
        $: { 'android:name': 'android.hardware.camera', 'android:required': 'false' },
      });
    }
    const hasMicrophoneFeature = manifest['uses-feature'].some(
      (entry) => entry && entry.$ && entry.$['android:name'] === 'android.hardware.microphone',
    );
    if (!hasMicrophoneFeature) {
      manifest['uses-feature'].push({
        $: { 'android:name': 'android.hardware.microphone', 'android:required': 'false' },
      });
    }
    return configWithManifest;
  });

  return config;
}

module.exports = withAgilCall;
module.exports.default = withAgilCall;
