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

// Explicit local development dependency; the hackathon library is not published to Maven yet.
val replayCheckout = providers.gradleProperty("faroReplayDir").orNull
    ?: error("Set -PfaroReplayDir=/absolute/path/to/faro-android-replay for this integration branch")
includeBuild(replayCheckout) {
    dependencySubstitution {
        substitute(module("com.grafana.faro:faro-android-replay")).using(project(":replay"))
    }
}
