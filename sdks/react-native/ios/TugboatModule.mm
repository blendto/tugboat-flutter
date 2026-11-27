#import <React/RCTBridgeModule.h>
#import <TugboatSpec/TugboatSpec.h>

#if __has_include(<TugboatReactNative/TugboatReactNative-Swift.h>)
#import <TugboatReactNative/TugboatReactNative-Swift.h>
#else
#import "TugboatReactNative-Swift.h"
#endif

// Each method is one call to the same-named `Tugboat` function in the Swift
// host, through `TugboatRN`. Nothing here throws into the app.
@interface TugboatModule : NSObject <NativeTugboatSpec>
@end

@implementation TugboatModule

RCT_EXPORT_MODULE(Tugboat)

- (void)start:(NSDictionary *)config
{
  [TugboatRN start:config ?: @{}];
}

- (void)activate:(NSString *)activationRequestId
{
  [TugboatRN activate:activationRequestId];
}

- (void)deactivate
{
  [TugboatRN deactivate];
}

- (void)stop
{
  [TugboatRN stop];
}

- (void)setScreen:(NSString *)name instanceId:(NSString *)instanceId
{
  [TugboatRN setScreen:name instanceId:instanceId];
}

- (void)setUserId:(NSString *)userId
{
  [TugboatRN setUserId:userId];
}

- (void)setTraits:(NSDictionary *)traits
{
  [TugboatRN setTraits:traits ?: @{}];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeTugboatSpecJSI>(params);
}

@end
