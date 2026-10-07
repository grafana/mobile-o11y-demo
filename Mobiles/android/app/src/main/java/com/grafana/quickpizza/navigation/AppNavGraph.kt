package com.grafana.quickpizza.navigation

import androidx.compose.runtime.Composable
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import com.grafana.quickpizza.features.about.AboutScreen
import com.grafana.quickpizza.features.auth.presentation.LoginScreen
import com.grafana.quickpizza.features.debug.ConfigScreen
import com.grafana.quickpizza.features.debug.DebugScreen
import com.grafana.quickpizza.features.debug.ReplayJourney
import com.grafana.quickpizza.features.pizza.presentation.HomeScreen
import com.grafana.quickpizza.features.profile.presentation.ProfileScreen

sealed class Screen(val route: String) {
    data object Login : Screen("login")
    data object Home : Screen("home")
    data object Profile : Screen("profile")
    data object About : Screen("about")
    data object Debug : Screen("debug")
    data object DebugConfig : Screen("debug/config")
}

@Composable
fun AppNavGraph(
    navController: NavHostController,
    modifier: Modifier = Modifier,
) {
    // Crossfading two screens is unsafe for a screenshot allow-list. Only the opt-in replay
    // journey disables it; normal navigation keeps the pinned NavHost defaults.
    val replayEnabled = ReplayJourney.recorder != null
    NavHost(
        navController = navController, startDestination = Screen.Home.route, modifier = modifier,
        enterTransition = { if (replayEnabled) EnterTransition.None else fadeIn(tween(700)) },
        exitTransition = { if (replayEnabled) ExitTransition.None else fadeOut(tween(700)) },
        popEnterTransition = { if (replayEnabled) EnterTransition.None else fadeIn(tween(700)) },
        popExitTransition = { if (replayEnabled) ExitTransition.None else fadeOut(tween(700)) },
    ) {
        composable(Screen.Home.route) {
            HomeScreen(
                onNavigateToLogin = { navController.navigate(Screen.Login.route) },
                onNavigateToProfile = { navController.navigate(Screen.Profile.route) },
            )
        }
        composable(Screen.Login.route) {
            LoginScreen(
                onLoginSuccess = { navController.popBackStack() },
                onBack = { navController.popBackStack() },
            )
        }
        composable(Screen.Profile.route) {
            ProfileScreen(
                onBack = { navController.popBackStack() },
                onSignOut = {
                    navController.popBackStack()
                },
            )
        }
        composable(Screen.About.route) {
            AboutScreen(
                onNavigateToLogin = { navController.navigate(Screen.Login.route) },
                onNavigateToProfile = { navController.navigate(Screen.Profile.route) },
            )
        }
        composable(Screen.Debug.route) {
            DebugScreen(
                onNavigateToConfig = { navController.navigate(Screen.DebugConfig.route) },
            )
        }
        composable(Screen.DebugConfig.route) {
            ConfigScreen(onBack = { navController.popBackStack() })
        }
    }
}
