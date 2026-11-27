package com.agil.calls

import android.annotation.SuppressLint
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONObject
import java.util.UUID

/**
 * Full-screen Android WebView hosting `/embed.html`.
 *
 * Android has no document-start script injection hook, so the bridge shim is
 * installed from `onPageStarted` and retried from `onPageFinished`. The widget
 * posts `agil:ready` only after its async mount, so the retry covers slow
 * devices; messages posted before the shim installed cannot be recovered.
 */
class AgilCallActivity : AppCompatActivity() {
    companion object {
        const val EXTRA_URL = "agil_call_url"
        const val EXTRA_ALLOWED_ORIGINS = "agil_call_allowed_origins"
        const val EXTRA_CAMERA = "agil_call_camera"
        const val EXTRA_MICROPHONE = "agil_call_microphone"
        private const val BRIDGE_NAME = "AgilBridge"
    }

    private var webView: WebView? = null
    private var widgetOrigin: String = ""
    private var allowedOrigins: Set<String> = emptySet()
    /** Per-load secret: only the widget-origin shim receives it. */
    private var bridgeNonce: String = ""
    private var cameraAllowed = true
    private var microphoneAllowed = true
    /** HTML5 video/DOM fullscreen surface handed over by `WebChromeClient`. */
    private var customView: View? = null
    private var customViewCallback: WebChromeClient.CustomViewCallback? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = intent.getStringExtra(EXTRA_URL)
        if (url.isNullOrBlank()) {
            finish()
            return
        }
        val origin = originOf(Uri.parse(url)) ?: run {
            finish()
            return
        }
        widgetOrigin = origin
        allowedOrigins = (intent.getStringArrayListExtra(EXTRA_ALLOWED_ORIGINS) ?: arrayListOf())
            .mapNotNull { originOf(Uri.parse(it)) }
            .toSet()
        cameraAllowed = intent.getBooleanExtra(EXTRA_CAMERA, true)
        microphoneAllowed = intent.getBooleanExtra(EXTRA_MICROPHONE, true)

