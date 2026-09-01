#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const int32_t TBImageCorePixelFormatRGBA8888;
FOUNDATION_EXPORT const int32_t TBImageCorePixelFormatBGRA8888;

@interface TBImageProcessResult : NSObject
@property(nonatomic, readonly) int32_t status;
@property(nonatomic, readonly, copy) NSString *dHash;
@property(nonatomic, readonly) int64_t maskFillMicros;
@property(nonatomic, readonly) int64_t dHashMicros;
@end

/// Objective-C++ bridge to the C ABI. Do not log `pixels`.
@interface TBImageCoreBridge : NSObject
+ (TBImageProcessResult *)processPixels:(void *)pixels
                                  width:(int32_t)width
                                 height:(int32_t)height
                            strideBytes:(int32_t)strideBytes
                                 format:(int32_t)format
                            masksPacked:(nullable const int32_t *)masksPacked
                           maskIntCount:(int32_t)maskIntCount
                              lastDHash:(NSString *)lastDHash
                                  force:(BOOL)force;
@end

NS_ASSUME_NONNULL_END
