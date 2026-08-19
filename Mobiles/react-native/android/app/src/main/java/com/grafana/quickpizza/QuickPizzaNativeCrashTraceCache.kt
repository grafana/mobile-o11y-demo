package com.grafana.quickpizza

import android.content.Context

/**
 * Demo-only writer for a pending native tombstone between SIGSEGV and the next launch.
 *
 * Uses the same SharedPreferences contract as Faro RN
 * `com.grafana.faro.crash_trace_cache` (available in newer SDK releases). Published
 * 1.3.0 does not read this yet, but caching keeps emulator tombstone fallback ready.
 */
internal object QuickPizzaNativeCrashTraceCache {
    const val PREFS_NAME = "com.grafana.faro.crash_trace_cache"
    const val KEY_TRACE = "pending_trace"
    const val KEY_TIMESTAMP = "pending_timestamp"

    fun savePendingCrashTrace(context: Context, trace: String, timestampMs: Long) {
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_TRACE, trace)
            .putLong(KEY_TIMESTAMP, timestampMs)
            .commit()
    }
}

internal fun looksLikeNativeBacktrace(trace: String): Boolean {
    if (trace.isBlank()) {
        return false
    }
    val nativeFrameLine = Regex("""^\s*#\d+\s+pc\s+(?:0x)?[0-9a-fA-F]+\s+\S+""")
    return trace.lineSequence().any { nativeFrameLine.containsMatchIn(it) }
}
