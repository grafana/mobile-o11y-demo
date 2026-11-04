package com.grafana.quickpizza.core.o11y

import android.app.Application
import androidx.navigation.NavController
import com.grafana.quickpizza.core.config.AppConfig
import com.grafana.quickpizza.core.config.RuntimeConfig
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.session.SessionObserver
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class NoOpSessionReplayIntegration @Inject constructor() : SessionReplayIntegration {
    override val sessionObserver: SessionObserver? = null

    override fun attach(rum: OpenTelemetryRum) = Unit

    override fun install(
        navController: NavController,
        runtimeConfig: RuntimeConfig,
        appConfig: AppConfig,
        application: Application,
    ) = Unit
}
