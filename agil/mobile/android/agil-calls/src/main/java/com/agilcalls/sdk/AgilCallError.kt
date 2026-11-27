package com.agilcalls.sdk

/**
 * Typed errors surfaced through [AgilCallEvent.Error].
 *
 * [message] is always token-free and safe to display. [fatal] means the call
 * cannot continue without a host action (fix configuration, grant a permission
 * or recreate the screen after a renderer crash).
 */
sealed class AgilCallError {
    /** Stable machine-readable code for analytics. */
    abstract val code: String

    /** Human-readable, token-free message. */
    abstract val message: String

    /** Whether the call cannot continue without host action. */
    open val fatal: Boolean = false

    /** Invalid [AgilCallConfig]; nothing was loaded. */
    data class InvalidConfig(
        val field: String?,
        override val message: String,
    ) : AgilCallError() {
        override val code: String = "invalid-config"
        override val fatal: Boolean = true
    }

    /** The page failed to load (network, TLS, renderer). */
    data class LoadFailed(
        override val message: String,
    ) : AgilCallError() {
        override val code: String = "load-failed"
        override val fatal: Boolean = true
    }

    /** The page returned a non-2xx HTTP status. */
    data class Http(
        val status: Int,
        override val message: String,
    ) : AgilCallError() {
        override val code: String = "http-error"
        override val fatal: Boolean = true
    }

    /** The WebView tried to leave the configured server/allowlist. */
    data class NavigationBlocked(
        val redactedUrl: String,
    ) : AgilCallError() {
        override val code: String = "navigation-blocked"
        override val message: String = "Blocked navigation to $redactedUrl"
    }

    /** Camera/microphone access was denied by the user or the OS. */
    data class PermissionDenied(
        val resources: List<String>,
    ) : AgilCallError() {
        override val code: String = "permission-denied"
        override val message: String =
            "Camera/microphone permission denied (${resources.joinToString(", ")})"
    }

    /** The JavaScript bridge is unavailable, full, or a command failed. */
    data class Bridge(
        override val message: String,
    ) : AgilCallError() {
        override val code: String = "bridge-error"
    }

    /** The widget did not finish the handshake in time. */
    data class Timeout(
        override val message: String,
    ) : AgilCallError() {
        override val code: String = "bridge-timeout"
        override val fatal: Boolean = true
    }

    /** The WebView renderer crashed; recreate the view. */
    data class RenderProcessGone(
        override val message: String = "The WebView renderer process exited",
    ) : AgilCallError() {
        override val code: String = "render-process-gone"
        override val fatal: Boolean = true
    }

    /** The widget reported an error through `agil:event {event:'error'}`. */
    data class Widget(
        val widgetCode: String?,
        override val message: String,
        override val fatal: Boolean = false,
    ) : AgilCallError() {
        override val code: String = "widget-error"
    }

    /** A widget command was denied (`agil:event {event:'action-denied'}`). */
    data class ActionDenied(
        val action: String?,
        val reason: String?,
    ) : AgilCallError() {
        override val code: String = "action-denied"
        override val message: String = "The widget denied the \"${action ?: "unknown"}\" action" +
            if (reason.isNullOrBlank()) "" else " ($reason)"
    }
}
