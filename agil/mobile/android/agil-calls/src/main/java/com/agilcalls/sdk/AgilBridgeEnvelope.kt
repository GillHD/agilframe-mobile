package com.agilcalls.sdk

import org.json.JSONObject
import java.security.SecureRandom

/**
 * Per-load nonce envelope for the JavaScript bridge.
 *
 * Android's `addJavascriptInterface` exposes the bridge object to **every frame**
 * of the WebView, and the native side can only inspect the top-level committed
 * URL. The injected shim therefore wraps each forwarded widget message in an
 * envelope carrying a secret that only the widget-origin top-frame closure
 * knows:
 *
 * ```json
 * {"__agilBridgeNonce":"<nonce>","message":"{\"type\":\"agil:ready\",...}"}
 * ```
 *
 * [AgilCallView] rejects anything that does not carry the current nonce, so a
 * subframe (or any page that is not the configured widget origin) cannot forge
 * `agil:ready`/`agil:event`/`agil:chat`/`agil:state`. This matches the
 * Capacitor and React Native shims and compensates for the fact that
 * `addJavascriptInterface` has no frame information.
 *
 * Pure `org.json`/`SecureRandom` (no Android framework) so the contract is
 * covered by plain JVM JUnit tests.
 */
internal object AgilBridgeEnvelope {
    /** Envelope key written by the shim and verified by the native bridge. */
    const val NONCE_FIELD: String = "__agilBridgeNonce"

    /** Inner payload key. */
    const val MESSAGE_FIELD: String = "message"

    /** Same upper bound as the message parser plus envelope/nonce overhead. */
    const val MAX_CHARS: Int = 262_144 + 1_024

    private const val NONCE_BYTES = 32
    private val HEX = "0123456789abcdef".toCharArray()

    /** 256-bit URL-safe hex nonce from a cryptographically strong RNG. */
    fun newNonce(): String {
        val random = SecureRandom()
        val bytes = ByteArray(NONCE_BYTES)
        random.nextBytes(bytes)
        val out = CharArray(bytes.size * 2)
        for (index in bytes.indices) {
            val value = bytes[index].toInt() and 0xFF
            out[index * 2] = HEX[value ushr 4]
            out[index * 2 + 1] = HEX[value and 0x0F]
        }
        return String(out)
    }

    /** Wraps [message] with the nonce; used by tests and by the JS contract. */
    fun wrap(message: String, nonce: String): String = JSONObject()
        .put(NONCE_FIELD, nonce)
        .put(MESSAGE_FIELD, message)
        .toString()

    /**
     * Returns the inner widget payload when [raw] is a valid envelope for
     * [nonce]; `null` for malformed JSON, an empty nonce (bridge not armed), a
     * missing/mismatched nonce or a non-string `message`.
     */
    fun unwrap(raw: String?, nonce: String): String? {
        if (raw.isNullOrEmpty() || raw.length > MAX_CHARS) return null
        if (nonce.isEmpty()) return null
        val envelope = try {
            JSONObject(raw)
        } catch (_: Exception) {
            return null
        }
        val envelopeNonce = envelope.opt(NONCE_FIELD) as? String ?: return null
        if (envelopeNonce != nonce) return null
        val message = envelope.opt(MESSAGE_FIELD) as? String ?: return null
        if (message.isEmpty() || message.length > MAX_CHARS) return null
        return message
    }
}
