package com.agilcalls.sdk

import org.json.JSONArray
import org.json.JSONObject

/**
 * Parses messages produced by [AgilBridgeScript] inside the hosted widget.
 *
 * Everything here is defensive: unknown types, oversized strings and malformed
 * JSON are ignored rather than trusted. Parsing happens on the main thread
 * after the JavaScript interface has checked the top-level page origin.
 */
internal object AgilBridgeProtocol {
    /** Name of the injected native object (`window.AgilCallsBridge`). */
    const val INTERFACE_NAME: String = "AgilCallsBridge"

    /** Hard limit for one message (characters, before JSON parsing). */
    const val MAX_MESSAGE_CHARS: Int = 262_144

    /** Host → widget command queue limit before `agil:ready`. */
    const val MAX_QUEUED_COMMANDS: Int = 50

    /** Maximum chat message length accepted by `agil:chat-send`. */
    const val MAX_CHAT_CHARS: Int = 4000

    /** Maximum reaction length accepted by `agil:action reaction` (widget cap). */
    const val MAX_REACTION_CHARS: Int = 16

    private const val MAX_EVENT_PAYLOAD_CHARS = 32_768
    private const val MAX_EVENT_NAME = 64
    private const val MAX_ROOM = 200
    private const val MAX_ID = 128
    private const val MAX_TEXT = 64
    private const val MAX_CHAT_TEXT = 8_000
    private const val MAX_PARTICIPANTS = 500
    // Parse with headroom above the 200-participant profile so the native
    // digest can report `truncated` instead of silently losing half a room.
    private const val MAX_PARTICIPANT_IDS = 500

    private val EVENT_NAME = Regex("^[a-z][a-z0-9-]{0,63}$")

    sealed class Message {
        /** Our own shim installed the listener; transport is alive. */
        object Shim : Message()

        object Pong : Message()

        data class Ready(
            val capabilities: AgilCapabilities,
            val room: String?,
        ) : Message()

        data class Chat(
            val message: AgilChatMessage,
        ) : Message()

        data class State(
            val snapshot: AgilCallSnapshot,
        ) : Message()

        data class Event(
            val name: String,
            val payload: JSONObject?,
            val payloadJson: String?,
        ) : Message()
    }

    fun parse(raw: String): Message? {
        if (raw.isEmpty() || raw.length > MAX_MESSAGE_CHARS) return null
        val json = try {
            JSONObject(raw)
        } catch (_: Exception) {
            return null
        }
        return when (json.optString("type", "")) {
            "agil:android-shim" -> Message.Shim
            "agil:ready" -> Message.Ready(
                capabilities = capabilities(json.optJSONObject("capabilities")),
                room = string(json, "room", MAX_ROOM),
            )
            "agil:pong" -> Message.Pong
            "agil:chat" -> parseChat(json.opt("message"))?.let { Message.Chat(it) }
            "agil:state" -> parseState(json.optJSONObject("state"))?.let { Message.State(it) }
            "agil:event" -> parseEvent(json)
            "agil:minimized" -> genericEvent("minimized", json.opt("minimized"))
            "agil:fullscreen" -> genericEvent("fullscreen", json.opt("fullscreen"))
            else -> null
        }
    }

    private fun parseChat(value: Any?): AgilChatMessage? {
        if (value is String) {
            val text = value.take(MAX_CHAT_TEXT)
            if (text.isBlank()) return null
            return AgilChatMessage(text = text)
        }
        val objectValue = value as? JSONObject ?: return null
        val text = string(objectValue, "text", MAX_CHAT_TEXT)?.takeIf { it.isNotBlank() } ?: return null
        val timestamp = when (val rawTs = objectValue.opt("ts")) {
            is Number -> rawTs.toLong()
            else -> null
        }
        return AgilChatMessage(
            text = text,
            id = string(objectValue, "id", MAX_ID),
            participantId = string(objectValue, "participantId", MAX_ID),
            participantName = string(objectValue, "participantName", MAX_ID),
            timestamp = timestamp,
        )
    }

    private fun parseState(state: JSONObject?): AgilCallSnapshot? {
        if (state == null) return null
        val quality = state.optJSONObject("quality")
        val settings = state.optJSONObject("settings")
        val participants = if (state.has("participants") && !state.isNull("participants")) {
            state.optInt("participants", 0)
        } else {
            null
        }
        val participantIdsArray = state.optJSONArray("participantIds")
        val hasParticipantIds = participantIdsArray != null
        val ids = participantIdsArray?.let { array ->
            val limit = if (array.length() > MAX_PARTICIPANT_IDS) MAX_PARTICIPANT_IDS else array.length()
            val result = ArrayList<String>(limit)
            for (index in 0 until limit) {
                val value = array.optString(index, "")
                if (value.isNotBlank()) result.add(value.take(MAX_ID))
            }
            result
        }.orEmpty()
        val score = quality?.let { value ->
            if (value.has("score") && !value.isNull("score")) value.optDouble("score", 0.0) else null
        }
        return AgilCallSnapshot(
            phase = string(state, "phase", MAX_TEXT),
            participants = participants?.coerceIn(0, MAX_PARTICIPANTS),
            participantIds = ids,
            qualityTier = quality?.let { string(it, "tier", MAX_TEXT) },
            qualityScore = score,
            connectionState = string(state, "connectionState", MAX_TEXT),
            recording = state.optBoolean("recording", false),
            minimized = state.optBoolean("minimized", false),
            chatMode = string(state, "chatMode", MAX_TEXT),
            fullscreen = state.optBoolean("fullscreen", false),
            micEnabled = settings?.let { booleanOrNull(it, "mic") },
            cameraEnabled = settings?.let { booleanOrNull(it, "camera") },
            screenSharing = settings?.let { booleanOrNull(it, "screen") },
            blurMode = settings?.let { string(it, "blur", MAX_TEXT) },
            panel = settings?.let { string(it, "panel", MAX_TEXT) },
            hasParticipantIds = hasParticipantIds,
        )
    }

