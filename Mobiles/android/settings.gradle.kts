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
fun resolveFaroReplayCheckout(): java.io.File {
    providers.gradleProperty("faroReplayDir").orNull?.let { return file(it) }
    System.getenv("FARO_REPLAY_DIR")?.trim()?.takeIf { it.isNotEmpty() }?.let { return file(it) }
    // Workbench default: repos/hackathon-18-faro-android-replay beside mobile-o11y-demo.
    val sibling = file("../../../hackathon-18-faro-android-replay")
    if (sibling.resolve("replay/build.gradle.kts").isFile) return sibling
    error(
        "Set -PfaroReplayDir=/absolute/path/to/faro-android-replay (or FARO_REPLAY_DIR) " +
            "for this integration branch",
    )
}
val replayCheckout = resolveFaroReplayCheckout()
includeBuild(replayCheckout) {
    dependencySubstitution {
        substitute(module("com.grafana.faro:faro-android-replay")).using(project(":replay"))
    }
}
