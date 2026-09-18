package com.grafana.quickpizza

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Scaffold
import androidx.compose.ui.Modifier
import androidx.navigation.compose.rememberNavController
import com.grafana.quickpizza.core.o11y.OTelService
import com.grafana.quickpizza.navigation.AppNavGraph
import com.grafana.quickpizza.navigation.BottomNavBar
import com.grafana.quickpizza.ui.theme.QuickPizzaTheme
import dagger.hilt.android.AndroidEntryPoint
import io.opentelemetry.instrumentation.compose.navigation.withOpenTelemetry
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    @Inject lateinit var otelService: OTelService

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            QuickPizzaTheme {
                val navController = rememberNavController()
                otelService.openTelemetryRum?.let { navController.withOpenTelemetry(it) }

                Scaffold(
                    modifier = Modifier.fillMaxSize(),
                    bottomBar = { BottomNavBar(navController) },
                ) { innerPadding ->
                    val bottomInset = innerPadding.calculateBottomPadding()
                    AppNavGraph(
                        navController = navController,
                        modifier = Modifier
                            .padding(bottom = bottomInset)
                            .consumeWindowInsets(PaddingValues(bottom = bottomInset)),
                    )
                }
            }
        }
    }
}
