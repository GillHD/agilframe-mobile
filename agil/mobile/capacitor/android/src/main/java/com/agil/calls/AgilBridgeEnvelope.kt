package com.agil.calls

import org.json.JSONObject

/**
 * Nonce envelope written by the Android bridge shim.
 *
 * `AgilBridge` is exposed to every frame, so the shim wraps each forwarded
 * widget message and passes the per-load nonce as a second argument:
 *
 * ```json
 * {"__agilBridgeNonce":"<nonce>","message":"{\"type\":\"agil:ready\",...}"}
 * ```
 *
 * [AgilCallActivity.BridgeInterface] validates the nonce and must forward the
 * **inner** `message` string to JS: `parseWidgetMessage()` in `src/bridge.ts`
 * expects a widget object and returns `null` for the envelope (no `type`).
 *
 * Pure org.json parsing (no Android framework) so the contract is easy to
 * review; the JS side has a matching `unwrapBridgeEnvelope()` regression test.
 */
internal object AgilBridgeEnvelope {
    /** Same upper bound as the JS parser (262 144 chars) plus envelope overhead. */
    const val MAX_CHARS: Int = 262_144 + 1_024

    /**
     * Returns the inner widget payload when [raw] is a valid nonce envelope for
     * [nonce]; `null` for malformed JSON, a missing/mismatched nonce or a
     * non-string `message`.
     */
    fun unwrap(raw: String?, nonce: String): String? {
        if (raw.isNullOrEmpty() || raw.length > MAX_CHARS) return null
        if (nonce.isEmpty()) return null
        val envelope = try {
            JSONObject(raw)
        } catch (_: Exception) {
            return null
        }
        val envelopeNonce = envelope.opt("__agilBridgeNonce") as? String ?: return null
        if (envelopeNonce != nonce) return null
        return envelope.opt("message") as? String
    }
}
