#!/usr/bin/env node
/**
 * Static large-room checks for the Android SDK (Stage 3b).
 *
 * No Android/Gradle toolchain is available on this host, so the view cannot be
 * compiled here. These checks assert the source-level contract that
 * `AgilLargeRoomTest` verifies on the JVM:
 *  - 200-participant profile and a pure participant/connection digest;
 *  - one bounded snapshot + deltas, never the 200-id array in compact states;
 *  - reconnect transitions deduplicated and exposed as an event;
 *  - fullscreen (HTML5 custom view), scroll, viewport and safe-area handling;
 *  - load() rotates the per-load nonce and rebuilds from the same config
 *    (server/room/token preserved).
 *
 * Usage: node agil/mobile/android/scripts/webview-large-rooms-check.mjs
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MAIN = join(ROOT, 'agil-calls', 'src', 'main', 'java', 'com', 'agilcalls', 'sdk');

function source(name) {
  return readFileSync(join(MAIN, name), 'utf8');
}

const failures = [];
function check(condition, message) {
  console.log(`${condition ? 'PASS' : 'FAIL'}  ${message}`);
  if (!condition) failures.push(message);
}

const largeRoom = source('AgilLargeRoom.kt');
const config = source('AgilCallConfig.kt');
const events = source('AgilCallEvent.kt');
const view = source('AgilCallView.kt');
const protocol = source('AgilBridgeProtocol.kt');

// 200-participant profile.
check(/MAX_PARTICIPANTS:\s*Int\s*=\s*200/.test(largeRoom), 'large-room profile is 200 participants');
check(/RESYNC_MIN:\s*Int\s*=\s*32/.test(largeRoom), 'participant resync threshold is 32 ids');
check(/MAX_PARTICIPANT_IDS\s*=\s*500/.test(protocol), 'state parser allows the full 200-participant id array (with truncation headroom)');
check(/class AgilParticipantDigest/.test(largeRoom), 'participant digest exists');
check(/class AgilConnectionDigest/.test(largeRoom), 'connection digest exists');
check(/SNAPSHOT/.test(largeRoom) && /DELTA/.test(largeRoom) && /SUMMARY/.test(largeRoom), 'digest supports snapshot/delta/summary');
check(/coerceIn\(2,\s*AgilLargeRoom\.MAX_PARTICIPANTS\)/.test(largeRoom), 'digest clamps to the 200-participant profile');

// Compact public events.
check(/data class Participants\(/.test(events), 'events expose compact Participants');
check(/data class Connection\(/.test(events), 'events expose Connection/reconnect');
check(/AgilConnectionState\.RECONNECTING/.test(largeRoom), 'reconnect state is modelled');

// Config limit + tokens preserved.
check(/val maxParticipants:\s*Int\s*=\s*AgilLargeRoom\.MAX_PARTICIPANTS/.test(config), 'config exposes maxParticipants');
check(/maxParticipants must be between 2 and/.test(config), 'config rejects out-of-range maxParticipants');
check(/val token:\s*String\?/.test(config) && /val identityToken:\s*String\?/.test(config), 'join/identity tokens remain immutable config fields');

// View integration.
check(/participantDigest\.apply\(/.test(view), 'view feeds snapshots through the participant digest');
check(/connectionDigest\.apply\(/.test(view), 'view feeds connection state through the connection digest');
check(/AgilCallEvent\.Participants\(/.test(view), 'view emits compact participant updates');
check(/AgilCallEvent\.Connection\(/.test(view), 'view emits reconnect transitions');
check(
  /hasParticipantIds/.test(protocol) && /hasParticipantIds = hasParticipantIds/.test(protocol),
  'state parser flags whether participantIds were present',
);
check(
  /if \(snapshot\.hasParticipantIds\) snapshot\.participantIds else null/.test(view),
  'view passes null for a count-only state so summary is reachable',
);
check(
  /participantCount/.test(events) && /participantRevision/.test(events),
  'compact state exposes participantCount/participantRevision',
);
check(
  /compactForParticipantUpdate/.test(largeRoom) && /compactForParticipantUpdate\(update\)/.test(view),
  'view compacts state through the shared digest helper',
);
check(
  /participantIds = emptyList\(\)/.test(largeRoom),
  'compact state drops ids even for the first snapshot',
);
check(/onShowCustomView/.test(view) && /onHideCustomView/.test(view), 'WebChromeClient supports HTML5 fullscreen');
check(/isNestedScrollingEnabled\s*=\s*true/.test(view), 'WebView enables nested scrolling for the participant list');
check(/setSupportZoom\(false\)/.test(view), 'WebView disables zoom for the widget viewport');
check(/useWideViewPort\s*=\s*true/.test(view), 'WebView honours the mobile viewport meta');
check(/WindowInsets\.Type\.displayCutout\(\)/.test(view), 'safe-area padding includes the display cutout');
check(/bridgeNonce = AgilBridgeEnvelope\.newNonce\(\)/.test(view), 'load() rotates the bridge nonce');
check(/fun reconnect\(\)/.test(view), 'host can reconnect explicitly');
check(/config\.toTarget\(\)/.test(view), 'load() rebuilds from the same config (token/origin preserved)');

const ios = readFileSync(
  join(ROOT, '..', 'ios', 'Sources', 'AgilCallsSDK', 'AgilLargeRoom.swift'),
  'utf8',
);
check(/maxParticipants\s*=\s*200/.test(ios), 'iOS twin uses the same 200-participant profile');

if (failures.length > 0) {
  console.error(`\n${failures.length} large-room check(s) failed`);
  process.exit(1);
}
console.log('\nAll Android large-room source checks passed (static; run the JVM tests on a machine with Gradle)');
