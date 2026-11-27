package com.agilcalls.compose

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.agilcalls.sdk.AgilCallConfig
import com.agilcalls.sdk.AgilCallEventListener
import com.agilcalls.sdk.AgilCallView

/**
 * Jetpack Compose wrapper around [AgilCallView].
 *
 * The composable owns the view lifecycle: it releases the WebView when it
 * leaves the composition. If [config] changes, the call is reloaded.
 *
 * ```kotlin
 * AgilCall(
 *     config = AgilCallConfig(
 *         serverUrl = "https://calls.example.com",
 *         room = "team-sync",
 *         token = joinToken,
 *     ),
 *     modifier = Modifier.fillMaxSize(),
 *     listener = AgilCallEventListener { event -> /* ... */ },
 * )
 * ```
 *
 * Camera/microphone runtime permissions still belong to the host Activity: the
 * AndroidX Compose host should request them and forward
 * `onRequestPermissionsResult` to the view (obtain it via [onViewReady]).
 * Forward `onActivityResult` to the same view to enable the document picker.
 */
@Composable
fun AgilCall(
    config: AgilCallConfig,
    modifier: Modifier = Modifier,
    listener: AgilCallEventListener? = null,
    externalLinkHandler: ((String) -> Unit)? = null,
    onViewReady: ((AgilCallView) -> Unit)? = null,
) {
    val listenerState = rememberUpdatedState(listener)
    val externalLinkState = rememberUpdatedState(externalLinkHandler)
    val onViewReadyState = rememberUpdatedState(onViewReady)
    val viewHolder = remember { arrayOfNulls<AgilCallView>(1) }

    DisposableEffect(Unit) {
        onDispose {
            viewHolder[0]?.release()
            viewHolder[0] = null
        }
    }

    AndroidView(
        modifier = modifier,
        factory = { context ->
            AgilCallView(context).also { view ->
                view.listener = AgilCallEventListener { event ->
                    listenerState.value?.onEvent(event)
                }
                view.externalLinkHandler = { url ->
                    externalLinkState.value?.invoke(url)
                }
                view.load(config)
                viewHolder[0] = view
                onViewReadyState.value?.invoke(view)
            }
        },
        update = { view ->
            if (view.config != config) view.load(config)
        },
    )
}