    private fun parseEvent(json: JSONObject): Message? {
        val name = string(json, "event", MAX_EVENT_NAME)?.lowercase(java.util.Locale.ROOT) ?: return null
        if (!EVENT_NAME.matches(name)) return null
        val payload = json.optJSONObject("payload")
        return genericEvent(name, payload)
    }

    private fun genericEvent(name: String, payload: Any?): Message.Event {
        val objectValue = payload as? JSONObject
        val payloadJson = when (payload) {
            null -> null
            is JSONObject, is JSONArray -> payload.toString().let {
                if (it.length > MAX_EVENT_PAYLOAD_CHARS) it.substring(0, MAX_EVENT_PAYLOAD_CHARS) else it
            }
            else -> payload.toString().let {
                if (it.length > MAX_EVENT_PAYLOAD_CHARS) it.substring(0, MAX_EVENT_PAYLOAD_CHARS) else it
            }
        }
        return Message.Event(name, objectValue, payloadJson)
    }

    private fun capabilities(value: JSONObject?): AgilCapabilities {
        if (value == null) return AgilCapabilities()
        return AgilCapabilities(
            media = value.optBoolean("media", false),
            blur = value.optBoolean("blur", false),
            screenShare = value.optBoolean("screenShare", false),
            captions = value.optBoolean("captions", false),
            recording = value.optBoolean("recording", false),
        )
    }

    private fun booleanOrNull(json: JSONObject, key: String): Boolean? {
        if (!json.has(key) || json.isNull(key)) return null
        return json.optBoolean(key, false)
    }

    private fun string(json: JSONObject, key: String, max: Int): String? {
        if (!json.has(key) || json.isNull(key)) return null
        val value = json.optString(key, "")
        if (value.isBlank()) return null
        return if (value.length > max) value.substring(0, max) else value
    }
}

/**
 * JavaScript injected into the hosted page.
 *
 * `embed.html` posts to `window.parent` with `targetOrigin:'*'`. In a top-level
 * WebView `window.parent === window`, so those messages are same-window
 * `message` events: the shim listens for them and forwards the documented
 * `agil:*` widget types to [AgilBridgeProtocol.INTERFACE_NAME]. It never
 * forwards host commands back (they are filtered out), and it refuses to run on
 * a page whose origin is not the configured server origin or outside the top
 * frame.
 *
 * Every forwarded message is wrapped in the [AgilBridgeEnvelope] with the
 * per-load [nonce]. The native interface is visible to **all** frames, so the
 * nonce — present only in this widget-origin top-frame closure — is what binds
 * a message to the widget frame and prevents subframe spoofing.
 */
internal object AgilBridgeScript {
    fun shim(origin: String, nonce: String): String {
        val quotedOrigin = JSONObject.quote(origin)
        val quotedNonce = JSONObject.quote(nonce)
        val quotedNonceField = JSONObject.quote(AgilBridgeEnvelope.NONCE_FIELD)
        val quotedMessageField = JSONObject.quote(AgilBridgeEnvelope.MESSAGE_FIELD)
        return """
            (function() {
              try {
                var w = window;
                if (!w || w.__agilAndroidBridgeInstalled) return;
                if (w.top !== w) return;
                var channel = w.AgilCallsBridge;
                if (!channel || typeof channel.postMessage !== 'function') return;
                if (w.location.origin !== $quotedOrigin) return;
                var nonce = $quotedNonce;
                if (typeof nonce !== 'string' || !nonce) return;
                var forward = function(data) {
                  try {
                    channel.postMessage(JSON.stringify(
                      { $quotedNonceField: nonce, $quotedMessageField: JSON.stringify(data) }
                    ));
                  } catch (e) {}
                };
                w.__agilAndroidBridgeInstalled = true;
                w.addEventListener('message', function(event) {
                  try {
                    if (event.source !== w) return;
                    var data = event.data;
                    if (!data || typeof data !== 'object') return;
                    var type = data.type;
                    if (typeof type !== 'string') return;
                    switch (type) {
                      case 'agil:ready':
                      case 'agil:event':
                      case 'agil:chat':
                      case 'agil:state':
                      case 'agil:pong':
                      case 'agil:minimized':
                      case 'agil:fullscreen':
                        forward(data);
                        break;
                      default:
                        break;
                    }
                  } catch (e) {}
                }, false);
                forward({type: 'agil:android-shim'});
              } catch (e) {}
            })();
        """.trimIndent()
    }

    /** Delivers a host command to the page's own `message` listener. */
    fun postMessage(json: String): String {
        val safe = escapeForJavaScript(json)
        return "(function(){try{window.postMessage($safe,window.location.origin);}catch(e){}})();"
    }

    /**
     * Escapes characters that are legal in JSON but historically problematic
     * inside a `<script>`/JavaScript source context. The JSON itself stays
     * valid because the escapes are inside string literals.
     */
    private fun escapeForJavaScript(json: String): String {
        val builder = StringBuilder(json.length + 16)
        for (character in json) {
            when (character) {
                '<' -> builder.append("\\u003c")
                '>' -> builder.append("\\u003e")
                '&' -> builder.append("\\u0026")
                '\u2028' -> builder.append("\\u2028")
                '\u2029' -> builder.append("\\u2029")
                else -> builder.append(character)
            }
        }
        return builder.toString()
    }
}
