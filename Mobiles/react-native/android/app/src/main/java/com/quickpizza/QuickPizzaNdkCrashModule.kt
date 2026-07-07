package com.quickpizza

import android.os.Handler
import android.os.Looper
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.grafana.faro.reactnative.FaroCrashReporter

class QuickPizzaNdkCrashModule(
  reactContext: ReactApplicationContext
) : ReactContextBaseJavaModule(reactContext) {

  override fun getName(): String = "QuickPizzaNdkCrash"

  @ReactMethod
  fun crash() {
    Handler(Looper.getMainLooper()).post {
      val trace = captureBacktraceForCache()
      if (trace.isNotBlank()) {
        FaroCrashReporter.cachePendingNativeCrashTrace(reactApplicationContext, trace)
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
