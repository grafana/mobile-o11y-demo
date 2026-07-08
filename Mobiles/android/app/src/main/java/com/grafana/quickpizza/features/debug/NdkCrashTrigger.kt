package com.grafana.quickpizza.features.debug

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Demo SIGSEGV trigger for the Debug tab (Android OTel app).
 *
 * Tombstone replay/export lives in `com.grafana.quickpizza.nativecrash` (separate PR) until
 * [opentelemetry-android#764](https://github.com/open-telemetry/opentelemetry-android/issues/764).
 * Mirrors [com.quickpizza.QuickPizzaNdkCrashModule] in the React Native demo.
 */
object NdkCrashTrigger {
    private const val TAG = "NdkCrashTrigger"

    init {
        System.loadLibrary("quickpizza_ndk_crash")
    }

    fun crash(context: Context) {
        Handler(Looper.getMainLooper()).post {
            val trace = captureBacktraceForCache()
            if (trace.isNotBlank() && looksLikeNativeBacktrace(trace)) {
                DebugNativeCrashTraceCache.savePendingCrashTrace(
                    context.applicationContext,
                    trace.trim(),
                    System.currentTimeMillis(),
                )
                Log.i(TAG, "Cached pending native tombstone (${trace.lineSequence().count()} lines)")
            }
            Log.i(TAG, "Triggering native SIGSEGV")
            nativeCrash()
        }
    }

    private external fun captureBacktraceForCache(): String

    private external fun nativeCrash()
}
