package com.grafana.quickpizza.nativecrash

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import io.opentelemetry.api.common.AttributeKey
import io.opentelemetry.api.common.Attributes
import io.opentelemetry.api.logs.Severity
import io.opentelemetry.sdk.logs.SdkLoggerProvider
import io.opentelemetry.sdk.trace.SdkTracerProvider
import java.util.concurrent.TimeUnit

/**
 * Demo-only replay of [ApplicationExitInfo.REASON_CRASH_NATIVE] over OTLP `device.crash`.
 *
 * **TODO:** Delete when opentelemetry-android implements native crash reporting:
 * https://github.com/open-telemetry/opentelemetry-android/issues/764
 *
 * Production apps must not ship tombstone parsing here — that belongs in the SDK (see Faro RN
 * `FaroCrashReporter` / `ApplicationExitTraceReader`).
 */
object NativeExitCrashReporter {
    private const val TAG = "NativeExitCrashReporter"
    private const val PREFS_NAME = "com.grafana.quickpizza.native_exit_crash_reporter"
    private const val KEY_LAST_PROCESSED_TIMESTAMP = "last_processed_timestamp"
    private const val CRASH_INSTRUMENTATION_SCOPE = "io.opentelemetry.crash"
    private const val DEVICE_CRASH_EVENT_NAME = "device.crash"
    private const val FLUSH_TIMEOUT_MS = 10_000L
    /** Grace before [PackageManager.getPackageInfo] lastUpdateTime when filtering stale exits. */
    private const val INSTALL_TIME_GRACE_MS = 2_000L
    private const val MAX_EXIT_REASONS = 20

    fun reportPendingNativeCrashes(
        context: Context,
        loggerProvider: SdkLoggerProvider,
        tracerProvider: SdkTracerProvider?,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return
        }

        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return

        val exitInfoList = activityManager.getHistoricalProcessExitReasons(
            context.packageName,
            0,
            MAX_EXIT_REASONS,
        )
        if (exitInfoList.isEmpty()) {
            return
        }

        val installTimeMs = packageLastUpdateTimeMs(context)
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val lastProcessed = prefs.getLong(KEY_LAST_PROCESSED_TIMESTAMP, 0L)
        val pendingTrace = NativeCrashTraceCache.peekPendingCrashTrace(context)
        var latestTimestamp = lastProcessed
        var pendingTraceUsed = false

        // One fatal native exit can surface as multiple ApplicationExitInfo rows; keep the
        // row with the richest tombstone (mirrors Faro RN FaroCrashReporter).
        val candidates = exitInfoList
            .filter { it.timestamp > lastProcessed && it.reason == ApplicationExitInfo.REASON_CRASH_NATIVE }
            .groupBy { it.timestamp }
            .mapValues { (_, exits) -> pickBestNativeExit(exits) }
            .toSortedMap()

        for ((_, exitInfo) in candidates) {
            if (exitInfo.timestamp > latestTimestamp) {
                latestTimestamp = exitInfo.timestamp
            }

            if (!isExitFromCurrentInstall(installTimeMs, exitInfo.timestamp)) {
                continue
            }

            val cachedTrace = NativeCrashTraceCache.traceForExitTimestamp(context, pendingTrace, exitInfo.timestamp)
            val parsedExit = ApplicationExitTraceReader.read(exitInfo)
            val exitTrace = parsedExit.text
            val trace = resolveNativeTrace(exitTrace, cachedTrace)

            if (trace.isBlank()) {
                Log.w(
                    TAG,
                    "Skipping CRASH_NATIVE without tombstone trace (traceInputStream was null and no cached backtrace)",
                )
                continue
            }

            if (!traceMatchesCurrentInstall(context, trace)) {
                Log.i(TAG, "Skipping CRASH_NATIVE tombstone from a different APK install")
                continue
            }

            if (parsedExit.text.isEmpty() && cachedTrace.isNotBlank()) {
                pendingTraceUsed = true
            } else if (cachedTrace.isNotBlank() && trace == cachedTrace) {
                pendingTraceUsed = true
            }

            emitNativeCrash(loggerProvider, tracerProvider, exitInfo, trace, parsedExit.signal)
        }

