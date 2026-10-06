pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
buildscript {
    // Lock the settings classpath (anything resolved by settings.gradle.kts).
    configurations.classpath {
        resolutionStrategy.activateDependencyLocking()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "QuickPizza"
include(":app")
include(":grafana-opentelemetry-android")

fun resolveFaroReplayCheckout(): java.io.File {
    val configured = providers.gradleProperty("faroReplayDir").orNull
        ?: System.getenv("FARO_REPLAY_DIR")?.trim()?.takeIf { it.isNotEmpty() }
        ?: error(
            "Set -PfaroReplayDir or FARO_REPLAY_DIR to the faro-android-replay checkout. " +
                "Use an absolute path, or a path relative to Mobiles/android.",
        )
    val checkout = file(configured)
    if (!checkout.resolve("replay/build.gradle.kts").isFile) {
        error("faroReplayDir does not contain replay/build.gradle.kts: ${checkout.absolutePath}")
    }
    return checkout
}

includeBuild(resolveFaroReplayCheckout()) {
    dependencySubstitution {
        substitute(module("com.grafana.faro:faro-android-replay")).using(project(":replay"))
    }
}
