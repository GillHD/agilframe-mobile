/**
 * Pure render-time helpers for `<AgilCall />`.
 *
 * These functions deliberately avoid React/React Native imports so they can be
 * unit-tested on a plain Node VM. They also never use the global `URL` class:
 * React Native ships a partial polyfill whose `origin` getter throws
 * `Error: URL.origin is not implemented`, and computing the shim origin during
 * render used to crash the whole component on a clean RN app.
 */
import type { AgilCallError } from './core-types.js';
import { parseAbsoluteUrl } from './url-core.js';
import { AgilConfigError, buildWidgetUrl } from './url.js';
import type { AgilWidgetUrlOptions } from './url.js';

export interface AgilCallRenderState {
  /** Widget URL, or `null` when the configuration is invalid. */
  url: string | null;
  /** Fatal configuration error to render instead of the WebView. */
  error: AgilCallError | null;
  /** Canonical widget origin used by the injected bridge shim. */
  origin: string | null;
}

/** Extracts the exact origin of a widget URL without the RN global `URL`. */
export function widgetOrigin(url: string | null | undefined): string | null {
  if (typeof url !== 'string' || !url) return null;
  return parseAbsoluteUrl(url)?.origin ?? null;
}

/**
 * Builds the URL/error/shim-origin triple that `<AgilCall />` needs during
 * render. Never throws: invalid configuration becomes a fatal `invalid-config`
 * error, matching the component's fallback UI.
 */
export function buildAgilCallRenderState(options: AgilWidgetUrlOptions): AgilCallRenderState {
  try {
    const url = buildWidgetUrl(options);
    const origin = widgetOrigin(url);
    if (!origin) {
      return {
        url: null,
        error: {
          code: 'invalid-config',
          message: 'The widget URL could not be parsed',
          fatal: true,
        },
        origin: null,
      };
    }
    return { url, error: null, origin };
  } catch (error) {
    const configError =
      error instanceof AgilConfigError
        ? error
        : new AgilConfigError('Invalid AgilCall configuration');
    return {
      url: null,
      error: {
        code: 'invalid-config',
        message: configError.message,
        fatal: true,
        ...(configError.field ? { details: { field: configError.field } } : {}),
      },
      origin: null,
    };
  }
}
