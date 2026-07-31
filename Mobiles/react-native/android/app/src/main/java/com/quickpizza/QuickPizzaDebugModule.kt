package com.quickpizza

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod

/**
 * Demo-only helpers for Debug tab fault injection.
 * [blockMainThread] stalls the UI looper so Faro Choreographer frame monitoring
 * records real slow/frozen frames (unlike JS-thread busy loops).
 */
class QuickPizzaDebugModule(
  reactContext: ReactApplicationContext,
) : ReactContextBaseJavaModule(reactContext) {

  override fun getName(): String = "QuickPizzaDebug"

  @ReactMethod
  fun blockMainThread(durationMs: Double, promise: Promise) {
    val blockForMs = durationMs.toLong().coerceIn(1, MAX_BLOCK_MS)
    Handler(Looper.getMainLooper()).post {
      val deadline = SystemClock.uptimeMillis() + blockForMs
      while (SystemClock.uptimeMillis() < deadline) {
        Thread.yield()
      }
      promise.resolve(null)
    }
  }

  companion object {
    private const val MAX_BLOCK_MS = 10_000L
  }
}
