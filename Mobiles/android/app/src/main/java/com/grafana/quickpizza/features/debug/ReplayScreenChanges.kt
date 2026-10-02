package com.grafana.quickpizza.features.debug

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.platform.LocalDensity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

/** Demo-only triggers. The caller passes visibility flags, never field contents or user text. */
@Composable
internal fun ReplayScreenChanges(screenName: String, scroll: ScrollState, vararg visibleState: Any?) {
    if (ReplayJourney.recorder == null) return
    val owner = LocalLifecycleOwner.current
    val ime = WindowInsets.ime
    val density = LocalDensity.current
    DisposableEffect(owner, screenName) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) ReplayJourney.changed(screenName)
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(screenName, *visibleState) {
        ReplayJourney.changed(screenName)
    }
    LaunchedEffect(screenName, scroll, ime, density) {
        snapshotFlow { Triple(scroll.value, scroll.isScrollInProgress, ime.getBottom(density) > 0) }
            .collect { (_, moving, _) ->
                ReplayJourney.scrolling(screenName, moving)
                ReplayJourney.changed(screenName)
            }
    }
}
