/**
 * Web fallback for `@agil/calls-capacitor`.
 *
 * On the web the "in-app WebView" is a full-screen same-page iframe pointing at
 * `/embed.html`. The iframe keeps running the hosted widget; this class owns the
 * overlay, the origin-checked `postMessage` bridge, theme commands and the
 * browser permission helpers. Browsers without iframe support fall back to a
 * new tab (`presentation: 'external'`).
 *
 * Widget messages are forwarded to the JS facade as raw JSON on the
 * `callMessage` channel, exactly like the native shells, so parsing/sanitizing
 * happens in one place (`src/bridge.ts`).
 */
import { WebPlugin } from '@capacitor/core';

import {
  actionMessage,
  chatMessage,
  parseWidgetMessage,
  schemeMessage,
  themeMessage,
} from './bridge.js';
import type { HostToWidgetMessage } from './bridge.js';
import type {
  AgilCallAction,
  AgilCallsNativePlugin,
  AgilNativeOpenCallOptions,
  AgilOpenCallResult,
  AgilPermissionReport,
  AgilPermissionStatus,
  AgilSupportResult,
  AgilThemeOptions,
} from './definitions.js';

const OVERLAY_ID = 'agil-calls-overlay';
const IFRAME_ID = 'agil-calls-frame';
const MAX_QUEUED_MESSAGES = 50;

function supportsIframe(): boolean {
  return typeof document !== 'undefined' && typeof HTMLIFrameElement !== 'undefined';
}

function makeCallId(): string {
  const random = Math.random().toString(36).slice(2, 10);
  return `agil-${Date.now().toString(36)}-${random}`;
}

async function queryPermission(name: 'camera' | 'microphone'): Promise<AgilPermissionStatus> {
  const permissions = typeof navigator !== 'undefined' ? navigator.permissions : undefined;
  if (!permissions || typeof permissions.query !== 'function') return 'unavailable';
  try {
    const status = await permissions.query({ name: name as PermissionName });
    if (status.state === 'granted') return 'granted';
    if (status.state === 'denied') return 'denied';
    return 'prompt';
  } catch {
    return 'unavailable';
  }
}

async function requestOne(kind: 'camera' | 'microphone'): Promise<AgilPermissionStatus> {
  const media = typeof navigator !== 'undefined' ? navigator.mediaDevices : undefined;
  if (!media || typeof media.getUserMedia !== 'function') return 'unavailable';
  try {
    const stream = await media.getUserMedia(kind === 'camera' ? { video: true } : { audio: true });
    for (const track of stream.getTracks()) track.stop();
    return 'granted';
  } catch (error) {
    const name = error instanceof Error ? error.name : '';
    if (name === 'NotAllowedError' || name === 'SecurityError') return 'denied';
    return 'unavailable';
  }
}

export class AgilCallsWeb extends WebPlugin implements AgilCallsNativePlugin {
  private frame: HTMLIFrameElement | null = null;
  private overlay: HTMLDivElement | null = null;
  private origin: string | null = null;
  private callId: string | null = null;
  private ready = false;
  private readonly queue: HostToWidgetMessage[] = [];
  private readonly listener = (event: MessageEvent): void => this.handleMessage(event);

  async openCall(options: AgilNativeOpenCallOptions): Promise<AgilOpenCallResult> {
    const url = typeof options?.url === 'string' ? options.url : '';
    if (!url) throw new Error('openCall requires a widget URL');
    if (options.presentation === 'external' || !supportsIframe()) {
      if (typeof window === 'undefined') throw new Error('No window available');
      window.open(url, '_blank', 'noopener,noreferrer');
      return { callId: makeCallId(), mode: 'external' };
    }

    let origin: string;
    try {
      origin = new URL(url).origin;
    } catch {
      throw new Error('openCall received an invalid widget URL');
    }
    if (origin === 'null' || !/^https?:\/\//.test(origin)) {
      throw new Error('openCall requires an http(s) widget URL');
    }

    await this.close();
    this.origin = origin;
    this.callId = makeCallId();
    this.ready = false;

    const overlay = document.createElement('div');
    overlay.id = OVERLAY_ID;
    overlay.setAttribute('role', 'dialog');
    overlay.setAttribute('aria-label', 'AgilFrame');
    overlay.style.cssText = [
      'position:fixed',
      'inset:0',
      'z-index:2147483647',
      'background:#080d16',
      'display:block',
    ].join(';');

    const frame = document.createElement('iframe');
    frame.id = IFRAME_ID;
    frame.src = url;
    frame.title = 'AgilFrame';
    frame.setAttribute(
      'allow',
      'camera; microphone; fullscreen; display-capture; autoplay; clipboard-write',
    );
    frame.setAttribute('allowfullscreen', '');
    frame.setAttribute('referrerpolicy', 'no-referrer');
    frame.style.cssText = ['border:0', 'width:100%', 'height:100%', 'display:block'].join(';');
    overlay.appendChild(frame);

    document.body.appendChild(overlay);
    this.overlay = overlay;
    this.frame = frame;
    window.addEventListener('message', this.listener);

    frame.addEventListener('error', () => {
      this.emitRaw({
        type: 'agil:event',
        event: 'error',
        payload: { code: 'load_failed', message: 'The call iframe failed to load' },
      });
    });

    this.startReadyTimeout();
    return { callId: this.callId, mode: 'in-app' };
  }

