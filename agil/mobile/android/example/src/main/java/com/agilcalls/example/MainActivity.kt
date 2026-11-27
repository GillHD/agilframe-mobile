package com.agilcalls.example

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.inputmethod.EditorInfo
import android.webkit.WebView
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import com.agilcalls.sdk.AgilCallConfig
import com.agilcalls.sdk.AgilCallConfigException
import com.agilcalls.sdk.AgilCallEvent
import com.agilcalls.sdk.AgilCallEventListener
import com.agilcalls.sdk.AgilCallError
import com.agilcalls.sdk.AgilCallView
import com.agilcalls.sdk.AgilTheme
import com.agilcalls.sdk.AgilTokenRedactor

/**
 * Minimal example: configure a room, load the hosted widget and show the typed
 * events. The token is only kept in memory and is never logged.
 *
 * Launch with extras for manual testing:
 * `adb shell am start -n com.agilcalls.example/.MainActivity --es server http://10.0.2.2:8787 --es room demo-room --es token "$TOKEN"`
 */
class MainActivity : Activity() {
    private lateinit var shell: LinearLayout
    private lateinit var callView: AgilCallView
    private lateinit var setupView: ScrollView
    private lateinit var titleView: TextView
    private lateinit var setupHint: TextView
    private lateinit var statusView: TextView
    private lateinit var screenShareNotice: TextView
    private lateinit var serverInput: EditText
    private lateinit var roomInput: EditText
    private lateinit var nameInput: EditText
    private lateinit var tokenInput: EditText
    private var immersive = false
    private var systemDark = true
    private var callDark: Boolean? = null
    private val darkShell: Boolean get() = callDark ?: systemDark
    private val showCallDiagnostics: Boolean get() = intent.getBooleanExtra(EXTRA_SHOW_CALL_DIAGNOSTICS, false)
    private var shareNoticeVisible = false
    private var fullscreenBackCallback: OnBackInvokedCallback? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            WebView.setWebContentsDebuggingEnabled(true)
        }
        requestMediaPermissions()
        systemDark = isDark(resources.configuration)
        configureSystemBars()
        shell = buildContent()
        setContentView(shell)
        applyShellTheme()
        applySystemBarVisibility()
        prefill()
        statusView.text = "Fill the room and press Join. Camera/microphone prompts appear on first join."
    }

    override fun onResume() {
        super.onResume()
        if (::callView.isInitialized) callView.onResume()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        systemDark = isDark(newConfig)
        applyShellTheme()
        applySystemBarVisibility()
        shell.requestApplyInsets()
        if (callView.visibility == View.VISIBLE) refreshCallTheme()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) applySystemBarVisibility()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (immersive && event.keyCode == KeyEvent.KEYCODE_BACK) {
            val keyboardOpen = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                shell.rootWindowInsets?.isVisible(WindowInsets.Type.ime()) == true
            if (!keyboardOpen && event.action in listOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP)) {
                if (event.action == KeyEvent.ACTION_UP && !event.isCanceled) callView.exitNativeFullscreen()
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onPause() {
        if (::callView.isInitialized) callView.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        if (::callView.isInitialized) callView.release()
        super.onDestroy()
    }

    @Deprecated("Platform Back on Android versions before API 33")
    override fun onBackPressed() {
        if (::callView.isInitialized && callView.exitNativeFullscreen()) return
        super.onBackPressed()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (::callView.isInitialized &&
            callView.onRequestPermissionsResult(requestCode, permissions, grantResults)
        ) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    @Deprecated("Activity result forwarding for the platform document picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (::callView.isInitialized && callView.onActivityResult(requestCode, resultCode, data)) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun buildContent(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xFF080D16.toInt())
            setOnApplyWindowInsetsListener { view, insets ->
                applyShellInsets(view, insets)
                insets
            }
        }
        val setup = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        setupView = ScrollView(this).apply { addView(setup) }
        root.addView(setupView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        titleView = TextView(this).apply {
            text = "AgilFrame Android SDK"
            textSize = 20f
        }
        setup.addView(titleView)
        setupHint = TextView(this).apply {
            text = "Tier-1 WebView wrapper for /embed.html. Not native WebRTC."
            textSize = 14f
            setPadding(0, dp(4), 0, dp(12))
        }
        setup.addView(setupHint)

        serverInput = field("Server URL (https://calls.example.com)", InputType.TYPE_TEXT_VARIATION_URI)
        roomInput = field("Room id", InputType.TYPE_CLASS_TEXT)
        nameInput = field("Display name (optional)", InputType.TYPE_CLASS_TEXT)
        tokenInput = field(
            "Join token (optional; empty = widget join screen)",
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
        )
        setup.addView(serverInput)
        setup.addView(roomInput)
        setup.addView(nameInput)
        setup.addView(tokenInput)

        val joinButton = Button(this).apply {
            setText(R.string.join_call)
            setAllCaps(false)
            textSize = 16f
            minHeight = dp(52)
            minimumHeight = dp(52)
            setOnClickListener { joinCall() }
        }
        setup.addView(
            joinButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(8); bottomMargin = dp(8) },
        )

        callView = AgilCallView(this).apply {
            visibility = View.GONE
            listener = AgilCallEventListener { event -> describeEvent(event) }
            nativeFullscreenListener = ::setNativeFullscreen
            externalLinkHandler = { url ->
                statusView.text = "Blocked link: ${AgilTokenRedactor.redactUrl(url)}"
            }
        }
        root.addView(
            callView,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f),
        )

        screenShareNotice = TextView(this).apply {
            textSize = 14f
            setTextColor(Color.parseColor("#FCA5A5"))
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            maxLines = 3
            visibility = View.GONE
        }
        root.addView(
            screenShareNotice,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT),
        )

        statusView = TextView(this).apply {
            textSize = 14f
            setTextColor(Color.parseColor("#CBD5E1"))
            gravity = Gravity.START
            maxLines = 4
            setPadding(0, dp(8), 0, 0)
        }
        root.addView(
            statusView,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        return root
    }

    private fun isDark(configuration: Configuration): Boolean =
        configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

    private fun shellColor(): Int = if (immersive) Color.BLACK else if (darkShell)
        0xFF080D16.toInt() else 0xFFF3F6FB.toInt()

    private fun applyShellTheme() {
        shell.setBackgroundColor(shellColor())
        val primary = if (darkShell) Color.WHITE else 0xFF152235.toInt()
        val secondary = if (darkShell) 0xFFCBD5E1.toInt() else 0xFF495A70.toInt()
        titleView.setTextColor(primary)
        setupHint.setTextColor(secondary)
        statusView.setTextColor(secondary)
        screenShareNotice.setTextColor(if (darkShell) 0xFFFCA5A5.toInt() else 0xFF9F1239.toInt())
        listOf(serverInput, roomInput, nameInput, tokenInput).forEach { field ->
            field.setTextColor(primary)
            field.setHintTextColor(secondary)
        }
    }

    @Suppress("DEPRECATION")
    private fun configureSystemBars() {
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) window.navigationBarDividerColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isStatusBarContrastEnforced = false
            window.isNavigationBarContrastEnforced = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) window.setDecorFitsSystemWindows(false)
    }

    @Suppress("DEPRECATION")
    private fun applySystemBarVisibility() {
        val darkIcons = !darkShell && !immersive
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            // Older three-button navigation can apply its own light backing to transparent bars.
            val surface = shellColor()
            window.statusBarColor = surface
            window.navigationBarColor = surface
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) window.navigationBarDividerColor = surface
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.decorView.windowInsetsController?.apply {
                val mask = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                    WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
                setSystemBarsAppearance(if (darkIcons) mask else 0, mask)
                systemBarsBehavior = if (immersive) WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    else WindowInsetsController.BEHAVIOR_DEFAULT
                if (immersive) hide(WindowInsets.Type.systemBars()) else show(WindowInsets.Type.systemBars())
            }
        } else {
            val layout = View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            val visibility = if (immersive) View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY else 0
            val appearance = if (darkIcons) View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or
                View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR else 0
            window.decorView.systemUiVisibility = layout or visibility or appearance
        }
    }

    @Suppress("DEPRECATION")
    private fun applyShellInsets(view: View, insets: WindowInsets) {
        val useSetupSpacing = !::callView.isInitialized || callView.visibility != View.VISIBLE
        val horizontal = if (useSetupSpacing) dp(16) else 0
        val top = if (useSetupSpacing) dp(20) else 0
        val bottom = if (useSetupSpacing) dp(16) else 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val types = WindowInsets.Type.displayCutout() or WindowInsets.Type.ime() or
                (if (immersive) 0 else WindowInsets.Type.systemBars())
            val safe = insets.getInsets(types)
            view.setPadding(horizontal + safe.left, top + safe.top, horizontal + safe.right, bottom + safe.bottom)
        } else {
            val cutout = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) insets.displayCutout else null
            val keyboard = if (insets.systemWindowInsetBottom > insets.stableInsetBottom)
                insets.systemWindowInsetBottom else 0
            view.setPadding(
                horizontal + maxOf(if (immersive) 0 else insets.systemWindowInsetLeft, cutout?.safeInsetLeft ?: 0),
                top + maxOf(if (immersive) 0 else insets.systemWindowInsetTop, cutout?.safeInsetTop ?: 0),
                horizontal + maxOf(if (immersive) 0 else insets.systemWindowInsetRight, cutout?.safeInsetRight ?: 0),
                bottom + maxOf(if (immersive) keyboard else insets.systemWindowInsetBottom, cutout?.safeInsetBottom ?: 0),
            )
        }
    }

    private fun setNativeFullscreen(active: Boolean) {
        if (immersive == active) return
        immersive = active
        shell.setBackgroundColor(shellColor())
        updateStatusVisibility()
        screenShareNotice.visibility = if (!active && shareNoticeVisible) View.VISIBLE else View.GONE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (active) {
                val callback = OnBackInvokedCallback { callView.exitNativeFullscreen() }
                fullscreenBackCallback = callback
                onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback)
            } else {
                fullscreenBackCallback?.let(onBackInvokedDispatcher::unregisterOnBackInvokedCallback)
                fullscreenBackCallback = null
            }
        }
        applySystemBarVisibility()
        shell.requestApplyInsets()
    }

    private fun joinCall() {
        val token = tokenInput.text.toString().trim().takeIf { it.isNotEmpty() }
        val name = nameInput.text.toString().trim().takeIf { it.isNotEmpty() }
        val config = try {
            AgilCallConfig(
                serverUrl = serverInput.text.toString(),
                room = roomInput.text.toString(),
                token = token,
                participantName = name,
                maxParticipants = 200,
                safeArea = false,
                backgroundColor = shellColor(),
            )
        } catch (error: AgilCallConfigException) {
            statusView.text = "Configuration error (${error.field}): ${error.message}"
            return
        }
        showCall(true)
        statusView.text = "Loading ${config.serverOrigin} …"
        callView.load(config)
    }

    private fun showCall(show: Boolean) {
        if (!show) callView.exitNativeFullscreen()
        callDark = null
        shareNoticeVisible = false
        screenShareNotice.visibility = View.GONE
        setupView.visibility = if (show) View.GONE else View.VISIBLE
        callView.visibility = if (show) View.VISIBLE else View.GONE
        statusView.maxLines = if (show) 1 else 4
        updateStatusVisibility()
        applyShellTheme()
        applySystemBarVisibility()
        shell.requestApplyInsets()
    }

    private fun updateStatusVisibility() {
        statusView.visibility = if (!immersive && (callView.visibility != View.VISIBLE || showCallDiagnostics))
            View.VISIBLE else View.GONE
    }

    private fun refreshCallTheme() {
        callView.readRenderedTheme { theme ->
            if (callView.visibility == View.VISIBLE) {
                callDark = when (theme) {
                    AgilTheme.LIGHT -> false
                    AgilTheme.DARK -> true
                    else -> null
                }
                applyShellTheme()
                applySystemBarVisibility()
            }
        }
    }

    private fun prefill() {
        serverInput.setText(intent.getStringExtra(EXTRA_SERVER) ?: "https://calls.example.com")
        roomInput.setText(intent.getStringExtra(EXTRA_ROOM) ?: "demo-room")
        nameInput.setText(intent.getStringExtra(EXTRA_NAME).orEmpty())
        tokenInput.setText(intent.getStringExtra(EXTRA_TOKEN).orEmpty())
        tokenInput.imeOptions = EditorInfo.IME_ACTION_DONE
        tokenInput.setOnEditorActionListener { _, _, _ ->
            joinCall()
            true
        }
    }

    private fun requestMediaPermissions() {
        val missing = ArrayList<String>(2)
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            missing.add(Manifest.permission.CAMERA)
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            missing.add(Manifest.permission.RECORD_AUDIO)
        }
        if (missing.isNotEmpty()) {
            requestPermissions(missing.toTypedArray(), REQUEST_MEDIA)
        }
    }

    private fun describeEvent(event: AgilCallEvent): Unit = when (event) {
        is AgilCallEvent.Ready -> {
            refreshCallTheme()
            val caps = event.capabilities
            statusView.text = "Ready: media=${caps.media}, blur=${caps.blur}, " +
                "screenShare=${caps.screenShare}, recording=${caps.recording}"
        }
        is AgilCallEvent.Joined -> statusView.text = "Joined the call"
        is AgilCallEvent.Left -> {
            showCall(false)
            statusView.text = "Left the call"
        }
        is AgilCallEvent.Chat -> {
            val message = event.message
            val author = message.participantName ?: message.participantId ?: "guest"
            statusView.text = "Chat $author: ${AgilTokenRedactor.redactText(message.text)}"
        }
        is AgilCallEvent.State -> {
            val state = event.snapshot
            statusView.text = "State: phase=${state.phase}, participants=${state.participants}, " +
                "mic=${state.micEnabled}, camera=${state.cameraEnabled}"
        }
        is AgilCallEvent.Participants -> {
            val update = event.update
            statusView.text = "Participants ${update.kind}: ${update.count} " +
                "(+${update.added.size}/-${update.removed.size}) rev=${update.revision}"
        }
        is AgilCallEvent.Connection -> {
            val update = event.update
            statusView.text = "Connection: ${update.state}" +
                (update.attempt?.let { " attempt=$it" } ?: "") +
                (update.delayMs?.let { " delay=$it ms" } ?: "")
        }
        is AgilCallEvent.Error -> {
            val error: AgilCallError = event.error
            if (error is AgilCallError.ActionDenied && error.action == "share-screen" &&
                error.reason == "screen-share-unavailable"
            ) {
                screenShareNotice.setText(R.string.screen_share_unavailable)
                shareNoticeVisible = true
                if (!immersive) screenShareNotice.visibility = View.VISIBLE
            } else {
                statusView.text = "Error [${error.code}]${if (error.fatal) " fatal" else ""}: ${error.message}"
                if (error.fatal && !immersive) statusView.visibility = View.VISIBLE
            }
            Unit
        }
        is AgilCallEvent.Generic -> {
            if (event.name == "theme-changed") refreshCallTheme()
            statusView.text = "Event: ${event.name}"
        }
    }

    private fun field(hint: String, inputType: Int): EditText = EditText(this).apply {
        this.hint = hint
        this.inputType = inputType
        textSize = 16f
        setSingleLine(true)
        setTextColor(Color.WHITE)
        setHintTextColor(Color.parseColor("#64748B"))
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val REQUEST_MEDIA = 1001
        private const val EXTRA_SERVER = "server"
        private const val EXTRA_ROOM = "room"
        private const val EXTRA_TOKEN = "token"
        private const val EXTRA_NAME = "name"
        private const val EXTRA_SHOW_CALL_DIAGNOSTICS = "show-call-diagnostics"
    }
}
