package com.grafana.quickpizza.core.o11y

import android.app.Application
import androidx.navigation.NavController
import com.grafana.quickpizza.core.config.AppConfig
import com.grafana.quickpizza.core.config.RuntimeConfig
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.session.SessionObserver

/**
 * Optional Faro Android session replay wiring. Default builds use [NoOpSessionReplayIntegration].
 */
interface SessionReplayIntegration {
    /** Session observer registered before the first OTel session starts, or null when replay is off. */
    val sessionObserver: SessionObserver?

    fun attach(rum: OpenTelemetryRum)

    fun install(
        navController: NavController,
        runtimeConfig: RuntimeConfig,
        appConfig: AppConfig,
        application: Application,
    )
}
