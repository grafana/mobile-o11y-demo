package com.grafana.quickpizza.features.debug

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag

/** Existing probe UI entry point, now driving the standalone recorder and real SDK. */
@Composable
fun ReplayProbeCaptureButton(screenName: String, modifier: Modifier = Modifier) {
    if (ReplayJourney.recorder == null) return
    var requested by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf("") }
    var showError by remember { mutableStateOf(ReplayJourney.errorVisible) }
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    LaunchedEffect(requested) {
        if (!requested) return@LaunchedEffect
        withFrameNanos { }
        withFrameNanos { }
        val result = ReplayJourney.capture(screenName)
        // Do not change layout while PixelCopy is outstanding.
        if (result != com.grafana.faro.replay.CaptureRequestResult.REQUESTED) status = result.name
        requested = false
    }
    Column(modifier) {
        OutlinedButton(onClick = {
            focus.clearFocus(force = true)
            keyboard?.hide()
            requested = true
        }, modifier = Modifier.fillMaxWidth().testTag("replay.capture")) {
            Text("Capture replay", modifier = Modifier.replayPublicLabel())
        }
        if (screenName == "Home") {
            OutlinedButton(onClick = {
                ReplayJourney.emitDemoError()
                showError = true
            }, modifier = Modifier.fillMaxWidth().testTag("replay.error")) {
                Text("Try demo checkout", modifier = Modifier.replayPublicLabel())
            }
            if (showError) Text("Demo checkout failed", modifier = Modifier.replayPublicLabel().testTag("replay.error.visible"))
        }
        OutlinedButton(onClick = { ReplayJourney.recorder?.stop(); status = "STOPPED" },
            modifier = Modifier.testTag("replay.stop")) { Text("Stop replay") }
        if (status.isNotEmpty()) Text("Capture request: $status")
    }
}
