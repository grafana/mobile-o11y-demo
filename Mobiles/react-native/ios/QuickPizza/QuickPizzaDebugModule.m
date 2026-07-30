#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(QuickPizzaDebug, NSObject)

RCT_EXTERN_METHOD(blockMainThread:(nonnull NSNumber *)durationMs
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)

@end
