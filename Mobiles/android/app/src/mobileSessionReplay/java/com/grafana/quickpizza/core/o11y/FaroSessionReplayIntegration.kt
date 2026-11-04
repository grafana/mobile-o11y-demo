package com.grafana.quickpizza.core.o11y

import android.app.Application
import android.os.Looper
import androidx.navigation.NavController
import com.grafana.faro.replay.AndroidProcessHost
import com.grafana.faro.replay.FaroReplay
import com.grafana.faro.replay.FaroReplayInstallation
import com.grafana.faro.replay.FaroReplayOptions
import com.grafana.faro.replay.MaskOptions
import com.grafana.quickpizza.core.config.AppConfig
import com.grafana.quickpizza.core.config.RuntimeConfig
import com.grafana.quickpizza.features.replay.QuickPizzaNavHost
import com.grafana.quickpizza.features.replay.QuickPizzaSessionHost
import io.opentelemetry.android.OpenTelemetryRum
import io.opentelemetry.android.session.SessionObserver
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class FaroSessionReplayIntegration @Inject constructor() : SessionReplayIntegration {
    private val replaySessionHost = QuickPizzaSessionHost()
    private val replayNavigationHost = QuickPizzaNavHost()
    private var processHost: AndroidProcessHost? = null
    private var replayInstallation: FaroReplayInstallation? = null
    private var rum: OpenTelemetryRum? = null

    override val sessionObserver: SessionObserver = replaySessionHost

    override fun attach(rum: OpenTelemetryRum) {
        this.rum = rum
        replaySessionHost.attach(rum)
    }

    override fun install(
        navController: NavController,
        runtimeConfig: RuntimeConfig,
        appConfig: AppConfig,
        application: Application,
    ) {
        if (!runtimeConfig.mobileSessionReplayEnabled) return
        check(Looper.myLooper() == Looper.getMainLooper()) {
            "FaroReplay.install requires the main thread"
        }
        replayNavigationHost.bind(navController)
        if (replayInstallation != null || rum == null) return

        replayInstallation = FaroReplay.install(
            processHost = processHost ?: AndroidProcessHost.create(application).also { processHost = it },
            options = FaroReplayOptions(
                ingestUrl = runtimeConfig.otlpEndpoint,
                headers = runtimeConfig.otlpAuthHeader?.let { mapOf("Authorization" to it) }.orEmpty(),
                appName = OTelService.SERVICE_NAME,
                appVersion = appConfig.appVersion,
                maskOptions = MaskOptions(
                    maskAllText = false,
                    maskAllInputs = true,
                    blockAllMedia = false,
                ),
                replaySamplingRate = 1.0f,
                allowLoopbackHttp = allowsLoopback(runtimeConfig.otlpEndpoint),
            ),
            sessionHost = replaySessionHost,
            navigationHost = replayNavigationHost,
        )
    }

    private companion object {
        fun allowsLoopback(endpoint: String): Boolean {
            val host = runCatching { java.net.URI(endpoint).host }.getOrNull()?.lowercase() ?: return false
            return host == "localhost" || host == "127.0.0.1" || host == "10.0.2.2" || host == "::1"
        }
    }
}
