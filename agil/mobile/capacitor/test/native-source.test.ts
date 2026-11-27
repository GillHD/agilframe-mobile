import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Static guards for the Swift/Kotlin bridge fixes. This host has no Xcode,
 * Swift or Android toolchain, so native behaviour is asserted from source here
 * and must still be rebuilt/run on a device or simulator before release.
 */
const PACKAGE_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

function source(relativePath: string): string {
  return readFileSync(join(PACKAGE_ROOT, relativePath), 'utf8');
}

const IOS_CONTROLLER = 'ios/Sources/AgilCallsPlugin/AgilCallViewController.swift';
const IOS_NORMALIZER = 'ios/Sources/AgilCallsPlugin/AgilOriginNormalizer.swift';
const ANDROID_ACTIVITY =
  'android/src/main/java/com/agil/calls/AgilCallActivity.kt';
const ANDROID_BRIDGE = 'android/src/main/java/com/agil/calls/AgilCallBridge.kt';
const ANDROID_ENVELOPE =
  'android/src/main/java/com/agil/calls/AgilBridgeEnvelope.kt';

test('iOS origin normalizer maps WKSecurityOrigin port 0 to the scheme default', () => {
  const normalizer = source(IOS_NORMALIZER);
  // Pure helper: importable by an XCTest target without WebKit/UIKit.
  assert.doesNotMatch(normalizer, /^\s*import (WebKit|UIKit)$/m);
  assert.match(normalizer, /import Foundation/);
  // Port 0 (WKWebView's "effective default") and explicit default ports collapse.
  assert.match(normalizer, /requestedPort == 0 \? defaultPort : requestedPort/);
  assert.match(normalizer, /scheme == "https" \? 443 : 80/);
  assert.match(normalizer, /effectivePort == defaultPort/);
  // An explicit non-default port is preserved, never dropped.
  assert.match(normalizer, /return "\\\(scheme\):\/\/\\\(host\):\\\(effectivePort\)"/);
  // Credentials and non-http(s) schemes stay rejected.
  assert.match(normalizer, /components\.user == nil/);
  assert.match(normalizer, /components\.password == nil/);
  assert.match(normalizer, /scheme == "https" \|\| scheme == "http"/);

  const controller = source(IOS_CONTROLLER);
  // Both the URL origin (widgetOrigin) and the frame security origin go through
  // the same normalizer, so port 443, port 0 and no-port all compare equal.
  assert.match(
    controller,
    /static func origin\(of urlString: String\) -> String\? \{\s*AgilOriginNormalizer\.normalize\(urlString: urlString\)/,
  );
  assert.match(
    controller,
    /static func origin\(of securityOrigin: WKSecurityOrigin\) -> String\? \{\s*AgilOriginNormalizer\.normalize\(\s*securityScheme: securityOrigin\.protocol,\s*host: securityOrigin\.host,\s*port: securityOrigin\.port/,
  );
  // The message guard still requires a non-nil, exactly-equal origin.
  assert.match(controller, /guard let messageOrigin = Self\.origin\(of: message\.frameInfo\.securityOrigin\),\s*messageOrigin == widgetOrigin else \{ return \}/);
  // The old buggy branch (append raw port) is gone.
  assert.doesNotMatch(controller, /return "\\\(scheme\):\/\/\\\(host\):\\\(port\)"/);
});

test('iOS queues sendAction/sendChat until the widget page is live', () => {
  const controller = source(IOS_CONTROLLER);
  assert.match(controller, /private var pageReady = false/);
  assert.match(controller, /private var pendingCommands: \[\[String: Any\]\] = \[\]/);
  assert.match(controller, /private static let maxPendingCommands = 20/);
  assert.match(
    controller,
    /func sendAction\(_ action: String\) \{\s*enqueueOrPost\(\["type": "agil:action", "action": action\]\)/,
  );
  assert.match(
    controller,
    /func sendChat\(_ text: String\) \{\s*enqueueOrPost\(\["type": "agil:chat-send", "text": text\]\)/,
  );
  assert.match(controller, /guard pageReady else \{[\s\S]*?pendingCommands\.append\(message\)/);
  assert.match(controller, /private func flushPendingCommands\(\)/);
  // Readiness is detected in the bridge callback and resets on a new document.
  assert.match(controller, /if !pageReady, Self\.isWidgetMessage\(text\) \{/);
  assert.match(controller, /didStartProvisionalNavigation[\s\S]*?pageReady = false/);
});

test('Android validates the nonce and unwraps the envelope before forwarding', () => {
  const activity = source(ANDROID_ACTIVITY);
  assert.match(activity, /if \(callerNonce != nonce\) return/);
  assert.match(activity, /val payload = AgilBridgeEnvelope\.unwrap\(message, nonce\) \?: return/);
  assert.match(activity, /AgilCallBridge\.emit\(payload\)/);
  // Forwarding the raw envelope was the P0 regression.
  assert.doesNotMatch(activity, /AgilCallBridge\.emit\(message\)/);

  const envelope = source(ANDROID_ENVELOPE);
  assert.match(envelope, /__agilBridgeNonce/);
  assert.match(envelope, /envelopeNonce != nonce/);
  assert.match(envelope, /envelope\.opt\("message"\) as\? String/);
  assert.match(envelope, /MAX_CHARS/);
});

test('Android queues sendAction/sendChat until agil:ready (page live)', () => {
  const bridge = source(ANDROID_BRIDGE);
  assert.match(bridge, /private var pageReady = false/);
  assert.match(bridge, /fun markPageReady\(\)/);
  assert.match(bridge, /fun resetPageReady\(\)/);
  assert.match(bridge, /private val pendingCommands = ArrayDeque<Pair<String, String>>\(\)/);
  assert.match(bridge, /if \(pageReady\) \{[\s\S]*?senderFor\(kind\)/);
  assert.match(bridge, /if \(!pendingAllowed \|\| pendingCommands\.size >= MAX_PENDING\) return false/);
  // The sender being installed is no longer enough to flush the queue.
  assert.doesNotMatch(bridge, /while \(pendingActions\.isNotEmpty\(\)\)/);

  const activity = source(ANDROID_ACTIVITY);
  assert.match(activity, /AgilCallBridge\.markPageReady\(\)/);
  assert.match(activity, /AgilCallBridge\.resetPageReady\(\)/);
  assert.match(activity, /onPageStarted[\s\S]*?resetPageReady\(\)/);
});

test('Capacitor iOS shell applies viewport, zoom, full-screen and safe-area rules', () => {
  const controller = source(IOS_CONTROLLER);
  // Presentation parity with the AGIL iOS SDK AgilCallView.
  assert.match(controller, /contentInsetAdjustmentBehavior\s*=\s*\.never/);
  assert.match(controller, /alwaysBounceVertical\s*=\s*false/);
  assert.match(controller, /isDirectionalLockEnabled\s*=\s*true/);
  assert.match(controller, /maximumZoomScale\s*=\s*1/);
  assert.match(controller, /allowsLinkPreview\s*=\s*false/);
  assert.match(controller, /isElementFullscreenEnabled\s*=\s*true/);
  assert.match(controller, /allowsPictureInPictureMediaPlayback\s*=\s*true/);
  assert.match(controller, /preferredContentMode\s*=\s*\.mobile/);
  // Safe area is owned by the constraint, not by scroll-view insets.
  assert.match(controller, /safeAreaLayoutGuide\.topAnchor/);
});

test('Capacitor Android shell applies viewport, nested scroll, cutout and fullscreen', () => {
  const activity = source(ANDROID_ACTIVITY);
  assert.match(activity, /useWideViewPort\s*=\s*true/);
  assert.match(activity, /loadWithOverviewMode\s*=\s*false/);
  assert.match(activity, /setSupportZoom\(false\)/);
  assert.match(activity, /isNestedScrollingEnabled\s*=\s*true/);
  assert.match(activity, /OVER_SCROLL_NEVER/);
  assert.match(activity, /displayCutout\(\)/);
  assert.match(activity, /onShowCustomView/);
  assert.match(activity, /onHideCustomView/);
});
