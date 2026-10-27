package com.grafana.quickpizza.features.replay

import androidx.navigation.NavController
import com.grafana.faro.replay.FaroReplayNavigationHost
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Navigation host for QuickPizza's Compose [NavController].
 *
 * [bind] can run again after a configuration change. Replay install stays once per
 * process; this host rebinds the controller and keeps the library subscription.
 *
 * TODO(faro-replay-otel-android): hackathon stand-in for this app's navigator.
 * Keep it here after the session host moves. Jetpack Navigation is not part of
 * OpenTelemetry, so it does not belong in `com.grafana.faro:faro-replay-otel-android`.
 */
internal class QuickPizzaNavHost : FaroReplayNavigationHost {
    private val callbacks = CopyOnWriteArrayList<(String?) -> Unit>()
    private var navController: NavController? = null
    private val listener = NavController.OnDestinationChangedListener { _, destination, _ ->
        publish(destination.route)
    }

    fun bind(controller: NavController) {
        if (navController === controller) return
        navController?.removeOnDestinationChangedListener(listener)
        navController = controller
        controller.addOnDestinationChangedListener(listener)
    }

    override fun currentScreenId(): String? =
        navController?.currentDestination?.route?.takeIf { it.isNotBlank() }

    override fun subscribe(onScreenChanged: (screenId: String?) -> Unit): AutoCloseable {
        callbacks.add(onScreenChanged)
        return AutoCloseable { callbacks.remove(onScreenChanged) }
    }

    private fun publish(route: String?) {
        val screenId = route?.takeIf { it.isNotBlank() }
        callbacks.forEach { callback -> callback(screenId) }
    }
}