        if (latestTimestamp > lastProcessed) {
            prefs.edit().putLong(KEY_LAST_PROCESSED_TIMESTAMP, latestTimestamp).apply()
        }
        if (pendingTraceUsed) {
            NativeCrashTraceCache.clearPendingCrashTrace(context)
        }
    }

    private fun emitNativeCrash(
        loggerProvider: SdkLoggerProvider,
        tracerProvider: SdkTracerProvider?,
        exitInfo: ApplicationExitInfo,
        trace: String,
        parsedSignal: String,
    ) {
        val message = buildFallbackCrashMessage(exitInfo)
        val preview = trace.lineSequence().firstOrNull { it.contains("#00 pc") }?.trim().orEmpty()
        Log.i(
            TAG,
            "Exporting CRASH_NATIVE via device.crash (${trace.lineSequence().count()} lines) preview=$preview",
        )

        val attrs = Attributes.builder()
            .put(AttributeKey.stringKey("exception.type"), "crash")
            .put(AttributeKey.stringKey("exception.message"), message)
            .put(AttributeKey.stringKey("trace"), trace)
            .put(AttributeKey.stringKey("mechanism"), "crash")
            .put(AttributeKey.stringKey("description"), "Application crash (Native)")
            .put(AttributeKey.stringKey("processName"), exitInfo.processName.orEmpty())
            .put(AttributeKey.longKey("pid"), exitInfo.pid.toLong())
            .put(AttributeKey.longKey("importance"), exitInfo.importance.toLong())
            .put(AttributeKey.longKey("timestamp"), exitInfo.timestamp)
            .put(AttributeKey.stringKey("reason"), "CRASH_NATIVE")
            .put(AttributeKey.longKey("status"), exitInfo.status.toLong())

        val signal = parsedSignal.ifBlank { parseSignal(trace) }
        if (signal.isNotBlank()) {
            attrs.put(AttributeKey.stringKey("signal"), signal)
        }

        loggerProvider.get(CRASH_INSTRUMENTATION_SCOPE)
            .logRecordBuilder()
            .setEventName(DEVICE_CRASH_EVENT_NAME)
            .setSeverity(Severity.ERROR)
            .setAllAttributes(attrs.build())
            .emit()

        val logsFlush = loggerProvider.forceFlush()
        logsFlush.join(FLUSH_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        tracerProvider?.forceFlush()?.join(FLUSH_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        if (logsFlush.isSuccess) {
            Log.i(TAG, "CRASH_NATIVE OTLP flush succeeded")
        } else {
            Log.e(TAG, "CRASH_NATIVE OTLP flush failed: $logsFlush")
        }
    }

    private fun resolveNativeTrace(exitTrace: String, cachedTrace: String): String {
        val exit = exitTrace.trim()
        val cached = cachedTrace.trim()

        if (TombstoneBacktraceFormatter.looksLikeNativeBacktrace(exit)) {
            return exit
        }
        if (TombstoneBacktraceFormatter.looksLikeNativeBacktrace(cached)) {
            return cached
        }
        return exit.ifEmpty { cached }
    }

    private fun buildFallbackCrashMessage(exitInfo: ApplicationExitInfo): String {
        val status = exitInfo.status
        return "CRASH_NATIVE: Application crash (Native), status: $status"
    }

    private fun parseSignal(trace: String): String {
        for (line in trace.lineSequence()) {
            val trimmed = line.trim()
            if (trimmed.startsWith("signal ", ignoreCase = true)) {
                return trimmed.removePrefix("signal ").trim()
            }
        }
        return ""
    }

    private fun packageLastUpdateTimeMs(context: Context): Long {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        return info.lastUpdateTime
    }

    /** Ignore exits recorded before the current APK was installed (replays after pm clear). */
    private fun isExitFromCurrentInstall(installTimeMs: Long, exitTimestampMs: Long): Boolean {
        if (exitTimestampMs >= installTimeMs - INSTALL_TIME_GRACE_MS) {
            return true
        }
        Log.i(
            TAG,
            "Skipping CRASH_NATIVE from previous install (exitTs=$exitTimestampMs lastUpdate=$installTimeMs)",
        )
        return false
    }

    /** Tombstone paths embed the per-install APK directory; skip rows from older installs. */
    private fun traceMatchesCurrentInstall(context: Context, trace: String): Boolean {
        val sourceDir = context.applicationInfo.sourceDir ?: return true
        val installDir = sourceDir.substringBeforeLast('/').substringAfterLast('/')
        if (installDir.isBlank()) {
            return true
        }
        return trace.contains(installDir)
    }

    private fun pickBestNativeExit(exits: List<ApplicationExitInfo>): ApplicationExitInfo {
        return exits.maxByOrNull { exit ->
            var score = 0
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val parsed = ApplicationExitTraceReader.read(exit)
                if (parsed.text.isNotEmpty()) {
                    score += 10
                }
                if (TombstoneBacktraceFormatter.looksLikeNativeBacktrace(parsed.text)) {
                    score += 5
                }
            }
            score
        } ?: exits.first()
    }
}
