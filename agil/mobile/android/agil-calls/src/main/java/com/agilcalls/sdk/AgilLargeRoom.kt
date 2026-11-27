package com.agilcalls.sdk

/**
 * Stage 3b large-room support.
 *
 * The widget's periodic `agil:state` snapshot carries the full
 * `participantIds` array. With 200 participants that is ~2 KB of JSON on every
 * change. [AgilParticipantDigest] keeps the canonical set natively and exposes
 * one bounded snapshot per load plus deltas, so the host never receives the
 * whole array on every tick. [AgilConnectionDigest] deduplicates the widget's
 * reconnect state.
 *
 * The same algorithm exists in the iOS/React Native/embed SDKs; keep the event
 * shapes and the 200-participant profile in sync
 * (`agil/core/docs/webview-large-rooms.md`).
 */
object AgilLargeRoom {
    /** Stage 3b profile: one room up to 200 participants. */
    const val MAX_PARTICIPANTS: Int = 200

    /** Minimum churn (ids added + removed) before a resync snapshot. */
    const val RESYNC_MIN: Int = 32

    /** Minimum fraction of the room that must change before a resync snapshot. */
    const val RESYNC_RATIO: Double = 0.5
}

enum class AgilParticipantUpdateKind {
    SNAPSHOT,
    DELTA,
    SUMMARY,
}

/**
 * One compact participant update delivered to the host.
 *
 * [ids] is non-null only for [AgilParticipantUpdateKind.SNAPSHOT], and is capped
 * at [AgilLargeRoom.MAX_PARTICIPANTS].
 */
data class AgilParticipantUpdate(
    val kind: AgilParticipantUpdateKind,
    val count: Int,
    val revision: Int,
    val added: List<String> = emptyList(),
    val removed: List<String> = emptyList(),
    val ids: List<String>? = null,
    val truncated: Boolean = false,
) {
    init {
        require(count >= 0) { "participant count must be >= 0" }
        require(revision >= 1) { "participant revision must be >= 1" }
    }
}

/**
 * Stateful participant digest; use one instance per page load and call [reset]
 * when a new document starts.
 */
class AgilParticipantDigest(
    maxParticipants: Int = AgilLargeRoom.MAX_PARTICIPANTS,
    private val resyncMin: Int = AgilLargeRoom.RESYNC_MIN,
    private val resyncRatio: Double = AgilLargeRoom.RESYNC_RATIO,
) {
    val maxParticipants: Int = maxParticipants.coerceIn(2, AgilLargeRoom.MAX_PARTICIPANTS)
    private val resyncThreshold: Int = resyncMin.coerceAtLeast(1)
    private val resyncFraction: Double = resyncRatio.coerceIn(0.0, 1.0)

    private val orderedIds = ArrayList<String>()
    private val idSet = HashSet<String>()
    private var currentCount = 0
    private var currentRevision = 0
    private var initialized = false

    val participantCount: Int get() = currentCount
    val revision: Int get() = currentRevision
    val ids: List<String> get() = orderedIds.toList()

    fun reset() {
        orderedIds.clear()
        idSet.clear()
        currentCount = 0
        currentRevision = 0
        initialized = false
    }

    /**
     * Applies one widget snapshot. Returns `null` when nothing meaningful
     * changed, which keeps the native channel quiet on unchanged ticks.
     */
    fun apply(participantIds: List<String>?, count: Int?): AgilParticipantUpdate? {
        if (participantIds == null) {
            val explicit = count?.takeIf { it >= 0 } ?: return null
            if (initialized && explicit == currentCount) return null
            initialized = true
            currentCount = explicit
            currentRevision += 1
            return AgilParticipantUpdate(
                kind = AgilParticipantUpdateKind.SUMMARY,
                count = explicit,
                revision = currentRevision,
            )
        }

        val nextOrdered = ArrayList<String>(minOf(participantIds.size, maxParticipants))
        val nextSet = HashSet<String>()
        var truncated = false
        for (raw in participantIds) {
            if (nextOrdered.size >= maxParticipants) {
                truncated = true
                break
            }
            val id = normalizeId(raw) ?: continue
            if (nextSet.add(id)) nextOrdered.add(id)
        }
        val nextCount = count ?: nextOrdered.size

        if (!initialized) {
            initialized = true
            currentCount = nextCount
            currentRevision = 1
            replace(nextOrdered, nextSet)
            return AgilParticipantUpdate(
                kind = AgilParticipantUpdateKind.SNAPSHOT,
                count = nextCount,
                revision = currentRevision,
                added = nextOrdered.toList(),
                ids = nextOrdered.toList(),
                truncated = truncated,
            )
        }

        val added = nextOrdered.filterNot { idSet.contains(it) }
        val removed = orderedIds.filterNot { nextSet.contains(it) }
        if (added.isEmpty() && removed.isEmpty() && nextCount == currentCount && !truncated) {
            return null
        }

        val changed = added.size + removed.size
        val baseline = maxOf(orderedIds.size, nextOrdered.size, 1)
        val resync = changed >= resyncThreshold && changed.toDouble() / baseline >= resyncFraction

        currentCount = nextCount
        currentRevision += 1
        replace(nextOrdered, nextSet)

        if (resync) {
            return AgilParticipantUpdate(
                kind = AgilParticipantUpdateKind.SNAPSHOT,
                count = nextCount,
                revision = currentRevision,
                added = nextOrdered.toList(),
                ids = nextOrdered.toList(),
                truncated = truncated,
            )
        }
        return AgilParticipantUpdate(
            kind = AgilParticipantUpdateKind.DELTA,
            count = nextCount,
            revision = currentRevision,
            added = added,
            removed = removed,
            truncated = truncated,
        )
    }

    private fun replace(nextOrdered: List<String>, nextSet: Set<String>) {
        orderedIds.clear()
        orderedIds.addAll(nextOrdered)
        idSet.clear()
        idSet.addAll(nextSet)
    }

    private fun normalizeId(value: String): String? {
        val trimmed = value.trim()
        if (trimmed.isEmpty() || trimmed.length > 200) return null
        for (character in trimmed) {
            if (character.code < 0x20 || character.code == 0x7f) return null
        }
        return trimmed
    }
}

