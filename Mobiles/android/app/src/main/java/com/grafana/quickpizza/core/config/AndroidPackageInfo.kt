package com.grafana.quickpizza.core.config

import android.content.Context

/**
 * Helper utilities for reading Android package metadata.
 *
 * Isolates API level compatibility logic from application config.
 */
object AndroidPackageInfo {
    /**
     * Returns the app's version code (build number).
     *
     * This is Android's incremental build identifier (like iOS CFBundleVersion),
     * not to be confused with the user-facing version string (versionName).
     */
    fun getVersionCode(context: Context): Long = runCatching {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
    }.getOrDefault(0L)
}
