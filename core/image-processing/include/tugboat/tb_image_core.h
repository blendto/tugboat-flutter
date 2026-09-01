#ifndef TUGBOAT_TB_IMAGE_CORE_H
#define TUGBOAT_TB_IMAGE_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Portable CPU image core. Public surface is this C ABI only — do not
 * expose C++ types from this header.
 *
 * Ownership: the caller owns every buffer. tb_image_process_v1 mutates
 * `pixels` in place (mask fill) and writes `result`. It does not allocate
 * pixel memory, retain pointers after return, or copy JPEG (JPEG is not
 * in this core).
 *
 * Thread-safety: different buffers may be processed concurrently. The same
 * pixel buffer, request, or result must not be used concurrently.
 *
 * Exceptions never cross this ABI. Failures are status codes.
 */

#define TB_IMAGE_CORE_ABI_VERSION 1
#define TB_IMAGE_CORE_MAX_WIDTH 8192
#define TB_IMAGE_CORE_MAX_HEIGHT 8192
#define TB_IMAGE_CORE_MAX_PIXELS 16777216
#define TB_IMAGE_CORE_DHASH_BITS 64
#define TB_IMAGE_CORE_DHASH_MATCH_DISTANCE 2

typedef enum tb_pixel_format {
  TB_PIXEL_FORMAT_RGBA8888 = 1,
  TB_PIXEL_FORMAT_BGRA8888 = 2,
} tb_pixel_format;

typedef enum tb_image_status {
  TB_IMAGE_OK = 0,
  TB_IMAGE_SKIPPED_BY_DHASH = 1,
  TB_IMAGE_INVALID_ARGUMENT = 2,
  TB_IMAGE_UNSUPPORTED_FORMAT = 3,
  TB_IMAGE_IMAGE_TOO_LARGE = 4,
  TB_IMAGE_INTERNAL_ERROR = 5,
} tb_image_status;

/* Inclusive-start, exclusive-end bitmap pixels. Empty or inverted rects
 * are ignored. Rects are clipped to the image; they are never expanded. */
typedef struct tb_rect {
  int32_t left;
  int32_t top;
  int32_t right;
  int32_t bottom;
} tb_rect;

typedef struct tb_image_request_v1 {
  uint32_t abi_version;
  uint8_t* pixels;
  int32_t width;
  int32_t height;
  int32_t stride_bytes;
  tb_pixel_format format;
  const tb_rect* masks;
  size_t mask_count;
  /* NUL-terminated 64-char '0'/'1' string, or NULL/empty for "no previous". */
  const char* last_dhash;
  /* Non-zero: never skip. Required so interaction frames keep session
   * semantics. */
  int force;
} tb_image_request_v1;

typedef struct tb_image_result_v1 {
  tb_image_status status;
  char dhash[TB_IMAGE_CORE_DHASH_BITS + 1];
  int64_t mask_fill_micros;
  int64_t dhash_micros;
} tb_image_result_v1;

/* Semantic version of this static library, e.g. "0.1.0". */
const char* tb_image_core_version(void);

uint32_t tb_image_core_abi_version(void);

/*
 * Mask-fill in place, then 9-by-8 dHash on RGBA-interpreted pixels.
 * BGRA8888 is sampled as B,G,R,A → R,G,B for dHash; the buffer layout is
 * not physically swizzled, so a platform JPEG encoder still sees native
 * channel order.
 *
 * On TB_IMAGE_OK and TB_IMAGE_SKIPPED_BY_DHASH, `dhash` is 64 '0'/'1'
 * characters plus a NUL. On failure, `dhash` is empty and timings may be
 * zero. Skip uses Hamming distance <= 2 against `last_dhash` unless
 * `force` is set.
 *
 * Invalid (zero size, bad stride, overflow) is TB_IMAGE_INVALID_ARGUMENT.
 * Dimensions or pixel count above the max is TB_IMAGE_IMAGE_TOO_LARGE.
 * Unknown format is TB_IMAGE_UNSUPPORTED_FORMAT. The core never clamps a
 * buffer to make it valid.
 */
tb_image_status tb_image_process_v1(const tb_image_request_v1* request,
                                    tb_image_result_v1* result);

#ifdef __cplusplus
}
#endif

#endif /* TUGBOAT_TB_IMAGE_CORE_H */
