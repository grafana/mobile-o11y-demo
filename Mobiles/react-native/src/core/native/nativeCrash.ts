import { NativeModules } from 'react-native';

type JavaCrashVariant = 'runtimeException' | 'nullPointer' | 'anr';

type QuickPizzaCrashModule = {
  crash: (variant: JavaCrashVariant) => void;
};

type QuickPizzaNdkCrashModule = {
  crash: () => void;
};

const javaCrashModule = NativeModules.QuickPizzaCrash as
  | QuickPizzaCrashModule
  | undefined;

const ndkCrashModule = NativeModules.QuickPizzaNdkCrash as
  | QuickPizzaNdkCrashModule
  | undefined;

/** Java/Kotlin crash reported via R8 mapping.txt retrace (not an NDK tombstone). */
export function triggerJavaCrash(variant: JavaCrashVariant): void {
  if (!javaCrashModule?.crash) {
    throw new Error('QuickPizzaCrash native module is not available');
  }

  javaCrashModule.crash(variant);
}

/** Real C++ SIGSEGV crash with a native tombstone (Android NDK symbols zip). */
export function triggerNdkCrash(): void {
  if (!ndkCrashModule?.crash) {
    throw new Error('QuickPizzaNdkCrash native module is not available');
  }

  ndkCrashModule.crash();
}
