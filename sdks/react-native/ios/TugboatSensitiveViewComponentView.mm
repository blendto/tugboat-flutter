#import <React/RCTViewComponentView.h>

#import <react/renderer/components/TugboatSpec/ComponentDescriptors.h>
#import <react/renderer/components/TugboatSpec/Props.h>

#if __has_include(<TugboatReactNative/TugboatReactNative-Swift.h>)
#import <TugboatReactNative/TugboatReactNative-Swift.h>
#else
#import "TugboatReactNative-Swift.h"
#endif

using namespace facebook::react;

// `<Tugboat.Sensitive>`: a plain view the Swift host masks with its whole
// subtree in every screenshot (`TugboatAdapters.markSensitive`).
@interface TugboatSensitiveViewComponentView : RCTViewComponentView
@end

@implementation TugboatSensitiveViewComponentView

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<TugboatSensitiveViewComponentDescriptor>();
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const TugboatSensitiveViewProps>();
    _props = defaultProps;
    [TugboatRN markSensitive:self];
  }
  return self;
}

@end

Class<RCTComponentViewProtocol> TugboatSensitiveViewCls(void)
{
  return TugboatSensitiveViewComponentView.class;
}