/**
 * Applies the shared compact-state convention to one widget snapshot.
 *
 * The compact state never carries ids, even for the single snapshot: hosts read
 * the bounded set from [AgilCallEvent.Participants]. The authoritative count and
 * digest revision travel as `participantCount` / `participantRevision`, matching
 * the JS `compactCallState` contract.
 */
fun AgilCallSnapshot.compactForParticipantUpdate(update: AgilParticipantUpdate?): AgilCallSnapshot =
    copy(
        participantIds = emptyList(),
        participantCount = update?.count,
        participantRevision = update?.revision,
        hasParticipantIds = false,
    )

enum class AgilConnectionState(val wire: String) {
    IDLE("idle"),
    CONNECTING("connecting"),
    CONNECTED("connected"),
    RECONNECTING("reconnecting"),
    DISCONNECTED("disconnected"),
    OFFLINE("offline"),
    CLOSED("closed"),
    FAILED("failed"),
    UNKNOWN("unknown"),
    ;

    companion object {
        @JvmStatic
        fun fromWire(value: String?): AgilConnectionState? {
            if (value == null) return null
            return when (value.trim().lowercase(java.util.Locale.ROOT)) {
                "" -> null
                "idle" -> IDLE
                "connecting", "new" -> CONNECTING
                "connected", "open" -> CONNECTED
                "reconnecting", "reconnect" -> RECONNECTING
                "disconnected" -> DISCONNECTED
                "offline" -> OFFLINE
                "closed" -> CLOSED
                "failed" -> FAILED
                else -> UNKNOWN
            }
        }
    }
}

/** Deduplicated connection/reconnect transition delivered to the host. */
data class AgilConnectionUpdate(
    val state: AgilConnectionState,
    val previous: AgilConnectionState? = null,
    val reconnecting: Boolean = state == AgilConnectionState.RECONNECTING,
    val attempt: Int? = null,
    val delayMs: Int? = null,
)

class AgilConnectionDigest {
    private var state: AgilConnectionState? = null
    private var attempt: Int? = null
    private var delayMs: Int? = null

    val currentState: AgilConnectionState? get() = state

    fun reset() {
        state = null
        attempt = null
        delayMs = null
    }

    fun apply(rawState: String?, rawAttempt: Int?, rawDelayMs: Int?): AgilConnectionUpdate? {
        val next = AgilConnectionState.fromWire(rawState) ?: return null
        val nextAttempt = rawAttempt?.takeIf { it >= 0 }
        val nextDelay = rawDelayMs?.takeIf { it >= 0 }
        if (next == state && nextAttempt == attempt && nextDelay == delayMs) return null
        val previous = state
        state = next
        attempt = nextAttempt
        delayMs = nextDelay
        return AgilConnectionUpdate(
            state = next,
            previous = previous,
            attempt = nextAttempt,
            delayMs = nextDelay,
        )
    }
}
