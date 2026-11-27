package com.agilcalls.sdk

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.DocumentsContract
import android.util.AttributeSet
import android.view.View
import android.view.WindowInsets
import android.webkit.ConsoleMessage
import android.webkit.CookieManager
import android.webkit.GeolocationPermissions
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONObject
import java.util.ArrayDeque

/**
 * Tier-1 native screen for AgilFrame: a hardened [WebView] around the hosted
 * `/embed.html` widget.
 *
 * Media, chat, themes and participants stay in the hosted widget; this view
 * owns presentation, window insets, Android runtime media permissions, the
 * origin navigation guard and the `postMessage` bridge.
 *
 * ```kotlin
 * val call = AgilCallView(activity)
 * call.listener = AgilCallEventListener { event -> /* ready/joined/... */ }
 * call.externalLinkHandler = { url -> openInBrowser(url) }
 * call.load(AgilCallConfig(serverUrl = "https://calls.example.com", room = "team-sync"))
 * setContentView(call)
 * ```
 *
 * Public methods must be called on the main thread. The view never logs.
 */
@SuppressLint("SetJavaScriptEnabled", "AddJavascriptInterface")
class AgilCallView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : android.widget.FrameLayout(context, attrs, defStyleAttr) {

    /** Receives every call event on the main thread. */
    var listener: AgilCallEventListener? = null

    /**
     * Called for a main-frame navigation blocked by the origin guard, so the
     * host can open it in a browser. The URL is raw (it may contain a token);
     * never log it.
     */
    var externalLinkHandler: ((String) -> Unit)? = null

    /** Called when Android shows or closes a native WebView fullscreen surface. */
    var nativeFullscreenListener: ((Boolean) -> Unit)? = null

    /** Currently loaded configuration, or `null` after [unload]/[release]. */
    var config: AgilCallConfig? = null
        private set

    /** True after the widget signalled `agil:ready` (or a bridge handshake). */
    var isReady: Boolean = false
        private set

    /** True while the widget reports the local participant as joined. */
    var isJoined: Boolean = false
        private set

    private val mainHandler = Handler(Looper.getMainLooper())
    private val webView = WebView(context)
    private var serverOrigin: String? = null
    private var pendingUrl: String? = null
    private var origins: Set<String> = emptySet()
    private var widgetReady: Boolean = false
    private var timedOut: Boolean = false
    private var released: Boolean = false
    private var webViewDestroyed: Boolean = false
    private var lastLoadFailureReported: Boolean = false
    private var lastParticipantCount: Int? = null
    private var participantDigest = AgilParticipantDigest()
    private var connectionDigest = AgilConnectionDigest()
    private var customView: View? = null
    private var customViewCallback: WebChromeClient.CustomViewCallback? = null
    private var pendingPermission: PermissionRequest? = null
    private var pendingPermissionResources: Array<String> = emptyArray()
    private var pendingDocument: Pair<Int, ValueCallback<Array<Uri>>>? = null
    private var readyTimeoutRunnable: Runnable? = null
    private var pingRunnable: Runnable? = null

    /**
     * Per-load bridge secret: embedded only in the widget-origin top-frame shim
     * and required in every message the JavaScript interface receives. Android
     * exposes the interface to every frame, so the nonce — not the URL — binds a
     * message to the widget frame. Regenerated on every [load].
     *
     * Written on the main thread, read on the WebView JavaBridge thread, hence
     * `@Volatile`.
     */
    @Volatile
    private var bridgeNonce: String = ""
    private val commandQueue = ArrayDeque<String>()

    init {
        checkMainThread()
        setBackgroundColor(DEFAULT_BACKGROUND)
        webView.setBackgroundColor(DEFAULT_BACKGROUND)
        webView.layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        webView.overScrollMode = View.OVER_SCROLL_NEVER
        webView.isVerticalScrollBarEnabled = false
        webView.isHorizontalScrollBarEnabled = false
        webView.isNestedScrollingEnabled = true
        webView.isScrollbarFadingEnabled = true
        // The widget owns the participant-list scroll container; the outer
        // WebView must not zoom or bounce (viewport is `device-width`).
        webView.settings.setSupportZoom(false)
        configureSettings(autoplay = true)
        webView.webViewClient = AgilWebViewClient()
        webView.webChromeClient = AgilChromeClient()
        webView.addJavascriptInterface(JsBridge(), AgilBridgeProtocol.INTERFACE_NAME)
        addView(webView)
        isFocusable = true
        isFocusableInTouchMode = true
        requestApplyInsets()
    }

    // ---------------------------------------------------------------------
    // Public lifecycle and commands
    // ---------------------------------------------------------------------

    /**
     * Validates [config] and loads `/embed.html`.
     *
     * Configuration errors are delivered through [listener] as
     * `AgilCallEvent.Error(AgilCallError.InvalidConfig)`; the previous page is
     * left untouched. Calling this again reloads the screen.
     */
    fun load(config: AgilCallConfig) {
        checkMainThread()
        checkNotReleased()

        val newTarget = try {
            config.toTarget()
        } catch (error: AgilCallConfigException) {
            reportInvalidConfig(error)
            return
        }
        val newOrigins = try {
            val result = LinkedHashSet<String>()
            result.add(newTarget.origin)
            result.addAll(AgilCallUrl.parseAllowedOrigins(config.allowedOrigins, config.allowInsecure))
            result
        } catch (error: AgilCallConfigException) {
            reportInvalidConfig(error)
            return
        }

        exitNativeFullscreen()
        stopTimers()
        cancelDocumentSelection()
        resetBridgeState()
        this.config = config
        this.participantDigest = AgilParticipantDigest(config.maxParticipants)
        this.connectionDigest = AgilConnectionDigest()
        this.serverOrigin = newTarget.origin
        this.origins = newOrigins
        this.pendingUrl = newTarget.url
        this.lastLoadFailureReported = false
        // A new page load gets a fresh bridge secret; the shim that forwards
        // widget messages is the only place the value is embedded.
        this.bridgeNonce = AgilBridgeEnvelope.newNonce()

        configureSettings(config.autoplay)
        setBackgroundColor(config.backgroundColor)
        webView.setBackgroundColor(config.backgroundColor)
        if (config.safeArea) requestApplyInsets() else setPadding(0, 0, 0, 0)

        try {
            webView.loadUrl(newTarget.url)
        } catch (error: RuntimeException) {
            emitError(AgilCallError.LoadFailed(AgilTokenRedactor.redactThrowable(error)))
            return
        }
        scheduleReadyTimeout()
        schedulePing()
    }

    /** Stops the page and forgets the current configuration. */
    fun unload() {
        checkMainThread()
        if (released) return
        exitNativeFullscreen()
        stopTimers()
        cancelDocumentSelection()
        resetBridgeState()
        config = null
        serverOrigin = null
        pendingUrl = null
        origins = emptySet()
        bridgeNonce = ""
        try {
            webView.stopLoading()
            webView.loadUrl("about:blank")
        } catch (_: RuntimeException) {
            // The renderer may already be gone; there is nothing else to stop.
        }
    }

    /** Reloads the current call (no-op without a configuration). */
    fun reload() {
        checkMainThread()
        if (released) return
        val current = config ?: return
        load(current)
    }

    /**
     * Explicit host reconnect: announces the transition, then reloads with the
     * same server/room/token. `load()` rotates the bridge nonce and restarts the
     * participant digest with one bounded snapshot.
     */
    fun reconnect() {
        checkMainThread()
        if (released) return
        val previous = connectionDigest.currentState ?: AgilConnectionState.RECONNECTING
        emit(
            AgilCallEvent.Connection(
                AgilConnectionUpdate(
                    state = AgilConnectionState.CONNECTING,
                    previous = previous,
                    reconnecting = true,
                ),
            ),
        )
        reload()
    }

    /** Pauses WebView media/timers; call from `Activity.onPause`. */
    fun onPause() {
        if (released || webViewDestroyed) return
        try {
            webView.onPause()
        } catch (_: RuntimeException) {
            // Ignore a race with renderer death.
        }
    }

    /** Resumes WebView media/timers; call from `Activity.onResume`. */
    fun onResume() {
        if (released || webViewDestroyed) return
        try {
            webView.onResume()
        } catch (_: RuntimeException) {
            // Ignore a race with renderer death.
        }
    }

    /** Permanently tears the WebView down. Idempotent; call from `onDestroy`. */
    fun release() {
        if (released) return
        checkMainThread()
        released = true
        stopTimers()
        cancelDocumentSelection()
        resetBridgeState()
        rejectPendingPermission()
        listener = null
        externalLinkHandler = null
        config = null
        serverOrigin = null
        pendingUrl = null
        origins = emptySet()
        bridgeNonce = ""
        try {
            webView.stopLoading()
        } catch (_: RuntimeException) {
            // Renderer already gone.
        }
        exitNativeFullscreen()
        nativeFullscreenListener = null
        removeAllViews()
        if (!webViewDestroyed) {
            webViewDestroyed = true
            try {
                webView.destroy()
            } catch (_: RuntimeException) {
                // WebView.destroy can throw after renderer death; nothing to do.
            }
        }
    }

    /** Toggles the microphone (`agil:action toggle-mic`). */
    fun toggleMute() = sendAction(ACTION_TOGGLE_MIC)

    /** Toggles the camera (`agil:action toggle-camera`). */
    fun toggleCamera() = sendAction(ACTION_TOGGLE_CAMERA)

    /** Opens/closes the widget chat panel (`agil:action toggle-chat`). */
    fun toggleChat() = sendAction(ACTION_TOGGLE_CHAT)

    /** Starts/stops screen sharing (`agil:action share-screen`). */
    fun toggleScreenShare() = sendAction(ACTION_SHARE_SCREEN)

    /** Enables background blur (`agil:action blur-on`). */
    fun blurOn() = sendAction(ACTION_BLUR_ON)

    /** Disables background blur (`agil:action blur-off`). */
    fun blurOff() = sendAction(ACTION_BLUR_OFF)

    /** Asks the widget to minimize itself (`agil:action minimize`). */
    fun minimize() = sendAction(ACTION_MINIMIZE)

    /** Restores a minimized widget (`agil:action restore`). */
    fun restore() = sendAction(ACTION_RESTORE)

    /** Requests/releases picture-in-picture (`agil:action pip`). */
    fun togglePictureInPicture() = sendAction(ACTION_PIP)

    /** Toggles the widget's DOM fullscreen (`agil:action fullscreen`). */
    fun toggleFullscreen() = sendAction(ACTION_FULLSCREEN)

    /** Opens the call in a new tab (`agil:action newtab`). */
    fun openInNewTab() = sendAction(ACTION_NEW_TAB)

    /** Raises/lowers the hand (`agil:action raise-hand`). */
    fun raiseHand() = sendAction(ACTION_RAISE_HAND)

    /** Leaves the call (`agil:action leave`). */
    fun leave() = sendAction(ACTION_LEAVE)

    /**
     * Sends an arbitrary widget action from the documented set
     * ([WIDGET_ACTIONS]); unknown names are rejected instead of being forwarded.
     * Prefer the typed helpers above.
     */
    fun sendAction(action: String) {
        if (!WIDGET_ACTIONS.contains(action)) {
            emitError(
                AgilCallError.InvalidConfig(
                    "action",
                    "unknown widget action; expected one of ${WIDGET_ACTIONS.joinToString()}",
                ),
            )
            return
        }
        sendCommand(
            JSONObject()
                .put("type", "agil:action")
                .put("action", action),
        )
    }

    /**
     * Sends an emoji reaction (`agil:action reaction` with `emoji`, max 16
     * characters). The widget normalizes/filters the value.
     */
    fun sendReaction(emoji: String) {
        checkMainThread()
        checkNotReleased()
        val value = emoji.trim()
        if (value.isEmpty() || value.length > AgilBridgeProtocol.MAX_REACTION_CHARS ||
            value.any { it.code < 0x20 || it.code == 0x7F }
        ) {
            emitError(
                AgilCallError.InvalidConfig(
                    "emoji",
                    "emoji must be 1..${AgilBridgeProtocol.MAX_REACTION_CHARS} printable characters",
                ),
            )
            return
        }
        sendCommand(
            JSONObject()
                .put("type", "agil:action")
                .put("action", ACTION_REACTION)
                .put("emoji", value),
        )
    }

    /** Sends a chat message through `agil:chat-send` (max 4000 characters). */
    fun sendChat(text: String) {
        checkMainThread()
        checkNotReleased()
        if (text.isBlank()) {
            emitError(AgilCallError.InvalidConfig("text", "chat text must not be empty"))
            return
        }
        if (text.length > AgilBridgeProtocol.MAX_CHAT_CHARS) {
            emitError(
                AgilCallError.InvalidConfig(
                    "text",
                    "chat text is too long (max ${AgilBridgeProtocol.MAX_CHAT_CHARS})",
                ),
            )
            return
        }
        sendCommand(
            JSONObject()
                .put("type", "agil:chat-send")
                .put("text", text),
        )
    }

    /** Switches light/dark/auto without reloading (`agil:scheme`). */
    fun setTheme(theme: AgilTheme) {
        sendCommand(
            JSONObject()
                .put("type", "agil:scheme")
                .put("scheme", theme.wire),
        )
    }

    /**
     * Applies a partial theme patch without reloading (`agil:theme`, same shape
     * as the widget's `updateTheme`/`ThemePatch`).
     */
    fun applyTheme(theme: JSONObject) {
        sendCommand(
            JSONObject()
                .put("type", "agil:theme")
                .put("theme", JSONObject(theme.toString())),
        )
    }

    /**
     * Applies a tenant-config patch without reloading (`agil:config`, same shape
     * as the widget's `updateConfig`/`TenantConfigPatch`).
     */
    fun applyConfig(config: JSONObject) {
        sendCommand(
            JSONObject()
                .put("type", "agil:config")
                .put("config", JSONObject(config.toString())),
        )
    }

    /** Sends `agil:ping`; the widget answers `agil:pong` (no public event). */
    fun ping() {
        sendCommand(JSONObject().put("type", "agil:ping"))
    }

    /**
     * Forwards the host Activity's `onRequestPermissionsResult` to the pending
     * media permission prompt. Returns `true` when the request belongs to this
     * view.
     */
    @Suppress("UNUSED_PARAMETER")
    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val pending = pendingPermission ?: return true
        val resources = pendingPermissionResources
        pendingPermission = null
        pendingPermissionResources = emptyArray()
        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        if (granted) {
            grantPermission(pending, resources.toList())
        } else {
            denyPermission(pending)
            emitError(AgilCallError.PermissionDenied(resources.map(::permissionResourceName)))
        }
        return true
    }

    /** Forwards the host Activity's result for a file input in the call. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        checkMainThread()
        val (code, callback) = pendingDocument ?: return false
        if (requestCode != code) return false
        pendingDocument = null
        val uri = if (resultCode == Activity.RESULT_OK && !released && isCurrentPageAllowed()) {
            data?.data?.takeIf(::canReadSelectedDocument)
        } else null
        callback.onReceiveValue(uri?.let { arrayOf(it) })
        return true
    }

    private fun canReadSelectedDocument(uri: Uri): Boolean {
        if (uri.scheme != "content" || uri.authority.isNullOrEmpty()) return false
        return try {
            DocumentsContract.isDocumentUri(context, uri) &&
                context.checkUriPermission(uri, Process.myPid(), Process.myUid(),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION) == PackageManager.PERMISSION_GRANTED
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun cancelDocumentSelection() {
        val callback = pendingDocument?.second ?: return
        pendingDocument = null
        try {
            callback.onReceiveValue(null)
        } catch (_: RuntimeException) {
            // The renderer can disappear while the picker is open.
        }
    }

    // ---------------------------------------------------------------------
    // Window insets (safe area)
    // ---------------------------------------------------------------------

    @Suppress("DEPRECATION")
    override fun onApplyWindowInsets(insets: WindowInsets): WindowInsets {
        if (!released) {
            if (config?.safeArea == true) {
                val left: Int
                val top: Int
                val right: Int
                val bottom: Int
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val bars = insets.getInsets(
                        WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout(),
                    )
                    left = bars.left
                    top = bars.top
                    right = bars.right
                    bottom = bars.bottom
                } else {
                    var leftInset = insets.systemWindowInsetLeft
                    var topInset = insets.systemWindowInsetTop
                    var rightInset = insets.systemWindowInsetRight
                    var bottomInset = insets.systemWindowInsetBottom
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        val cutout = insets.displayCutout
                        if (cutout != null) {
                            leftInset = maxOf(leftInset, cutout.safeInsetLeft)
                            topInset = maxOf(topInset, cutout.safeInsetTop)
                            rightInset = maxOf(rightInset, cutout.safeInsetRight)
                            bottomInset = maxOf(bottomInset, cutout.safeInsetBottom)
                        }
                    }
                    left = leftInset
                    top = topInset
                    right = rightInset
                    bottom = bottomInset
                }
                setPadding(left, top, right, bottom)
            } else {
                setPadding(0, 0, 0, 0)
            }
        }
        return super.onApplyWindowInsets(insets)
    }

    override fun onDetachedFromWindow() {
        if (!released && !webViewDestroyed) {
            exitNativeFullscreen()
            try {
                webView.onPause()
            } catch (_: RuntimeException) {
                // Renderer already gone.
            }
        }
        super.onDetachedFromWindow()
    }

    /** Closes the native fullscreen surface, for example from the host Back action. */
    fun exitNativeFullscreen(): Boolean {
        checkMainThread()
        val view = customView ?: return false
        val callback = customViewCallback
        customView = null
        customViewCallback = null
        removeView(view)
        if (!released && !webViewDestroyed) webView.visibility = View.VISIBLE
        dispatchNativeFullscreen(false)
        try {
            callback?.onCustomViewHidden()
        } catch (_: RuntimeException) {
            // The renderer can disappear while fullscreen is open.
        }
        return true
    }

    private fun dispatchNativeFullscreen(active: Boolean) {
        try {
            nativeFullscreenListener?.invoke(active)
        } catch (_: RuntimeException) {
            // Keep WebView lifecycle transitions independent of host callbacks.
        }
    }

    /**
     * Reads the current hosted page's resolved light/dark scheme for host chrome.
     * Older widget pages without a scheme marker return null.
     */
    fun readRenderedTheme(callback: (AgilTheme?) -> Unit) {
        checkMainThread()
        if (released || !isCurrentPageAllowed()) {
            callback(null)
            return
        }
        val nonce = bridgeNonce
        try {
            webView.evaluateJavascript("document.documentElement?.dataset.embedScheme") { value ->
                if (!released && nonce == bridgeNonce && isCurrentPageAllowed()) {
                    callback(AgilTheme.fromWire(value?.trim('"')))
                }
            }
        } catch (_: RuntimeException) {
            callback(null)
        }
    }

    // ---------------------------------------------------------------------
    // Internal setup / bridge
    // ---------------------------------------------------------------------

    @Suppress("DEPRECATION")
    private fun configureSettings(autoplay: Boolean) {
        val settings = webView.settings
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.databaseEnabled = false
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        settings.allowFileAccessFromFileURLs = false
        settings.allowUniversalAccessFromFileURLs = false
        settings.javaScriptCanOpenWindowsAutomatically = false
        settings.setSupportMultipleWindows(false)
        settings.mediaPlaybackRequiresUserGesture = !autoplay
        settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        settings.cacheMode = WebSettings.LOAD_DEFAULT
        settings.setGeolocationEnabled(false)
        settings.setSupportZoom(false)
        settings.builtInZoomControls = false
        settings.displayZoomControls = false
        settings.useWideViewPort = true
        settings.loadWithOverviewMode = false
        settings.textZoom = 100
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            settings.safeBrowsingEnabled = true
        }
        val cookies = CookieManager.getInstance()
        cookies.setAcceptCookie(true)
        cookies.setAcceptThirdPartyCookies(webView, false)
    }

    private fun resetBridgeState(clearQueue: Boolean = true) {
        widgetReady = false
        isReady = false
        isJoined = false
        timedOut = false
        lastParticipantCount = null
        participantDigest.reset()
        connectionDigest.reset()
        if (clearQueue) commandQueue.clear()
    }

    private fun stopTimers() {
        readyTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        readyTimeoutRunnable = null
        pingRunnable?.let { mainHandler.removeCallbacks(it) }
        pingRunnable = null
    }

    private fun scheduleReadyTimeout() {
        readyTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        readyTimeoutRunnable = null
        val timeout = config?.bridgeTimeoutMillis ?: return
        if (timeout <= 0L) return
        val runnable = object : Runnable {
            override fun run() {
                if (released || widgetReady) return
                timedOut = true
                commandQueue.clear()
                pingRunnable?.let { mainHandler.removeCallbacks(it) }
                pingRunnable = null
                emitError(
                    AgilCallError.Timeout(
                        "The call widget did not signal ready within $timeout ms",
                    ),
                )
            }
        }
        readyTimeoutRunnable = runnable
        mainHandler.postDelayed(runnable, timeout)
    }

    /**
     * Sends an `agil:ping` every [PING_INTERVAL_MS] and re-installs the shim.
     *
     * Pings let the SDK recover when `agil:ready` was posted before the shim
     * was installed: the page answers `agil:pong`, which flushes queued
     * commands. The page itself is not modified.
     */
    private fun schedulePing() {
        pingRunnable?.let { mainHandler.removeCallbacks(it) }
        val runnable = object : Runnable {
            override fun run() {
                if (released || widgetReady || timedOut) return
                installShim()
                postToPage(JSONObject().put("type", "agil:ping").toString())
                mainHandler.postDelayed(this, PING_INTERVAL_MS)
            }
        }
        pingRunnable = runnable
        mainHandler.postDelayed(runnable, PING_DELAY_MS)
    }

    private fun installShim() {
        val currentOrigin = serverOrigin ?: return
        val nonce = bridgeNonce
        if (nonce.isEmpty()) return
        evaluateJavascript(AgilBridgeScript.shim(currentOrigin, nonce))
    }

    private fun evaluateJavascript(script: String) {
        if (released || webViewDestroyed) return
        try {
            webView.evaluateJavascript(script, null)
        } catch (_: RuntimeException) {
            // Renderer gone or page not ready; the next ping retries.
        }
    }

    private fun sendCommand(command: JSONObject) {
        checkMainThread()
        checkNotReleased()
        val json = command.toString()
        if (json.length > AgilBridgeProtocol.MAX_MESSAGE_CHARS) {
            emitError(AgilCallError.Bridge("The bridge command is too large"))
            return
        }
        if (!widgetReady) {
            if (timedOut) {
                emitError(AgilCallError.Bridge("The call widget is not ready"))
                return
            }
            if (commandQueue.size >= AgilBridgeProtocol.MAX_QUEUED_COMMANDS) {
                emitError(AgilCallError.Bridge("The bridge command queue is full"))
                return
            }
            commandQueue.addLast(json)
            return
        }
        postToPage(json)
    }

    private fun postToPage(json: String) {
        evaluateJavascript(AgilBridgeScript.postMessage(json))
    }

    private fun flushQueue() {
        while (commandQueue.isNotEmpty()) {
            postToPage(commandQueue.removeFirst())
        }
    }

    private fun markWidgetReady() {
        if (widgetReady) return
        widgetReady = true
        isReady = true
        timedOut = false
        readyTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        readyTimeoutRunnable = null
        pingRunnable?.let { mainHandler.removeCallbacks(it) }
        pingRunnable = null
        flushQueue()
    }

    private fun handleBridgeMessage(raw: String) {
        if (!isCurrentPageAllowed()) return
        val message = AgilBridgeProtocol.parse(raw) ?: return
        when (message) {
            is AgilBridgeProtocol.Message.Shim -> Unit
            is AgilBridgeProtocol.Message.Pong -> markWidgetReady()
            is AgilBridgeProtocol.Message.Ready -> {
                markWidgetReady()
                emit(AgilCallEvent.Ready(message.capabilities, message.room))
            }
            is AgilBridgeProtocol.Message.Chat -> {
                markWidgetReady()
                emit(AgilCallEvent.Chat(message.message))
            }
            is AgilBridgeProtocol.Message.State -> {
                markWidgetReady()
                val snapshot = message.snapshot
                when (snapshot.phase) {
                    "joined" -> isJoined = true
                    "left", "idle" -> isJoined = false
                }
                lastParticipantCount = snapshot.participants
                // A count-only state (no `participantIds`) must reach the
                // digest as null, otherwise an empty room and a summary are
                // indistinguishable and SUMMARY is unreachable from this view.
                val update = participantDigest.apply(
                    if (snapshot.hasParticipantIds) snapshot.participantIds else null,
                    snapshot.participants,
                )
                val connection = connectionDigest.apply(snapshot.connectionState, null, null)
                if (connection != null) emit(AgilCallEvent.Connection(connection))
                val compact = snapshot.compactForParticipantUpdate(update)
                emit(AgilCallEvent.State(compact))
                if (update != null) emit(AgilCallEvent.Participants(update))
            }
            is AgilBridgeProtocol.Message.Event -> {
                // Chat/joined/state events are proof that the page is mounted;
                // an error can be a fatal mount error, so it is not.
                if (message.name != "error") markWidgetReady()
                handleWidgetEvent(message)
            }
        }
    }

    private fun handleWidgetEvent(event: AgilBridgeProtocol.Message.Event) {
        when (event.name) {
            "joined" -> {
                isJoined = true
                emit(AgilCallEvent.Joined(joinedParticipantCount(event.payload)))
            }
            "left" -> {
                isJoined = false
                emit(AgilCallEvent.Left(leftReason(event.payload)))
            }
            "error" -> {
                val code = jsonText(event.payload, "code", 64)
                    ?.let { AgilTokenRedactor.redactText(it).take(64) }
                val rawMessage = jsonText(event.payload, "message", 512)
                val safeMessage = rawMessage?.let { AgilTokenRedactor.redactText(it).take(300) }
                    ?: "The widget reported an error"
                // The widget sends its own `fatal` flag for signaling errors
                // (`signaling-client.ts`), and anything before the handshake is
                // a fatal mount error.
                val widgetFatal = event.payload?.let { value ->
                    value.has("fatal") && !value.isNull("fatal") && value.optBoolean("fatal", false)
                } == true
                emitError(
                    AgilCallError.Widget(
                        code,
                        safeMessage,
                        fatal = !widgetReady || widgetFatal,
                    ),
                )
            }
            "action-denied" -> {
                val action = jsonText(event.payload, "action", 64)
                    ?.let { AgilTokenRedactor.redactText(it).take(64) }
                val reason = jsonText(event.payload, "reason", 64)
                    ?.let { AgilTokenRedactor.redactText(it).take(64) }
                emitError(AgilCallError.ActionDenied(action = action, reason = reason))
            }
            "connection-state", "connection-changed" -> {
                val connection = connectionDigest.apply(
                    jsonText(event.payload, "connection", 40)
                        ?: jsonText(event.payload, "connectionState", 40),
                    event.payload?.optInt("attempt", -1)?.takeIf { it >= 0 },
                    event.payload?.optInt("delayMs", -1)?.takeIf { it >= 0 },
                )
                if (connection != null) emit(AgilCallEvent.Connection(connection))
                emit(AgilCallEvent.Generic(event.name, event.payloadJson))
            }
            else -> emit(AgilCallEvent.Generic(event.name, event.payloadJson))
        }
    }

    private fun isCurrentPageAllowed(): Boolean {
        val widgetOrigin = serverOrigin ?: return false
        val url = try {
            webView.url
        } catch (_: RuntimeException) {
            null
        } ?: return false
        // Only the widget origin may talk to the native bridge. Allowlisted
        // SSO origins are navigation targets, not bridge peers.
        return AgilCallUrl.originOfUrl(url) == widgetOrigin
    }

    /**
     * Best-effort participant count for `Joined`.
     *
     * The widget's `joined` payload is `{room, self}` (no count), so the count is
     * taken from a `participants`/`participantIds` field when a server variant
     * sends one, else from the latest `agil:state` snapshot, else falls back to
     * `1` (the local participant is joined). The authoritative count always
     * arrives in the following [AgilCallEvent.State] snapshot.
     */
    private fun joinedParticipantCount(payload: JSONObject?): Int {
        if (payload != null) {
            if (payload.has("participants") && !payload.isNull("participants")) {
                val count = payload.optInt("participants", -1)
                if (count >= 1) return count
            }
            val ids = payload.optJSONArray("participantIds")
            if (ids != null && ids.length() > 0) return ids.length()
        }
        val known = lastParticipantCount ?: 0
        return if (known >= 1) known else 1
    }

    /**
     * The widget's `left` payload is currently `{}`; report the reason when a
     * future version sends one, otherwise the local-leave reason.
     */
    private fun leftReason(payload: JSONObject?): String =
        jsonText(payload, "reason", 64)
            ?.let { AgilTokenRedactor.redactText(it).take(64) }
            ?: LEFT_REASON_LOCAL

    private fun jsonText(payload: JSONObject?, key: String, max: Int): String? {
        if (payload == null || !payload.has(key) || payload.isNull(key)) return null
        val value = payload.optString(key, "")
        if (value.isBlank()) return null
        return if (value.length > max) value.substring(0, max) else value
    }

    private fun emit(event: AgilCallEvent) {
        val currentListener = listener ?: return
        try {
            currentListener.onEvent(event)
        } catch (_: RuntimeException) {
            // A host callback must never break the bridge.
        }
    }

    private fun emitError(error: AgilCallError) {
        emit(AgilCallEvent.Error(error))
    }

    private fun reportInvalidConfig(error: AgilCallConfigException) {
        emitError(
            AgilCallError.InvalidConfig(
                field = error.field,
                message = error.message ?: "invalid configuration",
            ),
        )
    }

    private fun checkMainThread() {
        check(Looper.myLooper() == Looper.getMainLooper()) {
            "AgilCallView must be used on the main thread"
        }
    }

    private fun checkNotReleased() {
        check(!released) { "AgilCallView has been released" }
    }

    private fun rejectPendingPermission() {
        val pending = pendingPermission ?: return
        pendingPermission = null
        pendingPermissionResources = emptyArray()
        denyPermission(pending)
    }

    // ---------------------------------------------------------------------
    // WebView callbacks
    // ---------------------------------------------------------------------

    @SuppressLint("JavascriptInterface")
    private inner class JsBridge {
        @JavascriptInterface
        fun postMessage(json: String?) {
            // The interface is visible to every frame; only messages wrapped in
            // the current per-load nonce envelope can come from the widget
            // top-frame shim. Anything else (subframe, other origin) is dropped.
            val payload = AgilBridgeEnvelope.unwrap(json, bridgeNonce) ?: return
            if (payload.isEmpty() || payload.length > AgilBridgeProtocol.MAX_MESSAGE_CHARS) return
            mainHandler.post {
                if (released) return@post
                handleBridgeMessage(payload)
            }
        }
    }

    private inner class AgilWebViewClient : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
            if (request == null) return true
            if (!request.isForMainFrame) return false
            return handleNavigation(request.url)
        }

        override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
            super.onPageStarted(view, url, favicon)
            if (released || config == null) return
            cancelDocumentSelection()
            stopTimers()
            // Commands queued between load() and this callback belong to the
            // new page; keep them until the handshake flushes the queue.
            resetBridgeState(clearQueue = false)
            lastLoadFailureReported = false
            installShim()
            scheduleReadyTimeout()
            schedulePing()
        }

        override fun onPageCommitVisible(view: WebView?, url: String?) {
            super.onPageCommitVisible(view, url)
            if (!released && config != null) installShim()
        }

        override fun onPageFinished(view: WebView?, url: String?) {
            super.onPageFinished(view, url)
            if (!released && config != null) installShim()
        }

        override fun onReceivedError(
            view: WebView?,
            request: WebResourceRequest?,
            error: WebResourceError?,
        ) {
            super.onReceivedError(view, request, error)
            if (released || request?.isForMainFrame != true) return
            if (!isCurrentMainFrame(request)) return
            reportLoadFailure(
                error?.description?.toString()
                    ?.let { AgilTokenRedactor.redactText(it).take(300) }
                    ?: "The call page failed to load",
            )
        }

        override fun onReceivedHttpError(
            view: WebView?,
            request: WebResourceRequest?,
            response: WebResourceResponse?,
        ) {
            super.onReceivedHttpError(view, request, response)
            if (released || request?.isForMainFrame != true) return
            if (!isCurrentMainFrame(request)) return
            val status = response?.statusCode ?: 0
            reportLoadFailure("The call page returned HTTP $status", status)
        }

        override fun onReceivedSslError(
            view: WebView?,
            handler: SslErrorHandler?,
            error: android.net.http.SslError?,
        ) {
            // Never proceed past a certificate error.
            handler?.cancel()
            if (released) return
            reportLoadFailure("TLS certificate rejected")
        }

        override fun onRenderProcessGone(
            view: WebView?,
            detail: RenderProcessGoneDetail?,
        ): Boolean {
            if (released) return true
            stopTimers()
            cancelDocumentSelection()
            resetBridgeState()
            rejectPendingPermission()
            val crashed = detail?.didCrash() == true
            emitError(
                AgilCallError.RenderProcessGone(
                    if (crashed) "The WebView renderer crashed" else "The WebView renderer exited",
                ),
            )
            listener = null
            externalLinkHandler = null
            config = null
            serverOrigin = null
            pendingUrl = null
            origins = emptySet()
            webViewDestroyed = true
            released = true
            exitNativeFullscreen()
            nativeFullscreenListener = null
            try {
                removeAllViews()
                view?.destroy()
            } catch (_: RuntimeException) {
                // Already destroyed.
            }
            return true
        }

        private fun isCurrentMainFrame(request: WebResourceRequest): Boolean {
            val requestUrl = request.url.toString()
            val expected = pendingUrl
            if (expected != null && requestUrl == expected) return true
            val currentUrl = try {
                webView.url
            } catch (_: RuntimeException) {
                null
            } ?: return true
            // Ignore a late error from a page we already navigated away from.
            return requestUrl == currentUrl
        }

        private fun handleNavigation(uri: Uri): Boolean {
            val currentOrigin = serverOrigin ?: return true
            val url = uri.toString()
            if (AgilCallUrl.isAllowedNavigation(url, currentOrigin, origins)) return false
            if (uri.scheme == "http" || uri.scheme == "https") {
                try {
                    externalLinkHandler?.invoke(url)
                } catch (_: RuntimeException) {
                    // A host callback must never break navigation handling.
                }
            }
            emitError(
                AgilCallError.NavigationBlocked(AgilTokenRedactor.redactUrl(url)),
            )
            return true
        }

        private fun reportLoadFailure(message: String, status: Int? = null) {
            if (lastLoadFailureReported) return
            lastLoadFailureReported = true
            if (status != null && status > 0) {
                emitError(AgilCallError.Http(status, message))
            } else {
                emitError(AgilCallError.LoadFailed(message))
            }
        }
    }

    private inner class AgilChromeClient : WebChromeClient() {
        @Suppress("DEPRECATION")
        override fun onShowFileChooser(
            view: WebView,
            callback: ValueCallback<Array<Uri>>,
            params: FileChooserParams,
        ): Boolean {
            val activity = findActivity()
            if (released || view !== webView || !isCurrentPageAllowed() || activity == null ||
                pendingDocument != null || params.mode != FileChooserParams.MODE_OPEN || params.isCaptureEnabled
            ) return false

            val types = params.acceptTypes.flatMap { it.split(',') }.map(String::trim)
                .filter { it.contains('/') }.distinct()
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = types.singleOrNull() ?: "*/*"
                if (types.size > 1) putExtra(Intent.EXTRA_MIME_TYPES, types.toTypedArray())
            }
            val code = nextDocumentRequestCode
            nextDocumentRequestCode = if (code == 0x5FFF) 0x5200 else code + 1
            pendingDocument = code to callback
            try {
                activity.startActivityForResult(intent, code)
            } catch (_: RuntimeException) {
                cancelDocumentSelection()
            }
            return true
        }

        override fun onPermissionRequest(request: PermissionRequest) {
            handlePermissionRequest(request)
        }

        override fun onPermissionRequestCanceled(request: PermissionRequest) {
            if (pendingPermission === request) {
                pendingPermission = null
                pendingPermissionResources = emptyArray()
            }
        }

        /**
         * HTML5 video/DOM fullscreen support for large-room video tiles. The
         * custom view is added on top of the WebView; [onHideCustomView]
         * restores the widget page.
         */
        override fun onShowCustomView(view: View?, callback: WebChromeClient.CustomViewCallback?) {
            if (released || view == null) {
                callback?.onCustomViewHidden()
                return
            }
            if (customView != null) {
                callback?.onCustomViewHidden()
                return
            }
            customView = view
            customViewCallback = callback
            webView.visibility = View.GONE
            addView(
                view,
                android.widget.FrameLayout.LayoutParams(
                    LayoutParams.MATCH_PARENT,
                    LayoutParams.MATCH_PARENT,
                ),
            )
            dispatchNativeFullscreen(true)
        }

        override fun onHideCustomView() {
            exitNativeFullscreen()
        }

        override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean {
            // No logs: page console output may contain tokens or user content.
            return true
        }

        override fun onGeolocationPermissionsShowPrompt(
            origin: String,
            callback: GeolocationPermissions.Callback,
        ) {
            callback.invoke(origin, false, false)
        }
    }

    @SuppressLint("MissingPermission")
    private fun handlePermissionRequest(request: PermissionRequest) {
        val requestedOrigin = try {
            request.origin?.toString()
        } catch (_: RuntimeException) {
            null
        }
        val originValue = requestedOrigin?.let { AgilCallUrl.originOfUrl(it) }
        if (originValue == null || originValue != serverOrigin) {
            denyPermission(request)
            return
        }
        val resources = request.resources.filter {
            it == PermissionRequest.RESOURCE_VIDEO_CAPTURE ||
                it == PermissionRequest.RESOURCE_AUDIO_CAPTURE
        }
        if (resources.isEmpty()) {
            denyPermission(request)
            return
        }
        val needed = ArrayList<String>(2)
        if (resources.contains(PermissionRequest.RESOURCE_VIDEO_CAPTURE) &&
            !hasPermission(Manifest.permission.CAMERA)
        ) {
            needed.add(Manifest.permission.CAMERA)
        }
        if (resources.contains(PermissionRequest.RESOURCE_AUDIO_CAPTURE) &&
            !hasPermission(Manifest.permission.RECORD_AUDIO)
        ) {
            needed.add(Manifest.permission.RECORD_AUDIO)
        }
        if (needed.isEmpty()) {
            grantPermission(request, resources)
            return
        }
        val activity = findActivity()
        if (activity == null) {
            denyPermission(request)
            emitError(AgilCallError.PermissionDenied(resources.map(::permissionResourceName)))
            return
        }
        rejectPendingPermission()
        pendingPermission = request
        pendingPermissionResources = resources.toTypedArray()
        try {
            activity.requestPermissions(needed.toTypedArray(), PERMISSION_REQUEST_CODE)
        } catch (_: RuntimeException) {
            rejectPendingPermission()
            emitError(AgilCallError.PermissionDenied(resources.map(::permissionResourceName)))
        }
    }

    private fun hasPermission(permission: String): Boolean =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun grantPermission(request: PermissionRequest, resources: List<String>) {
        try {
            request.grant(resources.toTypedArray())
        } catch (_: RuntimeException) {
            denyPermission(request)
        }
    }

    private fun denyPermission(request: PermissionRequest) {
        try {
            request.deny()
        } catch (_: RuntimeException) {
            // The request was already granted or cancelled.
        }
    }

    private fun findActivity(): Activity? {
        var current: Context? = context
        while (current != null) {
            if (current is Activity) return current
            current = (current as? ContextWrapper)?.baseContext
        }
        return null
    }

    private fun permissionResourceName(resource: String): String = when (resource) {
        PermissionRequest.RESOURCE_VIDEO_CAPTURE -> "camera"
        PermissionRequest.RESOURCE_AUDIO_CAPTURE -> "microphone"
        else -> resource
    }

    companion object {
        /** Request code forwarded from `Activity.onRequestPermissionsResult`. */
        const val PERMISSION_REQUEST_CODE: Int = 0x4147
        private var nextDocumentRequestCode = 0x5200

        /**
         * Actions the hosted widget documents for `agil:action`
         * (`agil/core/docs/contract.md` §7, `agil/websdk/embed/src/bridge.ts`) plus the
         * forward-compatible `raise-hand`/`reaction` extensions. Anything else
         * is rejected locally instead of producing a widget `action-denied`.
         */
        @JvmField
        val WIDGET_ACTIONS: Set<String> = java.util.Collections.unmodifiableSet(
            linkedSetOf(
                "toggle-mic",
                "toggle-camera",
                "toggle-chat",
                "share-screen",
                "blur-on",
                "blur-off",
                "minimize",
                "restore",
                "pip",
                "fullscreen",
                "newtab",
                "leave",
                "raise-hand",
                "reaction",
            ),
        )

        /** `Left.reason` used when the widget sends no reason (it currently sends none). */
        const val LEFT_REASON_LOCAL: String = "local"

        private val DEFAULT_BACKGROUND = 0xFF080D16.toInt()
        private const val PING_INTERVAL_MS = 800L
        private const val PING_DELAY_MS = 350L
        private const val ACTION_TOGGLE_MIC = "toggle-mic"
        private const val ACTION_TOGGLE_CAMERA = "toggle-camera"
        private const val ACTION_TOGGLE_CHAT = "toggle-chat"
        private const val ACTION_SHARE_SCREEN = "share-screen"
        private const val ACTION_BLUR_ON = "blur-on"
        private const val ACTION_BLUR_OFF = "blur-off"
        private const val ACTION_MINIMIZE = "minimize"
        private const val ACTION_RESTORE = "restore"
        private const val ACTION_PIP = "pip"
        private const val ACTION_FULLSCREEN = "fullscreen"
        private const val ACTION_NEW_TAB = "newtab"
        private const val ACTION_RAISE_HAND = "raise-hand"
        private const val ACTION_REACTION = "reaction"
        private const val ACTION_LEAVE = "leave"
    }
}
