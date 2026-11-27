package com.agilcalls.sdk

/** Capability flags reported by the widget in `agil:ready`. */
data class AgilCapabilities(
    val media: Boolean = false,
    val blur: Boolean = false,
    val screenShare: Boolean = false,
    val captions: Boolean = false,
    val recording: Boolean = false,
)

/** One chat message from `agil:chat`. */
data class AgilChatMessage(
    val text: String,
    val id: String? = null,
    val participantId: String? = null,
    val participantName: String? = null,
    val timestamp: Long? = null,
) {
    init {
        require(text.isNotEmpty()) { "chat text must not be empty" }
    }

    /** Token-redacted and truncated; chat text is user content. */
    override fun toString(): String {
        val safeText = AgilTokenRedactor.redactText(text)
        val preview = if (safeText.length > 80) safeText.substring(0, 80) + "…" else safeText
        return "AgilChatMessage(id=$id, participantId=$participantId, " +
            "participantName=$participantName, text=$preview)"
    }
}

/**
 * Periodic snapshot posted by the widget as `agil:state`.
 *
 * Only documented fields are typed; the full payload is not exposed to keep the
 * public API stable and safe.
 */
data class AgilCallSnapshot(
    val phase: String? = null,
    val participants: Int? = null,
    val participantIds: List<String> = emptyList(),
    val qualityTier: String? = null,
    val qualityScore: Double? = null,
    val connectionState: String? = null,
    val recording: Boolean = false,
    val minimized: Boolean = false,
    val chatMode: String? = null,
    val fullscreen: Boolean = false,
    val micEnabled: Boolean? = null,
    val cameraEnabled: Boolean? = null,
    val screenSharing: Boolean? = null,
    val blurMode: String? = null,
    val panel: String? = null,
    /** Authoritative count from the large-room digest, when this compact state has one. */
    val participantCount: Int? = null,
    /** Monotonic revision of the participant digest, when this compact state has one. */
    val participantRevision: Int? = null,
    /**
     * True when this snapshot carries the widget's `participantIds` (an empty
     * array is a valid snapshot for an empty room; absent means count-only).
     * Compact states always report false because they drop the id list.
     */
    val hasParticipantIds: Boolean = false,
)

/**
 * Events delivered to [AgilCallEventListener].
 *
 * ```kotlin
 * callView.listener = AgilCallEventListener { event ->
 *     when (event) {
 *         is AgilCallEvent.Ready -> renderCapabilities(event.capabilities)
 *         is AgilCallEvent.Joined -> Unit
 *         is AgilCallEvent.Left -> Unit
 *         is AgilCallEvent.Chat -> render(event.message)
 *         is AgilCallEvent.State -> render(event.snapshot)
 *         is AgilCallEvent.Error -> showError(event.error)
 *         else -> Unit
 *     }
 * }
 * ```
 *
 * Events are delivered on the main thread.
 */
sealed class AgilCallEvent {
    /** Widget mounted and the bridge is alive (`agil:ready`). */
    data class Ready(
        val capabilities: AgilCapabilities,
        val room: String? = null,
    ) : AgilCallEvent()

    /** Participant joined the room (`agil:event {event:'joined'}`). */
    data class Joined(
        val participantCount: Int? = null,
    ) : AgilCallEvent()

    /** Participant left the room (`agil:event {event:'left'}`). */
    data class Left(
        val reason: String? = null,
    ) : AgilCallEvent()

    /** New chat message (`agil:chat`). */
    data class Chat(
        val message: AgilChatMessage,
    ) : AgilCallEvent()

    /** Call state snapshot (`agil:state`). */
    data class State(
        val snapshot: AgilCallSnapshot,
    ) : AgilCallEvent()

    /** Compact participant snapshot/delta (Stage 3b; never the 200-id array per tick). */
    data class Participants(
        val update: AgilParticipantUpdate,
    ) : AgilCallEvent()

    /** Deduplicated connection/reconnect transition. */
    data class Connection(
        val update: AgilConnectionUpdate,
    ) : AgilCallEvent()

    /** Any error (configuration, load, bridge, widget, permissions). */
    data class Error(
        val error: AgilCallError,
    ) : AgilCallEvent()

    /** Any other `agil:event` (`participant-joined`, `quality-changed`, …). */
    data class Generic(
        val name: String,
        val payloadJson: String? = null,
    ) : AgilCallEvent() {
        override fun toString(): String {
            val safe = payloadJson?.let { AgilTokenRedactor.redactText(it) }
            val preview = if (safe != null && safe.length > 200) safe.substring(0, 200) + "…" else safe
            return "AgilCallEvent.Generic(name=$name, payload=$preview)"
        }
    }
}

/** Receives every call event on the main thread. */
fun interface AgilCallEventListener {
    fun onEvent(event: AgilCallEvent)
}
