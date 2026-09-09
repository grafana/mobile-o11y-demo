plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.grafana.opentelemetry.android"
    compileSdk = 36

    defaultConfig {
        minSdk = 23
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlin {
        compilerOptions {
            jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
        }
    }
}

dependencies {
    coreLibraryDesugaring(libs.desugar.jdk.libs)

    api(platform(libs.opentelemetry.android.bom))
    api(libs.opentelemetry.android.agent)

    testImplementation(libs.junit)
    testImplementation(libs.opentelemetry.android.core)
}
