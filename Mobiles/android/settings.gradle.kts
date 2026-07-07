pluginManagement {
    repositories {
        // Until com.grafana.faro.android-symbols is on the Gradle Plugin Portal, release builds
        // need: publishToMavenLocal in faro-android-gradle-plugin, then refresh lockfiles
        // (see Mobiles/android/README.md — "Local Gradle plugin").
        mavenLocal()
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
