package com.agil.calls

import org.json.JSONObject

/**
 * Process-wide plumbing between [AgilCallsPlugin] and [AgilCallActivity].
 *
 * The plugin and the Activity are separate components; Capacitor plugin
 * instances do not survive an Activity launch, so the Activity publishes its
 * bridge callbacks here.
 */
internal object AgilCallBridge {
    var messageListener: ((String) -> Unit)? = null
    var themeApplier: ((String?, JSONObject?) -> Unit)? = null
    var closer: (() -> Unit)? = null

    private var actionSender: ((String) -> Boolean)? = null
    private var chatSender: ((String) -> Boolean)? = null
    /** Commands sent before the widget page is live, in call order. */
    private val pendingCommands = ArrayDeque<Pair<String, String>>()
    private var pendingAllowed = false
    /** Set by the Activity when the widget page proved it is live. */
    private var pageReady = false
    private const val MAX_PENDING = 20

    /** Called by the plugin before the Activity is created. */
    fun beginCall() {
        pendingAllowed = true
        pageReady = false
        pendingCommands.clear()
    }

    fun emit(raw: String) {
        messageListener?.invoke(raw)
    }

    /**
     * Marks the widget page live and delivers every queued command in order.
     * Called on `agil:ready` (or the first accepted `agil:*` message).
     */
    fun markPageReady() {
        pageReady = true
        flushPending()
    }

    /** A reload starts a new document: queue commands again until it is live. */
    fun resetPageReady() {
        pageReady = false
    }

    fun applyTheme(scheme: String?, theme: JSONObject?) {
        themeApplier?.invoke(scheme, theme)
    }

    /**
     * Commands can arrive right after `openCall()` (the Activity/page are
     * created asynchronously) and before the widget posts `agil:ready`. Queue
     * them, preserving order, instead of posting into an empty WebView where
     * they would be lost. The queue is bounded; over-limit commands are
     * rejected so the caller sees a failure instead of silent loss.
     */
    fun sendAction(action: String): Boolean = enqueueOrSend("action", action)

    fun sendChat(text: String): Boolean = enqueueOrSend("chat", text)

    private fun enqueueOrSend(kind: String, value: String): Boolean {
        if (pageReady) {
            val sender = senderFor(kind) ?: return false
            return sender(value)
        }
        if (!pendingAllowed || pendingCommands.size >= MAX_PENDING) return false
        pendingCommands.addLast(kind to value)
        return true
    }

    private fun senderFor(kind: String): ((String) -> Boolean)? =
        if (kind == "action") actionSender else chatSender

    private fun flushPending() {
        if (!pageReady) return
        while (pendingCommands.isNotEmpty()) {
            val (kind, value) = pendingCommands.removeFirst()
            val sender = senderFor(kind) ?: continue
            sender(value)
        }
    }

    fun setActionSender(sender: ((String) -> Boolean)?) {
        actionSender = sender
        if (sender == null) {
            pendingAllowed = false
            return
        }
        if (pageReady) flushPending()
    }

    fun setChatSender(sender: ((String) -> Boolean)?) {
        chatSender = sender
        if (sender == null) {
            pendingAllowed = false
            return
        }
        if (pageReady) flushPending()
    }

    fun close() {
        closer?.invoke()
    }
}
