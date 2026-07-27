package com.grafana.quickpizza.nativecrash

import android.content.Context

/**
 * Persists a pending native tombstone between SIGSEGV and the next launch.
 *
 * **Demo-only:** This class exists because [opentelemetry-android](https://github.com/open-telemetry/opentelemetry-android)
 * does not yet report native crashes (`REASON_CRASH_NATIVE`) over OTLP — see
 * [opentelemetry-android#764](https://github.com/open-telemetry/opentelemetry-android/issues/764).
 * Until the SDK handles ApplicationExitInfo replay, we cache a backtrace at crash time and merge it
 * on the next launch when [ApplicationExitInfo.traceInputStream] is empty or delayed.
 *
 * Mirrors the Faro RN SDK cache used when ApplicationExitInfo.traceInputStream is null.
 * Delete with the rest of this package once OTel Android ships native crash reporting.
 */
internal object NativeCrashTraceCache {
    private const val PREFS_NAME = "com.grafana.quickpizza.native_crash_trace_cache"
    private const val KEY_TRACE = "pending_trace"
    private const val KEY_TIMESTAMP = "pending_timestamp"
    private const val MAX_TIMESTAMP_DELTA_MS = 10_000L

    fun savePendingCrashTrace(context: Context, trace: String, timestampMs: Long) {
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_TRACE, trace)
            .putLong(KEY_TIMESTAMP, timestampMs)
            .commit()
    }

    data class PendingTrace(val trace: String, val timestampMs: Long)

    fun peekPendingCrashTrace(context: Context): PendingTrace? {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val trace = prefs.getString(KEY_TRACE, null)?.trim().orEmpty()
        val cachedTimestamp = prefs.getLong(KEY_TIMESTAMP, 0L)
        if (trace.isEmpty() || cachedTimestamp == 0L) {
            return null
        }
        return PendingTrace(trace, cachedTimestamp)
    }

    fun traceForExitTimestamp(context: Context, pending: PendingTrace?, exitTimestampMs: Long): String {
        if (pending == null) {
            return ""
        }
        val delta = kotlin.math.abs(exitTimestampMs - pending.timestampMs)
        if (delta > MAX_TIMESTAMP_DELTA_MS) {
            clearPendingCrashTrace(context)
            return ""
        }
        return pending.trace
    }

    fun clearPendingCrashTrace(context: Context) {
        context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_TRACE)
            .remove(KEY_TIMESTAMP)
            .apply()
    }
}

internal fun looksLikeNativeBacktrace(trace: String): Boolean =
    TombstoneBacktraceFormatter.looksLikeNativeBacktrace(trace)
