#include <jni.h>

#include <dlfcn.h>
#include <iomanip>
#include <sstream>
#include <string>
#include <unwind.h>

struct BacktraceState {
  void **frames;
  size_t count;
  size_t max;
};

static _Unwind_Reason_Code unwindCallback(_Unwind_Context *context, void *arg) {
  auto *state = static_cast<BacktraceState *>(arg);
  if (state->count >= state->max) {
    return _URC_END_OF_STACK;
  }
  state->frames[state->count++] =
      reinterpret_cast<void *>(_Unwind_GetIP(context));
  return _URC_NO_REASON;
}

static std::string abiLabel() {
#if defined(__aarch64__)
  return "arm64";
#elif defined(__arm__)
  return "arm";
#elif defined(__x86_64__)
  return "x86_64";
#elif defined(__i386__)
  return "x86";
#else
  return "unknown";
#endif
}

static std::string formatBacktrace(void **frames, size_t count) {
  std::ostringstream out;
  out << "*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***\n";
  out << "ABI: '" << abiLabel() << "'\n";
  out << "backtrace:\n";

  for (size_t i = 0; i < count && i < 32; ++i) {
    Dl_info info {};
    const auto pc = reinterpret_cast<uintptr_t>(frames[i]);
    dladdr(frames[i], &info);
    const char *library =
        (info.dli_fname != nullptr) ? info.dli_fname : "unknown";
    out << "      #" << std::setw(2) << std::setfill('0') << i << " pc "
        << std::hex << std::uppercase << std::setw(16) << std::setfill('0')
        << pc << "  " << library;
    if (info.dli_sname != nullptr) {
      out << " (" << info.dli_sname << ")";
    }
    out << "\n";
  }

  return out.str();
}

static std::string captureCurrentBacktrace() {
  void *frames[32];
  BacktraceState state {frames, 0, 32};
  _Unwind_Backtrace(unwindCallback, &state);
  return formatBacktrace(frames, state.count);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_grafana_quickpizza_QuickPizzaNdkCrashModule_captureBacktraceForCache(
    JNIEnv *env,
    jobject /* thiz */) {
  const std::string trace = captureCurrentBacktrace();
  return env->NewStringUTF(trace.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_com_grafana_quickpizza_QuickPizzaNdkCrashModule_nativeCrash(JNIEnv * /* env */,
                                                         jobject /* thiz */) {
  // Intentional null dereference → SIGSEGV with a native tombstone stack trace.
  volatile int *ptr = nullptr;
  *ptr = 42;
}
