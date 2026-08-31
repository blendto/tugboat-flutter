#include "tugboat/tb_image_core.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  if (size < 8) {
    return 0;
  }
  const int32_t width = static_cast<int32_t>((data[0] % 32) + 1);
  const int32_t height = static_cast<int32_t>((data[1] % 32) + 1);
  const tb_pixel_format format =
      (data[2] & 1) != 0 ? TB_PIXEL_FORMAT_BGRA8888 : TB_PIXEL_FORMAT_RGBA8888;
  const size_t stride = static_cast<size_t>(width) * 4;
  std::vector<uint8_t> pixels(stride * static_cast<size_t>(height), 128);
  const size_t copy = std::min(pixels.size(), size);
  std::memcpy(pixels.data(), data, copy);

  const size_t rect_bytes = size >= 8 ? size - 8 : 0;
  const size_t rect_count = rect_bytes / sizeof(tb_rect);
  std::vector<tb_rect> masks(rect_count);
  if (rect_count > 0) {
    std::memcpy(masks.data(), data + 8, rect_count * sizeof(tb_rect));
  }

  tb_image_request_v1 req{};
  req.abi_version = TB_IMAGE_CORE_ABI_VERSION;
  req.pixels = pixels.data();
  req.width = width;
  req.height = height;
  req.stride_bytes = static_cast<int32_t>(stride);
  req.format = format;
  req.masks = masks.empty() ? nullptr : masks.data();
  req.mask_count = masks.size();
  req.last_dhash = nullptr;
  req.force = data[3] & 1;

  tb_image_result_v1 result{};
  tb_image_process_v1(&req, &result);
  return 0;
}