  async close(): Promise<void> {
    if (typeof window !== 'undefined') {
      window.removeEventListener('message', this.listener);
    }
    this.frame?.remove();
    this.overlay?.remove();
    this.frame = null;
    this.overlay = null;
    this.origin = null;
    this.callId = null;
    this.ready = false;
    this.queue.length = 0;
  }

  async isSupported(): Promise<AgilSupportResult> {
    const inAppWebView = supportsIframe();
    return {
      supported: inAppWebView || typeof window !== 'undefined',
      inAppWebView,
      ...(inAppWebView ? {} : { reason: 'iframes are unavailable; calls open in a new tab' }),
    };
  }

  async setTheme(options: AgilThemeOptions): Promise<void> {
    if (!options || typeof options !== 'object') throw new Error('setTheme requires options');
    if (options.scheme) {
      this.post(schemeMessage(options.scheme));
    }
    if (options.theme && Object.keys(options.theme).length > 0) {
      this.post(themeMessage(options.theme));
    }
  }

  async sendAction({ action }: { action: AgilCallAction }): Promise<void> {
    this.post(actionMessage(action));
  }

  async sendChat({ text }: { text: string }): Promise<void> {
    this.post(chatMessage(text));
  }

  async checkPermissions(): Promise<AgilPermissionReport> {
    const camera = await queryPermission('camera');
    const microphone = await queryPermission('microphone');
    return { camera, microphone, settingsRequired: camera === 'denied' || microphone === 'denied' };
  }

  async requestPermissions(): Promise<AgilPermissionReport> {
    const camera = await requestOne('camera');
    const microphone = await requestOne('microphone');
    return { camera, microphone, settingsRequired: camera === 'denied' || microphone === 'denied' };
  }

  private post(message: HostToWidgetMessage): void {
    if (!this.frame || !this.origin) return;
    if (!this.ready) {
      if (this.queue.length >= MAX_QUEUED_MESSAGES) return;
      this.queue.push(message);
      return;
    }
    try {
      this.frame.contentWindow?.postMessage(message, this.origin);
    } catch {
      // The iframe may have navigated away; the host can reopen the call.
    }
  }

  private flushQueue(): void {
    if (!this.frame || !this.origin) return;
    const queued = this.queue.splice(0, this.queue.length);
    for (const message of queued) {
      try {
        this.frame.contentWindow?.postMessage(message, this.origin);
      } catch {
        // Ignore per-message failures; the next state update will retry.
      }
    }
  }

  private startReadyTimeout(): void {
    if (typeof window === 'undefined') return;
    const origin = this.origin;
    const callId = this.callId;
    window.setTimeout(() => {
      if (this.origin !== origin || this.callId !== callId || this.ready) return;
      this.emitRaw({
        type: 'agil:event',
        event: 'error',
        payload: { code: 'timeout', message: 'The call widget did not signal ready within 20000 ms' },
      });
    }, 20_000);
  }

  private handleMessage(event: MessageEvent): void {
    if (!this.frame || event.source !== this.frame.contentWindow) return;
    if (!this.origin || event.origin !== this.origin) return;
    const parsed = parseWidgetMessage(event.data);
    if (!parsed) return;
    if (!this.ready) {
      this.ready = true;
      this.flushQueue();
    }
    const raw = typeof event.data === 'string' ? event.data : JSON.stringify(event.data);
    this.emitRawString(raw);
  }

  private emitRaw(payload: Record<string, unknown>): void {
    this.emitRawString(JSON.stringify(payload));
  }

  private emitRawString(raw: string): void {
    void this.notifyListeners('callMessage', { raw });
  }
}
