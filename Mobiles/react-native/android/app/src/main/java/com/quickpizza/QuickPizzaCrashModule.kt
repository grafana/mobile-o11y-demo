package com.quickpizza

import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod

class QuickPizzaCrashModule(
  reactContext: ReactApplicationContext
) : ReactContextBaseJavaModule(reactContext) {

  override fun getName(): String = "QuickPizzaCrash"

  @ReactMethod
  fun crash(variant: String) {
    when (variant) {
      "nullPointer" -> {
        val value: String? = null
        value!!
      }
      else -> throw RuntimeException("QuickPizza RN intentional native crash")
    }
  }
}
