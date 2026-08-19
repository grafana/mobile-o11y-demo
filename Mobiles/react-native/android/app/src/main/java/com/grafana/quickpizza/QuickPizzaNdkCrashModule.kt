package com.grafana.quickpizza

import android.os.Handler
import android.os.Looper
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod

class QuickPizzaNdkCrashModule(
  reactContext: ReactApplicationContext
) : ReactContextBaseJavaModule(reactContext) {

  override fun getName(): String = "QuickPizzaNdkCrash"

  @ReactMethod
  fun crash() {
    Handler(Looper.getMainLooper()).post {
      val trace = captureBacktraceForCache()
      if (trace.isNotBlank() && looksLikeNativeBacktrace(trace)) {
        QuickPizzaNativeCrashTraceCache.savePendingCrashTrace(
          reactApplicationContext,
          trace.trim(),
          System.currentTimeMillis(),
        )
      }
      nativeCrash()
    }
  }

  private external fun captureBacktraceForCache(): String

  private external fun nativeCrash()

  companion object {
    init {
      System.loadLibrary("quickpizza_ndk_crash")
    }
  }
}
