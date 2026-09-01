#include "tugboat/tb_image_core.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace {

constexpr uint8_t kMaskFill = 0x1a;
constexpr uint8_t kMaskAlpha = 0xff;
constexpr int kHashWidth = 9;
constexpr int kHashHeight = 8;
constexpr char kVersion[] = "0.1.0";

void clear_result(tb_image_result_v1* result, tb_image_status status) {
  result->status = status;
  result->dhash[0] = '\0';
  result->mask_fill_micros = 0;
  result->dhash_micros = 0;
}

int64_t elapsed_micros(std::chrono::steady_clock::time_point start) {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now() - start)
      .count();
}

bool mul_u64(uint64_t a, uint64_t b, uint64_t* out) {
  if (a != 0 && b > UINT64_MAX / a) {
    return false;
  }
  *out = a * b;
  return true;
}

int channel_r(tb_pixel_format format) {
  return format == TB_PIXEL_FORMAT_BGRA8888 ? 2 : 0;
}

int channel_b(tb_pixel_format format) {
  return format == TB_PIXEL_FORMAT_BGRA8888 ? 0 : 2;
}

/* Matches Dart `(i * extent / cells).floor()` then
 * `((i + 1) * extent / cells).floor().clamp(start + 1, extent)`. */
int32_t cell_start(int32_t i, int32_t extent, int32_t cells) {
  const double value = static_cast<double>(static_cast<int64_t>(i) * extent) /
                       static_cast<double>(cells);
  return static_cast<int32_t>(std::floor(value));
}

int32_t cell_end(int32_t i, int32_t extent, int32_t cells, int32_t start) {
  const double value =
      static_cast<double>(static_cast<int64_t>(i + 1) * extent) /
      static_cast<double>(cells);
  int32_t end = static_cast<int32_t>(std::floor(value));
  const int32_t lower = start + 1;
  if (end < lower) {
    end = lower;
  }
  if (end > extent) {
    end = extent;
  }
  return end;
}

bool last_dhash_valid(const char* last) {
  if (last == nullptr) {
    return false;
  }
  for (int i = 0; i < TB_IMAGE_CORE_DHASH_BITS; ++i) {
    const char c = last[i];
    if (c == '\0' || (c != '0' && c != '1')) {
      return false;
    }
  }
  return last[TB_IMAGE_CORE_DHASH_BITS] == '\0';
}

int hamming(const char* a, const char* b) {
  int distance = 0;
  for (int i = 0; i < TB_IMAGE_CORE_DHASH_BITS; ++i) {
    if (a[i] != b[i]) {
      ++distance;
    }
  }
  return distance;
}

tb_image_status validate(const tb_image_request_v1* request) {
  if (request == nullptr || request->pixels == nullptr) {
    return TB_IMAGE_INVALID_ARGUMENT;
  }
  if (request->abi_version != TB_IMAGE_CORE_ABI_VERSION) {
    return TB_IMAGE_INVALID_ARGUMENT;
  }
  if (request->format != TB_PIXEL_FORMAT_RGBA8888 &&
      request->format != TB_PIXEL_FORMAT_BGRA8888) {
    return TB_IMAGE_UNSUPPORTED_FORMAT;
  }
  if (request->width <= 0 || request->height <= 0 ||
      request->stride_bytes <= 0) {
    return TB_IMAGE_INVALID_ARGUMENT;
  }
  if (request->mask_count > 0 && request->masks == nullptr) {
    return TB_IMAGE_INVALID_ARGUMENT;
  }

  uint64_t min_stride = 0;
  if (!mul_u64(static_cast<uint64_t>(request->width), 4, &min_stride)) {
    return TB_IMAGE_INVALID_ARGUMENT;
  }
  if (static_cast<uint64_t>(request->stride_bytes) < min_stride) {
    return TB_IMAGE_INVALID_ARGUMENT;
  }

  uint64_t pixels = 0;
  if (!mul_u64(static_cast<uint64_t>(request->width),
               static_cast<uint64_t>(request->height), &pixels)) {
    return TB_IMAGE_IMAGE_TOO_LARGE;
  }
  if (request->width > TB_IMAGE_CORE_MAX_WIDTH ||
      request->height > TB_IMAGE_CORE_MAX_HEIGHT ||
      pixels > TB_IMAGE_CORE_MAX_PIXELS) {
    return TB_IMAGE_IMAGE_TOO_LARGE;
  }

  uint64_t bytes = 0;
  if (!mul_u64(static_cast<uint64_t>(request->stride_bytes),
               static_cast<uint64_t>(request->height), &bytes)) {
    return TB_IMAGE_INVALID_ARGUMENT;
  }
  return TB_IMAGE_OK;
}

