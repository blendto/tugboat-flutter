#import "TugboatImageCoreBridge.h"

#include "tugboat/tb_image_core.h"

#include <vector>

const int32_t TBImageCorePixelFormatRGBA8888 = TB_PIXEL_FORMAT_RGBA8888;
const int32_t TBImageCorePixelFormatBGRA8888 = TB_PIXEL_FORMAT_BGRA8888;

@implementation TBImageProcessResult

- (instancetype)initWithStatus:(int32_t)status
                         dHash:(NSString *)dHash
               maskFillMicros:(int64_t)maskFillMicros
                   dHashMicros:(int64_t)dHashMicros {
  self = [super init];
  if (self) {
    _status = status;
    _dHash = [dHash copy];
    _maskFillMicros = maskFillMicros;
    _dHashMicros = dHashMicros;
  }
  return self;
}

@end

@implementation TBImageCoreBridge

+ (TBImageProcessResult *)fail:(tb_image_status)status {
  return [[TBImageProcessResult alloc] initWithStatus:static_cast<int32_t>(status)
                                                dHash:@""
                                      maskFillMicros:0
                                          dHashMicros:0];
}

+ (TBImageProcessResult *)processPixels:(void *)pixels
                                  width:(int32_t)width
                                 height:(int32_t)height
                            strideBytes:(int32_t)strideBytes
                                 format:(int32_t)format
                            masksPacked:(const int32_t *)masksPacked
                           maskIntCount:(int32_t)maskIntCount
                              lastDHash:(NSString *)lastDHash
                                  force:(BOOL)force {
  if (pixels == nullptr) {
    return [self fail:TB_IMAGE_INVALID_ARGUMENT];
  }
  if (maskIntCount < 0 || (maskIntCount % 4) != 0) {
    return [self fail:TB_IMAGE_INVALID_ARGUMENT];
  }
  if (format != TB_PIXEL_FORMAT_RGBA8888 && format != TB_PIXEL_FORMAT_BGRA8888) {
    return [self fail:TB_IMAGE_UNSUPPORTED_FORMAT];
  }

  std::vector<tb_rect> rects;
  if (masksPacked != nullptr && maskIntCount > 0) {
    rects.resize(static_cast<size_t>(maskIntCount / 4));
    for (int32_t i = 0; i < maskIntCount; i += 4) {
      tb_rect &r = rects[static_cast<size_t>(i / 4)];
      r.left = masksPacked[i];
      r.top = masksPacked[i + 1];
      r.right = masksPacked[i + 2];
      r.bottom = masksPacked[i + 3];
    }
  }

  const char *last_chars = lastDHash.length == 0 ? nullptr : lastDHash.UTF8String;

  tb_image_request_v1 request {};
  request.abi_version = TB_IMAGE_CORE_ABI_VERSION;
  request.pixels = static_cast<uint8_t *>(pixels);
  request.width = width;
  request.height = height;
  request.stride_bytes = strideBytes;
  request.format = static_cast<tb_pixel_format>(format);
  request.masks = rects.empty() ? nullptr : rects.data();
  request.mask_count = rects.size();
  request.last_dhash = last_chars;
  request.force = force ? 1 : 0;

  tb_image_result_v1 native {};
  tb_image_process_v1(&request, &native);

  NSString *dhash = native.dhash[0] == '\0'
                        ? @""
                        : [[NSString alloc] initWithUTF8String:native.dhash];
  return [[TBImageProcessResult alloc] initWithStatus:static_cast<int32_t>(native.status)
                                                dHash:dhash
                                      maskFillMicros:native.mask_fill_micros
                                          dHashMicros:native.dhash_micros];
}

@end
