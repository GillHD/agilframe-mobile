package com.agil.calls

import android.Manifest
import android.content.Intent
import android.net.Uri
import com.getcapacitor.JSObject
import com.getcapacitor.PermissionState
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import com.getcapacitor.annotation.Permission
import com.getcapacitor.annotation.PermissionCallback
import java.util.UUID

/**
 * Android shell for the hosted AgilFrame widget.
 *
 * `openCall` launches [AgilCallActivity] (in-app WebView) or the system browser.
 * Media, chat and themes stay inside the widget; the plugin owns the Activity,
 * the `AgilBridge` channel and runtime camera/microphone permissions.
 */
@CapacitorPlugin(
    name = "AgilCalls",
    permissions = [
        Permission(alias = "camera", strings = [Manifest.permission.CAMERA]),
        Permission(alias = "microphone", strings = [Manifest.permission.RECORD_AUDIO])
    ]
)
class AgilCallsPlugin : Plugin() {
    private var callId: String? = null

    @PluginMethod
    fun openCall(call: PluginCall) {
        val url = call.getString("url")
        if (url.isNullOrBlank()) {
            call.reject("openCall requires a widget URL")
            return
        }
        val uri = Uri.parse(url)
        val scheme = uri.scheme?.lowercase()
        if (scheme != "https" && scheme != "http") {
            call.reject("openCall requires an http(s) widget URL")
            return
        }
        if (call.getString("presentation") == "external") {
            openExternal(call, uri)
            return
        }

        val id = UUID.randomUUID().toString()
        callId = id
        AgilCallBridge.beginCall()
        AgilCallBridge.messageListener = { raw ->
            notifyListeners("callMessage", JSObject().put("raw", raw))
        }

        val allowedOrigins = ArrayList<String>()
        val originsArray = call.getArray("allowedOrigins")
        if (originsArray != null) {
            for (value in originsArray.toList<Any?>()) {
                if (value is String) allowedOrigins.add(value)
            }
        }
        val permissions = call.getObject("permissions")
        val intent = Intent(context, AgilCallActivity::class.java).apply {
            putExtra(AgilCallActivity.EXTRA_URL, url)
            putStringArrayListExtra(AgilCallActivity.EXTRA_ALLOWED_ORIGINS, allowedOrigins)
            putExtra(AgilCallActivity.EXTRA_CAMERA, permissions?.get("camera") as? Boolean ?: true)
            putExtra(AgilCallActivity.EXTRA_MICROPHONE, permissions?.get("microphone") as? Boolean ?: true)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        call.resolve(JSObject().put("callId", id).put("mode", "in-app"))
    }

    @PluginMethod
    fun close(call: PluginCall) {
        AgilCallBridge.close()
        AgilCallBridge.messageListener = null
        AgilCallBridge.themeApplier = null
        AgilCallBridge.setActionSender(null)
        AgilCallBridge.setChatSender(null)
        callId = null
        call.resolve()
    }

    @PluginMethod
    fun sendAction(call: PluginCall) {
        val action = call.getString("action")?.trim().orEmpty()
        if (action.isEmpty() || action.length > 64) {
            call.reject("sendAction requires a widget action")
            return
        }
        if (!AgilCallBridge.sendAction(action)) {
            call.reject("No AgilFrame WebView is open")
            return
        }
        call.resolve()
    }

    @PluginMethod
    fun sendChat(call: PluginCall) {
        val text = call.getString("text")
        if (text.isNullOrBlank()) {
            call.reject("sendChat requires non-empty text")
            return
        }
        if (!AgilCallBridge.sendChat(text.take(4000))) {
            call.reject("No AgilFrame WebView is open")
            return
        }
        call.resolve()
    }

    @PluginMethod
    fun isSupported(call: PluginCall) {
        val webViewAvailable = try {
            Class.forName("android.webkit.WebView")
            true
        } catch (_: ClassNotFoundException) {
            false
        }
        val result = JSObject().put("supported", true).put("inAppWebView", webViewAvailable)
        if (!webViewAvailable) {
            result.put("reason", "Android WebView is unavailable; calls open in the system browser")
        }
        call.resolve(result)
    }

    @PluginMethod
    fun setTheme(call: PluginCall) {
        val scheme = call.getString("scheme")
        val theme = call.getObject("theme")
        if (scheme == null && theme == null) {
            call.resolve()
            return
        }
        AgilCallBridge.applyTheme(scheme, theme)
        call.resolve()
    }

    @PluginMethod
    override fun checkPermissions(call: PluginCall) {
        call.resolve(permissionReport())
    }

    @PluginMethod
    override fun requestPermissions(call: PluginCall) {
        requestPermissionForAliases(arrayOf("camera", "microphone"), call, "permissionsCallback")
    }

    @PermissionCallback
    private fun permissionsCallback(call: PluginCall) {
        call.resolve(permissionReport())
    }

    private fun permissionReport(): JSObject {
        val camera = permissionStatus("camera")
        val microphone = permissionStatus("microphone")
        return JSObject()
            .put("camera", camera)
            .put("microphone", microphone)
            .put("settingsRequired", camera == "denied" || microphone == "denied")
    }

    private fun permissionStatus(alias: String): String = when (getPermissionState(alias)) {
        PermissionState.GRANTED -> "granted"
        PermissionState.DENIED -> "denied"
        PermissionState.PROMPT -> "prompt"
        PermissionState.PROMPT_WITH_RATIONALE -> "prompt-with-rationale"
        else -> "unavailable"
    }

    private fun openExternal(call: PluginCall, uri: Uri) {
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            call.resolve(JSObject().put("callId", UUID.randomUUID().toString()).put("mode", "external"))
        } catch (error: Exception) {
            call.reject("No app can open this call URL", error)
        }
    }
}