void apply_masks(uint8_t* pixels, int32_t width, int32_t height,
                 int32_t stride, const tb_rect* masks, size_t mask_count) {
  if (masks == nullptr || mask_count == 0) {
    return;
  }
  for (size_t i = 0; i < mask_count; ++i) {
    int32_t left = std::max(masks[i].left, 0);
    int32_t top = std::max(masks[i].top, 0);
    int32_t right = std::min(masks[i].right, width);
    int32_t bottom = std::min(masks[i].bottom, height);
    if (right <= left || bottom <= top) {
      continue;
    }
    for (int32_t y = top; y < bottom; ++y) {
      uint8_t* row = pixels + static_cast<size_t>(y) * static_cast<size_t>(stride);
      for (int32_t x = left; x < right; ++x) {
        uint8_t* px = row + static_cast<size_t>(x) * 4;
        px[0] = kMaskFill;
        px[1] = kMaskFill;
        px[2] = kMaskFill;
        px[3] = kMaskAlpha;
      }
    }
  }
}

int gray_at(const uint8_t* px, int r_off, int b_off) {
  const int r = px[r_off];
  const int g = px[1];
  const int b = px[b_off];
  return (r * 299 + g * 587 + b * 114) / 1000;
}

int sample_gray(const uint8_t* pixels, int32_t width, int32_t stride,
                int32_t x, int32_t y0, int32_t y1, int r_off, int b_off) {
  const int32_t start_x = cell_start(x, width, kHashWidth);
  const int32_t end_x = cell_end(x, width, kHashWidth, start_x);
  int64_t sum = 0;
  int32_t count = 0;
  for (int32_t sy = y0; sy < y1; ++sy) {
    const uint8_t* row =
        pixels + static_cast<size_t>(sy) * static_cast<size_t>(stride);
    for (int32_t sx = start_x; sx < end_x; ++sx) {
      sum += gray_at(row + static_cast<size_t>(sx) * 4, r_off, b_off);
      ++count;
    }
  }
  return count == 0 ? 0 : static_cast<int>(sum / count);
}

void compute_dhash(const uint8_t* pixels, int32_t width, int32_t height,
                   int32_t stride, tb_pixel_format format, char* out) {
  const int r_off = channel_r(format);
  const int b_off = channel_b(format);
  int cells[kHashWidth * kHashHeight];
  for (int y = 0; y < kHashHeight; ++y) {
    const int32_t y0 = cell_start(y, height, kHashHeight);
    const int32_t y1 = cell_end(y, height, kHashHeight, y0);
    for (int x = 0; x < kHashWidth; ++x) {
      cells[y * kHashWidth + x] =
          sample_gray(pixels, width, stride, x, y0, y1, r_off, b_off);
    }
  }
  int bit = 0;
  for (int y = 0; y < kHashHeight; ++y) {
    for (int x = 0; x < kHashWidth - 1; ++x) {
      const int left = cells[y * kHashWidth + x];
      const int right = cells[y * kHashWidth + x + 1];
      out[bit++] = left < right ? '1' : '0';
    }
  }
  out[TB_IMAGE_CORE_DHASH_BITS] = '\0';
}

tb_image_status process_impl(const tb_image_request_v1* request,
                             tb_image_result_v1* result) {
  const tb_image_status valid = validate(request);
  if (valid != TB_IMAGE_OK) {
    clear_result(result, valid);
    return valid;
  }

  const auto mask_start = std::chrono::steady_clock::now();
  apply_masks(request->pixels, request->width, request->height,
              request->stride_bytes, request->masks, request->mask_count);
  result->mask_fill_micros = elapsed_micros(mask_start);

  const auto hash_start = std::chrono::steady_clock::now();
  compute_dhash(request->pixels, request->width, request->height,
                request->stride_bytes, request->format, result->dhash);
  result->dhash_micros = elapsed_micros(hash_start);

  if (request->force == 0 && last_dhash_valid(request->last_dhash) &&
      hamming(request->last_dhash, result->dhash) <=
          TB_IMAGE_CORE_DHASH_MATCH_DISTANCE) {
    result->status = TB_IMAGE_SKIPPED_BY_DHASH;
    return TB_IMAGE_SKIPPED_BY_DHASH;
  }
  result->status = TB_IMAGE_OK;
  return TB_IMAGE_OK;
}

}  // namespace

extern "C" {

const char* tb_image_core_version(void) { return kVersion; }

uint32_t tb_image_core_abi_version(void) { return TB_IMAGE_CORE_ABI_VERSION; }

tb_image_status tb_image_process_v1(const tb_image_request_v1* request,
                                    tb_image_result_v1* result) {
  if (result == nullptr) {
    return TB_IMAGE_INVALID_ARGUMENT;
  }
  try {
    return process_impl(request, result);
  } catch (...) {
    clear_result(result, TB_IMAGE_INTERNAL_ERROR);
    return TB_IMAGE_INTERNAL_ERROR;
  }
}

}  // extern "C"
