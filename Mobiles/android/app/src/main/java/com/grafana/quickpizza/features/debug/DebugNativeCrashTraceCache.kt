package com.grafana.quickpizza.features.debug

import android.content.Context

/**
 * Demo-only writer for a pending native tombstone between SIGSEGV and the next launch.
 *
 * Uses the same SharedPreferences contract as [com.grafana.quickpizza.nativecrash.NativeCrashTraceCache]
 * (added in a follow-up PR) so [ApplicationExitInfo.traceInputStream] null cases on emulators still
 * have a backtrace to replay.
 */
internal object DebugNativeCrashTraceCache {
    const val PREFS_NAME = "com.grafana.quickpizza.native_crash_trace_cache"
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
