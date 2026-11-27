/**
 * Native permission helpers for the WebView call screen.
 *
 * iOS: WKWebView itself prompts for camera/microphone on the first
 * `getUserMedia()` call, provided `NSCameraUsageDescription` /
 * `NSMicrophoneUsageDescription` exist in Info.plist. React Native cannot
 * pre-grant those permissions without a native module, so this module reports
 * `system-prompt` and the app explains the prompt.
 *
 * Android: WebView can only capture after the *app* holds CAMERA/RECORD_AUDIO.
 * This module requests them at runtime; the manifest entries are documented in
 * README/docs/mobile.md.
 */
import { Linking, PermissionsAndroid, Platform } from 'react-native';
import type { AgilMediaPermissions } from './core-types.js';

export type AgilPermissionStatus =
  | 'granted'
  | 'denied'
  | 'blocked'
  | 'system-prompt'
  | 'not-requested'
  | 'unavailable';

export interface AgilPermissionReport {
  camera: AgilPermissionStatus;
  microphone: AgilPermissionStatus;
  /** At least one permission is permanently blocked; the app should open Settings. */
  settingsRequired: boolean;
}

function androidStatus(result: string | undefined): AgilPermissionStatus {
  if (result === PermissionsAndroid.RESULTS.GRANTED) return 'granted';
  if (result === PermissionsAndroid.RESULTS.NEVER_ASK_AGAIN) return 'blocked';
  if (result === PermissionsAndroid.RESULTS.DENIED) return 'denied';
  return 'unavailable';
}

/**
 * Requests Android CAMERA/RECORD_AUDIO permissions. On iOS it resolves with
 * `system-prompt` (the WKWebView prompt is triggered by the widget itself).
 */
export async function requestAgilMediaPermissions(
  permissions: AgilMediaPermissions = {},
): Promise<AgilPermissionReport> {
  const camera = permissions.camera !== false;
  const microphone = permissions.microphone !== false;

  if (!camera && !microphone) {
    return { camera: 'not-requested', microphone: 'not-requested', settingsRequired: false };
  }

  if (Platform.OS !== 'android') {
    return {
      camera: camera ? 'system-prompt' : 'not-requested',
      microphone: microphone ? 'system-prompt' : 'not-requested',
      settingsRequired: false,
    };
  }

  const version = typeof Platform.Version === 'number' ? Platform.Version : Number(Platform.Version);
  if (Number.isFinite(version) && version > 0 && version < 23) {
    return {
      camera: camera ? 'granted' : 'not-requested',
      microphone: microphone ? 'granted' : 'not-requested',
      settingsRequired: false,
    };
  }

  const requested: string[] = [];
  if (camera) requested.push(PermissionsAndroid.PERMISSIONS.CAMERA);
  if (microphone) requested.push(PermissionsAndroid.PERMISSIONS.RECORD_AUDIO);

  try {
    const results = await PermissionsAndroid.requestMultiple(requested);
    const cameraStatus = camera ? androidStatus(results[PermissionsAndroid.PERMISSIONS.CAMERA]) : 'not-requested';
    const microphoneStatus = microphone
      ? androidStatus(results[PermissionsAndroid.PERMISSIONS.RECORD_AUDIO])
      : 'not-requested';
    return {
      camera: cameraStatus,
      microphone: microphoneStatus,
      settingsRequired: cameraStatus === 'blocked' || microphoneStatus === 'blocked',
    };
  } catch {
    return {
      camera: camera ? 'unavailable' : 'not-requested',
      microphone: microphone ? 'unavailable' : 'not-requested',
      settingsRequired: false,
    };
  }
}

/** Opens the system settings page for this app (permission recovery). */
export async function openAppSettings(): Promise<void> {
  try {
    if (Platform.OS === 'ios') {
      await Linking.openURL('app-settings:');
      return;
    }
    if (Platform.OS === 'android') {
      await Linking.openSettings();
    }
  } catch {
    // Settings are unavailable in simulators/restricted devices; caller may show a hint.
  }
}