        val web = WebView(this)
        web.layoutParams = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        )
        setContentView(web)
        webView = web
        bridgeNonce = UUID.randomUUID().toString() + UUID.randomUUID().toString()
        configure(web)

        AgilCallBridge.closer = { finish() }
        AgilCallBridge.themeApplier = { scheme, theme ->
            runOnUiThread { applyTheme(web, scheme, theme) }
        }
        AgilCallBridge.setActionSender { action ->
            runOnUiThread {
                postMessage(
                    web,
                    JSONObject().put("type", "agil:action").put("action", action).toString()
                )
            }
            true
        }
        AgilCallBridge.setChatSender { text ->
            runOnUiThread {
                postMessage(
                    web,
                    JSONObject().put("type", "agil:chat-send").put("text", text).toString()
                )
            }
            true
        }
        web.loadUrl(url)
    }

    @SuppressLint("SetJavaScriptEnabled")
    @Suppress("DEPRECATION")
    private fun configure(web: WebView) {
        web.setBackgroundColor(0xFF080D16.toInt())
        // Large-room presentation parity with the AGIL Android SDK view.
        web.overScrollMode = View.OVER_SCROLL_NEVER
        web.isVerticalScrollBarEnabled = false
        web.isHorizontalScrollBarEnabled = false
        web.isNestedScrollingEnabled = true
        web.isScrollbarFadingEnabled = true
        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            // The widget's `width=device-width` meta viewport wins; no zoom.
            setSupportZoom(false)
            builtInZoomControls = false
            displayZoomControls = false
            useWideViewPort = true
            loadWithOverviewMode = false
            textZoom = 100
        }
        // Pad for system bars and the display cutout, like AgilCallView's
        // safe-area handling; the widget has no CSS env() safe-area on Android.
        web.setOnApplyWindowInsetsListener { view, insets ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val bars = insets.getInsets(
                    WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout(),
                )
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            } else {
                var left = insets.systemWindowInsetLeft
                var top = insets.systemWindowInsetTop
                var right = insets.systemWindowInsetRight
                var bottom = insets.systemWindowInsetBottom
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    val cutout = insets.displayCutout
                    if (cutout != null) {
                        left = maxOf(left, cutout.safeInsetLeft)
                        top = maxOf(top, cutout.safeInsetTop)
                        right = maxOf(right, cutout.safeInsetRight)
                        bottom = maxOf(bottom, cutout.safeInsetBottom)
                    }
                }
                view.setPadding(left, top, right, bottom)
            }
            insets
        }
        web.requestApplyInsets()
        web.addJavascriptInterface(BridgeInterface(bridgeNonce), BRIDGE_NAME)
        web.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest) {
                // Grant each media type independently: a camera:false /
                // microphone:true call still gets audio-only capture instead of
                // losing both permissions.
                val granted = request.resources.filter { resource ->
                    when (resource) {
                        PermissionRequest.RESOURCE_VIDEO_CAPTURE -> cameraAllowed
                        PermissionRequest.RESOURCE_AUDIO_CAPTURE -> microphoneAllowed
                        else -> true
                    }
                }
                if (granted.isEmpty()) {
                    runOnUiThread { request.deny() }
                    return
                }
                runOnUiThread { request.grant(granted.toTypedArray()) }
            }

            /**
             * HTML5 video/DOM fullscreen support for large-room video tiles.
             * The custom view is added above the WebView; onHideCustomView
             * restores the widget page.
             */
            override fun onShowCustomView(view: View?, callback: WebChromeClient.CustomViewCallback?) {
                if (view == null) {
                    callback?.onCustomViewHidden()
                    return
                }
                if (customView != null) {
                    callback?.onCustomViewHidden()
                    return
                }
                customView = view
                customViewCallback = callback
                web.visibility = View.GONE
                this@AgilCallActivity.addContentView(
                    view,
                    ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    ),
                )
            }

            override fun onHideCustomView() {
                val view = customView ?: return
                customView = null
                (view.parent as? ViewGroup)?.removeView(view)
                web.visibility = View.VISIBLE
                val callback = customViewCallback
                customViewCallback = null
                callback?.onCustomViewHidden()
            }
        }
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val target = request.url
                if (isAllowed(target)) return false
                if (request.isForMainFrame) {
                    // Only hand web links to the system browser. Arbitrary
                    // schemes (intent:, tel:, custom app links) are never
                    // launched from the guard path.
                    val scheme = target.scheme?.lowercase()
                    if (scheme == "http" || scheme == "https") {
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, target))
                        } catch (_: Exception) {
                            // No browser available; keep the navigation blocked.
                        }
                    }
                    emitError(
                        "navigation-blocked",
                        "Blocked navigation to ${target.host ?: "an unsupported host"}"
                    )
                }
                return true
            }

            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                // A new document loses page readiness; queue host commands until
                // the reloaded widget proves it is live again.
                AgilCallBridge.resetPageReady()
                injectShim(view)
            }

            override fun onPageFinished(view: WebView, url: String?) {
                injectShim(view)
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError
            ) {
                if (!request.isForMainFrame) return
                emitError(
                    "load-failed",
                    error.description?.toString() ?: "The WebView failed to load the call page"
                )
            }
        }
    }

    private fun isAllowed(target: Uri): Boolean {
        val scheme = target.scheme?.lowercase() ?: return false
        if (scheme == "about") {
            val value = target.toString().lowercase()
            return value == "about:blank" || value == "about:srcdoc"
        }
        if (scheme != "https" && scheme != "http") return false
        if (!target.userInfo.isNullOrEmpty()) return false
        val origin = originOf(target) ?: return false
        return origin == widgetOrigin || allowedOrigins.contains(origin)
    }

    private fun originOf(uri: Uri): String? {
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme != "https" && scheme != "http") return null
        if (!uri.userInfo.isNullOrEmpty()) return null
        val host = uri.host?.lowercase() ?: return null
        val defaultPort = if (scheme == "https") 443 else 80
        val port = uri.port
        return if (port == -1 || port == defaultPort) "$scheme://$host" else "$scheme://$host:$port"
    }

    private fun injectShim(web: WebView) {
        val originLiteral = JSONObject.quote(widgetOrigin)
        val nonceLiteral = JSONObject.quote(bridgeNonce)
        val script = """
            (function(){try{
            var w=window;
            if(!w||w.__agilCapacitorBridgeInstalled){return;}
            if(w.location.origin!==$originLiteral){return;}
            var channel=w.AgilBridge;
            if(!channel||typeof channel.postMessage!=="function"){return;}
            var nonce=$nonceLiteral;
            var original=w.parent.postMessage;
            if(typeof original!=="function"){return;}
            var forward=function(message,targetOrigin){
            try{
            var text=typeof message==="string"?message:JSON.stringify(message);
            channel.postMessage(JSON.stringify({__agilBridgeNonce:nonce,message:text}),nonce);
            }catch(e){}
            try{return original.call(w.parent,message,targetOrigin||w.location.origin);}catch(e){}
            };
            var installed=false;
            try{w.parent.postMessage=forward;installed=w.parent.postMessage===forward;}catch(e){}
            if(!installed){try{Object.defineProperty(w.parent,"postMessage",{value:forward,writable:true,configurable:true});installed=w.parent.postMessage===forward;}catch(e2){}}
            if(installed){w.__agilCapacitorPostToPage=original;w.__agilCapacitorBridgeInstalled=true;}
            }catch(e){}})();true;
        """.trimIndent()
        web.evaluateJavascript(script, null)
    }

    private fun applyTheme(web: WebView, scheme: String?, theme: JSONObject?) {
        if (scheme != null) {
            postMessage(
                web,
                JSONObject().put("type", "agil:scheme").put("scheme", scheme).toString()
            )
        }
        if (theme != null && theme.length() > 0) {
            postMessage(
                web,
                JSONObject().put("type", "agil:theme").put("theme", theme).toString()
            )
        }
    }

    private fun postMessage(web: WebView, json: String) {
        // U+2028/U+2029 are line terminators in JavaScript source and would
        // otherwise break the injected expression.
        val safe = json
            .replace("\u2028", "\\u2028")
            .replace("\u2029", "\\u2029")
        val script = "(function(){try{var p=window.__agilCapacitorPostToPage||window.postMessage;" +
            "if(typeof p!=='function'){return;}p.call(window,$safe,window.location.origin);}catch(e){}})();true;"
        web.evaluateJavascript(script, null)
    }

    /** True for a JSON `agil:*` widget message (readiness signal for queued commands). */
    private fun isLiveWidgetMessage(payload: String): Boolean = try {
        val type = JSONObject(payload).optString("type")
        type.startsWith("agil:") && type.length <= 64
    } catch (_: Exception) {
        false
    }

    private fun redact(text: String): String = text
        .replace(
            Regex("(?i)((?:token|identity_token|id_token|access_token)=)[^&\\s#]+"),
            "\$1redacted"
        )
        .replace(
            Regex("\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\b"),
            "redacted"
        )

    private fun emitError(code: String, message: String) {
        val payload = JSONObject()
            .put("type", "agil:event")
            .put("event", "error")
            .put(
                "payload",
                JSONObject().put("code", code).put("message", redact(message).take(500))
            )
        AgilCallBridge.emit(payload.toString())
    }

    private inner class BridgeInterface(private val nonce: String) {
        @JavascriptInterface
        fun postMessage(message: String, callerNonce: String) {
            // The Java bridge is visible to every frame. The per-load nonce is
            // embedded only in the widget-origin shim closure, so a page on an
            // allowed SSO origin cannot forge `agil:*` messages.
            if (callerNonce != nonce) return
            // The shim forwards `{__agilBridgeNonce, message}`; JS parses widget
            // objects, so unwrap after the nonce check. Forwarding the envelope
            // made parseWidgetMessage() return null for every Android event.
            val payload = AgilBridgeEnvelope.unwrap(message, nonce) ?: return
            runOnUiThread {
                AgilCallBridge.emit(payload)
                // `agil:ready` is the contract; any accepted `agil:*` message
                // also proves the page and shim are live (Android installs the
                // shim from onPageStarted, so a very early ready can be missed).
                if (isLiveWidgetMessage(payload)) {
                    AgilCallBridge.markPageReady()
                }
            }
        }
    }

    override fun onDestroy() {
        AgilCallBridge.closer = null
        AgilCallBridge.themeApplier = null
        AgilCallBridge.setActionSender(null)
        AgilCallBridge.setChatSender(null)
        AgilCallBridge.messageListener = null
        customView?.let { view ->
            (view.parent as? ViewGroup)?.removeView(view)
            customViewCallback?.onCustomViewHidden()
        }
        customView = null
        customViewCallback = null
        webView?.apply {
            removeJavascriptInterface(BRIDGE_NAME)
            loadUrl("about:blank")
            destroy()
        }
        webView = null
        super.onDestroy()
    }
}
