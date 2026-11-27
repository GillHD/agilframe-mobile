#!/usr/bin/env node
/**
 * Static large-room checks for the iOS SDK (Stage 3b).
 *
 * This host has no Xcode/Swift toolchain, so the native view cannot be built
 * here. These checks assert the source-level contract that the XCTest target
 * (`AgilLargeRoomTests`) verifies on macOS:
 *  - 200-participant profile and a pure, Foundation-only participant digest;
 *  - one bounded snapshot + deltas, never the 200-id array in compact states;
 *  - reconnect transitions deduplicated and exposed as an event;
 *  - fullscreen / scroll / safe-area configuration present;
 *  - reload/reconnect keep the configuration (server, room, tokens) and rotate
 *    the per-load nonce.
 *
 * Usage: node agil/mobile/ios/scripts/webview-large-rooms-check.mjs
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SOURCES = join(ROOT, 'Sources', 'AgilCallsSDK');

function source(name) {
  return readFileSync(join(SOURCES, name), 'utf8');
}

const failures = [];
function check(condition, message) {
  console.log(`${condition ? 'PASS' : 'FAIL'}  ${message}`);
  if (!condition) failures.push(message);
}

const largeRoom = source('AgilLargeRoom.swift');
const configuration = source('AgilCallConfiguration.swift');
const bridge = source('AgilBridge.swift');
const view = source('AgilCallView.swift');

// 200-participant profile.
check(/maxParticipants\s*=\s*200/.test(largeRoom), 'large-room profile is 200 participants');
check(/resyncMin\s*=\s*32/.test(largeRoom), 'participant resync threshold is 32 ids');
check(/struct AgilParticipantDigest/.test(largeRoom), 'participant digest is a pure Swift struct');
check(/struct AgilConnectionDigest/.test(largeRoom), 'connection digest is a pure Swift struct');
check(/kind:\s*\.snapshot/.test(largeRoom) && /kind:\s*\.delta/.test(largeRoom), 'digest produces snapshot and delta updates');
check(/kind:\s*\.summary/.test(largeRoom), 'count-only updates produce a summary');

// Compact public events.
check(/case participants\(AgilParticipantUpdate\)/.test(bridge), 'bridge exposes a participants event');
check(/case connection\(AgilConnectionUpdate\)/.test(bridge), 'bridge exposes a connection event');
check(/hasParticipantIds/.test(bridge), 'snapshot distinguishes an absent id array from an empty room');
check(/maxArray:\s*500/.test(bridge), 'state parser allows the full 200-participant id array (not the 100-item default)');
check(
  /replacingParticipantIds\([\s\S]*?known:/.test(largeRoom),
  'snapshot compaction can drop participant ids for delta ticks',
);

// Config limit + tokens preserved.
check(/public let maxParticipants:\s*Int/.test(configuration), 'configuration exposes maxParticipants');
check(/AgilLargeRoom\.maxParticipants/.test(configuration), 'configuration defaults to the 200 cap');
check(/field:\s*\.maxParticipants/.test(configuration), 'configuration rejects out-of-range maxParticipants');
check(/public let joinToken/.test(configuration) && /public let identityToken/.test(configuration), 'join/identity tokens are part of the immutable configuration');

// View integration: digest, events, fullscreen, scroll, safe area, nonce.
check(/participantDigest\.apply\(/.test(view), 'view feeds state snapshots through the participant digest');
check(/connectionDigest\.apply\(/.test(view), 'view feeds connection state through the connection digest');
check(/deliver\(\.participants/.test(view), 'view delivers compact participant updates');
check(/deliver\(\.connection/.test(view), 'view delivers reconnect transitions');
check(
  /snapshot\.hasParticipantIds \? snapshot\.participantIds : nil/.test(view),
  'view passes nil for a count-only state so summary is reachable',
);
check(
  /public let participantCount:\s*Int\?/.test(bridge) && /public let participantRevision:\s*Int\?/.test(bridge),
  'compact state exposes participantCount/participantRevision',
);
check(
  /compacting\(participantUpdate/.test(largeRoom) && /compacting\(participantUpdate: update\)/.test(view),
  'view compacts state through the shared digest helper',
);
check(
  /compacting\(participantUpdate[\s\S]*?replacingParticipantIds\(\s*\[\]/.test(largeRoom),
  'compact state drops ids even for the first snapshot',
);
check(
  /participantCount:\s*count/.test(largeRoom) && /participantRevision:\s*revision/.test(largeRoom),
  'compaction carries the digest count and revision',
);
check(/isElementFullscreenEnabled\s*=\s*true/.test(view), 'WebView enables DOM element fullscreen');
check(/allowsPictureInPictureMediaPlayback\s*=\s*true/.test(view), 'WebView enables picture-in-picture');
check(/contentInsetAdjustmentBehavior\s*=\s*\.never/.test(view), 'scroll view does not add its own safe-area insets');
check(/alwaysBounceVertical\s*=\s*false/.test(view), 'scroll view does not bounce');
check(/maximumZoomScale\s*=\s*1/.test(view), 'WebView does not zoom the widget viewport');
check(/respectsSafeArea/.test(view), 'safe-area pinning remains available');
check(/rotateNonce:\s*true/.test(view), 'every SDK-initiated load rotates the bridge nonce');
check(/try AgilWidgetURL\.build\(configuration\)/.test(view), 'reload rebuilds from the same configuration (token/origin preserved)');
check(/public func reconnect\(\)/.test(view), 'host can reconnect explicitly');

// The Android/Kotlin twin is checked by its own script; both must stay at 200.
const android = readFileSync(
  join(ROOT, '..', 'android', 'agil-calls', 'src', 'main', 'java', 'com', 'agilcalls', 'sdk', 'AgilLargeRoom.kt'),
  'utf8',
);
check(/MAX_PARTICIPANTS:\s*Int\s*=\s*200/.test(android), 'Android twin uses the same 200-participant profile');

if (failures.length > 0) {
  console.error(`\n${failures.length} large-room check(s) failed`);
  process.exit(1);
}
console.log('\nAll iOS large-room source checks passed (static; run scripts/ci.sh on macOS)');
